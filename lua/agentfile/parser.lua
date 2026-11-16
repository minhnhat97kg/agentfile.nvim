-- lua/agentfile/parser.lua
local markers = require("agentfile.markers")

local M = {}

local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- Detect a heredoc delimiter at the end of a tool-call line, e.g. `<<'EOF'`.
--- Only lines that mention a tool (`@name`) are considered, so prose like
--- "run `cat << EOF`" never opens literal mode.
---@param line string
---@return string|nil delimiter
local function heredoc_delim(line)
  if not line:find("@", 1, true) then
    return nil
  end
  return line:match("<<%s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?%s*$")
end

--- Which argument receives a heredoc body for a given tool.
---@param name string
---@return string|nil
local function heredoc_content_key(name)
  if name == "write_file" then
    return "content"
  elseif name == "edit_file" then
    return "replacement"
  elseif name == "run_command" then
    return "command"
  end
  return nil
end

--- Parse Frontmatter YAML subset
---@param lines string[]
---@return table, number # config, end_line_index (or 0 if no frontmatter)
function M.parse_frontmatter(lines)
  local config = {}
  if not lines or #lines == 0 or trim(lines[1]) ~= "---" then
    return config, 0
  end

  local end_idx = 0
  local scopes = { { indent = -1, value = config } }
  for i = 2, #lines do
    local line = trim(lines[i])
    if line == "---" then
      end_idx = i
      break
    end

    -- ignore comments or empty lines
    if line ~= "" and not line:match("^#") then
      -- strip inline comment if any
      local cleaned = line:gsub("%s+#.*$", "")
      local key, val = cleaned:match("^([%w_]+)%s*:%s*(.*)$")
      if key and val then
        key = trim(key)
        val = trim(val)
        local indent = #(lines[i]:match("^(%s*)") or "")
        while #scopes > 1 and indent <= scopes[#scopes].indent do
          table.remove(scopes)
        end
        local target = scopes[#scopes].value

        -- Handle inline array: [a, b, c]
        if val == "" then
          target[key] = {}
          table.insert(scopes, { indent = indent, value = target[key] })
        elseif val:match("^%[.*%]$") then
          local inner = val:sub(2, -2)
          local arr = {}
          for item in inner:gmatch("[^,]+") do
            local clean_item = trim(item)
            -- strip quotes if present
            clean_item = clean_item:gsub('^["\'](.*)["\']$', "%1")
            if clean_item ~= "" then
              table.insert(arr, clean_item)
            end
          end
          target[key] = arr
        -- Handle env var: env:VAR_NAME
        elseif val:match("^env:[%w_]+$") then
          local env_var = val:sub(5)
          target[key] = os.getenv(env_var) or ""
        -- Handle boolean
        elseif val == "true" then
          target[key] = true
        elseif val == "false" then
          target[key] = false
        -- Handle numbers
        elseif tonumber(val) then
          target[key] = tonumber(val)
        else
          -- Strip optional quotes
          target[key] = val:gsub('^["\'](.*)["\']$', "%1")
        end
      end
    end
  end

  return config, end_idx
end

--- Parse blocks using the configured markers (default: [system], [me], [think],
--- [agent], [result ...], [reset], [error]). Legacy markers (>>me, #me) are
--- still accepted.
---@param lines string[]
---@param start_from? number
---@return table[]
function M.parse_blocks(lines, start_from)
  local blocks = {}
  local start_idx = start_from or 1

  local current_block = nil
  local heredoc = nil

  local function flush_current()
    if current_block then
      -- Preserve framed tool data exactly; trim ordinary conversation blocks.
      local raw = table.concat(current_block.raw_lines, "\n")
      current_block.content = current_block.result_fence and raw or trim(raw)
      table.insert(blocks, current_block)
      current_block = nil
    end
    heredoc = nil
  end

  for i = start_idx, #lines do
    local line = lines[i]

    -- Only our explicit result envelope makes markers literal. Its fence is
    -- chosen by the writer to avoid collisions with all nested tool output.
    local opening = line:match("^(`+)agentfile%-result$")
    if current_block and current_block.result_fence and not current_block.result_closed then
      if line == current_block.result_fence then
        current_block.result_closed = true
      else
        table.insert(current_block.raw_lines, line)
      end
      current_block.end_line = i
    elseif current_block and current_block.role == "result"
      and not current_block.result_fence and #current_block.raw_lines == 0
      and opening and #opening >= 3 then
      current_block.result_fence = opening
      current_block.end_line = i
    elseif heredoc then
      -- Inside a heredoc body (from `@tool ... <<'EOF'`): markers are literal.
      if current_block then
        table.insert(current_block.raw_lines, line)
        current_block.end_line = i
      end
      if trim(line) == heredoc then
        heredoc = nil
      end
    else
      local kind, extra = markers.kind_of(line)
      if kind then
        flush_current()
        current_block = {
          role = kind == "me" and "user" or kind,
          kind = kind,
          raw_lines = {},
          start_line = i,
          end_line = i,
        }
        if kind == "result" then
          local id, status = markers.parse_result_attrs(extra)
          current_block.id = id
          current_block.status = status
        elseif kind == "ask" then
          current_block.ask_text = trim(extra or "")
        end
      elseif current_block then
        if not current_block.result_closed then
          table.insert(current_block.raw_lines, line)
        end
        current_block.end_line = i
        if current_block.role ~= "result" then
          heredoc = heredoc_delim(line)
        end
      end
    end
  end

  flush_current()
  return blocks
end

--- Parse a single tool-call line (must start the line).
--- Supports JSON, single string, and key=value forms.
---@param line string
---@return table|nil
local function parse_tool_line(line)
  -- A tool call is only executed when it is the first token on a line.
  -- Mentions inside prose, lists or inline code (e.g. `@read_file(...)`)
  -- are documentation, not actions.
  local raw_call, name, args_str = line:match("^%s*(@([a-z][a-z0-9_]*)%s*%((.-)%))")
  if not raw_call then
    return nil
  end

  local args = {}
  args_str = trim(args_str)
  if args_str ~= "" then
    -- 1. Try standard JSON decode
    local ok, decoded = pcall(vim.json.decode, args_str)
    if ok and type(decoded) == "table" then
      args = decoded
    else
      -- 2. Try single string literal: "something" or 'something'
      local single_str = args_str:match('^["\'](.*)["\']$')
      if single_str then
        if name == "read_file" or name == "list_files" then
          args = { path = single_str }
        elseif name == "run_command" then
          args = { command = single_str }
        else
          args = { value = single_str, path = single_str }
        end
      else
        -- 3. Try key=val pairs: path="foo.txt", replacement="..."
        for k, v in args_str:gmatch('([%w_]+)%s*=%s*["\'](.-)["\']') do
          args[k] = v
        end
      end
    end
  end

  return { name = name, args = args, raw = raw_call }
end

--- Parse a tool call that carries a heredoc body:
---   @write_file({"path": "x"}) <<'EOF'
--- or, for tools whose only argument is the body:
---   @run_command <<'EOF'
---@param line string
---@return table|nil # { name, args, delim }
local function parse_heredoc_tool(line)
  local name, args_part, delim = line:match("^%s*@([a-z][a-z0-9_]*)%s*(.-)<<%s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?%s*$")
  if not name then
    return nil
  end

  local key = heredoc_content_key(name)
  if not key then
    return nil
  end

  args_part = trim(args_part or "")
  if args_part == "" or args_part == "()" then
    return { name = name, args = {}, delim = delim }
  end

  local call = parse_tool_line("@" .. name .. args_part)
  if not call then
    return nil
  end
  return { name = name, args = call.args, delim = delim }
end

--- Some models wrap an intended tool call in a text/plaintext code fence even
--- when told not to. Accept such a block only when it contains nothing but
--- tool-call lines, so documentation code samples with prose/comments are
--- still ignored.
---@param fence_lines string[]
---@param info string
---@return table[]
local function tool_calls_in_fence(fence_lines, info)
  info = (info or ""):lower():match("^([%w_+-]*)") or ""
  local allowed = {
    [""] = true,
    text = true,
    plaintext = true,
    txt = true,
    json = true,
    jsonc = true,
    bash = true,
    sh = true,
    shell = true,
    console = true,
  }
  if not allowed[info] then
    return {}
  end

  local calls = {}
  for _, line in ipairs(fence_lines) do
    if trim(line) ~= "" then
      local call = parse_tool_line(line)
      if not call then
        return {}
      end
      table.insert(calls, call)
    end
  end
  return calls
end

--- Extract tool calls from agent text.
--- By default fenced code blocks are ignored (documentation examples).
--- Pass `allow_fenced = true` for agent output: models sometimes wrap the
--- intended call in ```plaintext; a fence containing only tool calls is then
--- treated as an action.
---@param text string
---@param opts? table # { allow_fenced = boolean }
---@return table[] # list of { name = string, args = table, raw = string }
function M.extract_tool_calls(text, opts)
  local calls = {}
  if not text or text == "" then return calls end
  opts = opts or {}
  local allow_fenced = opts.allow_fenced == true

  local lines = vim.split(text, "\n")
  local in_fenced_code = false
  local fence_info = ""
  local fence_lines = {}

  local function flush_fence()
    if allow_fenced then
      vim.list_extend(calls, tool_calls_in_fence(fence_lines, fence_info))
    end
    fence_lines = {}
    fence_info = ""
  end

  local i = 1
  while i <= #lines do
    local line = lines[i]
    local trimmed = trim(line)
    if not in_fenced_code and trimmed:match("^```") then
      in_fenced_code = true
      fence_info = trim(trimmed:sub(4))
      fence_lines = {}
    elseif in_fenced_code and trimmed:match("^```%s*$") then
      flush_fence()
      in_fenced_code = false
    elseif in_fenced_code then
      table.insert(fence_lines, line)
    else
      -- Heredoc form first: the body is verbatim, so multi-line code never
      -- has to be escaped into a JSON string.
      local hcall = parse_heredoc_tool(line)
      if hcall then
        local key = heredoc_content_key(hcall.name)
        local body = {}
        i = i + 1
        while i <= #lines and trim(lines[i]) ~= hcall.delim do
          table.insert(body, lines[i])
          i = i + 1
        end
        hcall.args[key] = table.concat(body, "\n")
        table.insert(calls, {
          name = hcall.name,
          args = hcall.args,
          raw = "@" .. hcall.name .. " (heredoc)",
        })
      else
        local call = parse_tool_line(line)
        if call then
          table.insert(calls, call)
        end
      end
    end
    i = i + 1
  end

  -- Tolerate an unclosed final fence.
  if in_fenced_code then
    flush_fence()
  end

  return calls
end

--- Pair tool calls from conversation blocks with their [result] blocks
---@param blocks table[]
---@return table[] # list of { id = number, tool = table, block_index = number, result = table|nil }
function M.pair_tools_and_results(blocks)
  local pairs = {}
  local results_by_id = {}
  local unmatched_results = {}

  -- First pass: gather result blocks
  for idx, block in ipairs(blocks) do
    if block.role == "result" then
      if block.id then
        results_by_id[block.id] = block
      else
        table.insert(unmatched_results, block)
      end
    end
  end

  -- Second pass: find tool calls and pair them
  local current_id = 0
  for b_idx, block in ipairs(blocks) do
    if block.role == "user" or block.role == "agent" then
      local calls = M.extract_tool_calls(block.content, {
        allow_fenced = block.role == "agent",
      })
      for _, call in ipairs(calls) do
        current_id = current_id + 1
        local paired_result = results_by_id[current_id]
        if not paired_result and #unmatched_results > 0 then
          paired_result = table.remove(unmatched_results, 1)
          paired_result.id = current_id
        end

        table.insert(pairs, {
          id = current_id,
          tool = call,
          block_index = b_idx,
          result = paired_result
        })
      end
    end
  end

  return pairs
end

return M
