-- lua/agentfile/init.lua
local parser = require("agentfile.parser")
local serializer = require("agentfile.serializer")
local state = require("agentfile.state")
local tools = require("agentfile.tools")
local client = require("agentfile.client")
local markers = require("agentfile.markers")
local agent_config = require("agentfile.agent_config")
local tool_result = require("agentfile.tool_result")
local loop = require("agentfile.loop")

local M = {}

M.register_tool = tools.register
M.register_strategy = loop.register
M.last_chat_path = "chat.agentfile"
M.defaults = {}

--- Default template for a newly created chat buffer.
---@return string[]
function M.default_template()
  return {
    "---",
    "host: http://localhost:9931/v1",
    "model: ggml-org/gemma-4-E2B-it-GGUF:Q8_0 # Gemma 4 (GGUF, Q8_0)",
    "context_window: 32768 # dùng cho [me](context used/limit)",
    "max_tokens: 2048 # giới hạn output, tránh model suy nghĩ vô hạn",
    "# temperature: 0.6 # khuyến nghị 0.5 - 0.7 cho model reasoning nhỏ",
    "# top_p: 0.95",
    "# presence_penalty: 0.2 # giảm lặp lại suy nghĩ (repetition loops)",
    "# thinking:",
    "#   budget_tokens: 1024 # giới hạn token suy nghĩ (OpenRouter / Anthropic)",
    "#   concise: true # ép model suy nghĩ ngắn gọn (< 150 từ)",
    "#   enabled: false # tắt suy nghĩ nếu không cần thiết",
    "#   keep_on_error: false # gửi lại [think] một lần khi tool vừa fail",
    "auto_run_tools: false",
    "agent:",
    "  enabled: true",
    "  max_steps: 4 # số lần gọi model cho mỗi yêu cầu",
    "  max_format_errors: 3 # dừng khi model trả lời hỏng liên tiếp (0 = không giới hạn)",
    "  # wall_time_limit: 300 # giây cho mỗi yêu cầu (0 = không giới hạn)",
    "# retries: 2 # thử lại khi 429/5xx/mất kết nối",
    "# retry_delay_ms: 1000",
    "# include_usage: true # bật để hiển thị số token thật trong meter (một số server GGUF không hỗ trợ)",
    "# tool_mode: text # text (mặc định) hoặc native (dùng tool_calls của API)",
    "# planner: plan_first # react (mặc định) hoặc plan_first (lập kế hoạch trước khi gọi tool)",
    "# executor: parallel_reads # sequential (mặc định) hoặc parallel_reads (chạy song song tool read-only)",
    "# memory:",
    "#   enabled: true",
    "#   path: .agentfile/memory.md",
    "#   max_chars: 1200",
    "#   require_approval: true",
    "skills: [read_file, write_file, edit_file, run_command, list_files, done]",
    "---",
    "",
    markers.format("system"),
    "You are a coding assistant working directly in Neovim in the project's current working directory.",
    "You can read files, inspect directories, write/edit files, and run shell commands using the available tools.",
    "",
    "Workflow:",
    "1. Locate the relevant files with @list_files, then read them with @read_file. Never guess file contents.",
    "2. Reproduce the problem when possible (run the failing test/command) before changing code.",
    "3. Make the smallest change. Use @edit_file for a unique target and @write_file for a full rewrite.",
    "4. Verify with the relevant test, lint or build command, and inspect the result.",
    "5. If a tool fails, state the root cause in one sentence in [think], then change your approach. Never repeat an identical failing call.",
    "6. Use at most ONE file-modifying or command tool per turn; batch only read-only calls.",
    "7. When the task is complete and verified, call @done({\"summary\": \"what changed and how it was verified\"}) as the only call in that turn.",
    "8. Keep responses concise: which files you read or changed, and what verification proved it.",
    "9. For read/understand/explain requests, only inspect files; do not edit files or run programs unless requested.",
    "10. For multi-line code or scripts, use a heredoc body instead of escaping it into a JSON string:",
    "    @write_file({\"path\": \"src/main.go\"}) <<'EOF'",
    "    package main",
    "    func main() { println(\"hi\") }",
    "    EOF",
    "",
    markers.format("me"),
    ""
  }
end

--- Make a buffer behave like an Agentfile chat: filetype markdown (so
--- markdown/rendering plugins work normally) plus Agentfile highlighting,
--- folding and keymaps.
---@param bufnr number
local function attach_agentfile_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.bo[bufnr].filetype ~= "markdown" then
    vim.bo[bufnr].filetype = "markdown"
  end

  -- Keep marker highlighting even though the filetype is markdown.
  if vim.bo[bufnr].syntax ~= "agentfile" then
    vim.bo[bufnr].syntax = "agentfile"
  end

  -- Safe to call repeatedly: window options are re-applied and the marker
  -- syntax is guarded inside setup_buffer.
  require("agentfile.ui").setup_buffer(bufnr)

  local config = select(1, parser.parse_frontmatter(
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  ))
  M.update_context_marker(bufnr, config)
end

--- Open (or focus) a chat buffer, creating the default template if needed.
---@param path? string
---@return number bufnr
function M.open(path)
  path = path or M.last_chat_path or "chat.agentfile"
  M.last_chat_path = path

  local target_full = vim.fn.fnamemodify(path, ":p")
  local target_buf = nil

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == target_full then
      target_buf = buf
      break
    end
  end

  if target_buf then
    local win = vim.fn.bufwinid(target_buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    else
      vim.api.nvim_set_current_buf(target_buf)
    end
  else
    -- `hide` avoids E37 when the source buffer has unsaved changes.
    vim.cmd("hide edit " .. vim.fn.fnameescape(path))
    target_buf = vim.api.nvim_get_current_buf()
  end

  local lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
  if #lines <= 1 and (lines[1] or "") == "" then
    local template = M.default_template()
    vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, template)
    vim.api.nvim_win_set_cursor(0, { #template, 0 })
  end

  attach_agentfile_buffer(target_buf)

  local config = select(1, parser.parse_frontmatter(
    vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
  ))
  M.update_context_marker(target_buf, config)

  return target_buf
end

--- Append text lines to the chat buffer, creating a [me] block when needed.
---@param chat_buf number
---@param text_lines string[]
local function append_chat_lines(chat_buf, text_lines)
  local chat_lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
  local _, end_fm = parser.parse_frontmatter(chat_lines)
  local blocks = parser.parse_blocks(chat_lines, end_fm + 1)

  local to_add = {}
  if #chat_lines > 0 and chat_lines[#chat_lines] ~= "" then
    table.insert(to_add, "")
  end
  local last = blocks[#blocks]
  if not last or last.role ~= "user" then
    table.insert(to_add, markers.format("me"))
    table.insert(to_add, "")
  end

  vim.list_extend(to_add, text_lines)
  table.insert(to_add, "")

  vim.api.nvim_buf_set_lines(chat_buf, -1, -1, false, to_add)

  local new_count = vim.api.nvim_buf_line_count(chat_buf)
  pcall(vim.api.nvim_win_set_cursor, 0, { new_count, 0 })

  local config = select(1, parser.parse_frontmatter(
    vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
  ))
  M.update_context_marker(chat_buf, config)
end

local MAX_SELECTION_LINES = 200
local MAX_CONTEXT_LINES = 200
local MAX_CONTEXT_FILES = 20
local MAX_CONTEXT_BYTES = 512 * 1024

--- Build a fenced snippet for a file/context entry.
---@param display string
---@param ft string
---@param lines string[]
---@param truncated? boolean
---@return string[]
local function make_file_snippet(display, ft, lines, truncated)
  local lang = (ft or ""):match("^[^%.]+") or "text"
  if lang == "" then
    lang = "text"
  end

  local header = string.format("File: `%s`", display)
  if truncated then
    header = header .. string.format(" (first %d lines)", MAX_CONTEXT_LINES)
  end

  local out = { header, "", "```" .. lang }
  vim.list_extend(out, lines)
  table.insert(out, "```")
  return out
end

--- Find a loaded buffer with the given full path.
---@param full_path string
---@return number|nil
local function find_buffer_by_name(full_path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == full_path then
      return buf
    end
  end
  return nil
end

--- Add one or more files as context to the chat buffer.
--- With no paths, the current buffer is used (including unsaved changes).
--- Globs are supported, e.g. `require("agentfile").add_context({ "lua/**/*.lua" })`.
---@param paths? string[]|string
---@return number added
function M.add_context(paths)
  if type(paths) == "string" then
    paths = vim.split(paths, "%s+", { trimempty = true })
  end
  paths = paths or {}

  local chat_path = M.last_chat_path or "chat.agentfile"
  local chat_full = vim.fn.fnamemodify(chat_path, ":p")
  local src_buf = vim.api.nvim_get_current_buf()

  local snippets = {}
  local skipped = {}
  local seen = {}
  local file_count = 0

  local function add_snippet(display, ft, lines)
    if file_count >= MAX_CONTEXT_FILES then
      return
    end
    if #lines > MAX_CONTEXT_LINES then
      lines = vim.list_slice(lines, 1, MAX_CONTEXT_LINES)
      vim.list_extend(snippets, make_file_snippet(display, ft, lines, true))
    else
      vim.list_extend(snippets, make_file_snippet(display, ft, lines, false))
    end
    file_count = file_count + 1
  end

  if #paths == 0 then
    -- Current buffer: include in-memory content so unsaved work is sent.
    local name = vim.api.nvim_buf_get_name(src_buf)
    if name == chat_full then
      vim.notify("[agentfile] Current buffer is already the chat buffer.", vim.log.levels.WARN)
      return 0
    end
    local display = name ~= "" and vim.fn.fnamemodify(name, ":.") or "[No Name]"
    local lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
    add_snippet(display, vim.bo[src_buf].filetype, lines)
  else
    -- Expand globs
    local expanded = {}
    for _, path in ipairs(paths) do
      if path:find("[*?[]") then
        local matches = vim.fn.glob(path, false, true)
        if #matches == 0 then
          table.insert(skipped, path .. " (no matches)")
        else
          vim.list_extend(expanded, matches)
        end
      else
        table.insert(expanded, path)
      end
    end

    for _, path in ipairs(expanded) do
      if file_count >= MAX_CONTEXT_FILES then
        table.insert(skipped, string.format("(limit: only %d files)", MAX_CONTEXT_FILES))
        break
      end

      local full = vim.fn.fnamemodify(path, ":p")
      if full == chat_full then
        table.insert(skipped, path .. " (chat buffer)")
      elseif not seen[full] then
        seen[full] = true
        local display = vim.fn.fnamemodify(full, ":.")
        local size = vim.fn.getfsize(full)

        if vim.fn.filereadable(full) == 0 then
          table.insert(skipped, path .. " (not readable)")
        elseif vim.fn.isdirectory(full) == 1 then
          table.insert(skipped, path .. " (directory)")
        elseif size > MAX_CONTEXT_BYTES then
          table.insert(skipped, path .. " (larger than 512KB)")
        else
          local lines
          local src = find_buffer_by_name(full)
          if src then
            lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
          else
            lines = vim.fn.readfile(full, "", MAX_CONTEXT_LINES + 1)
          end

          if not lines then
            table.insert(skipped, path .. " (could not read)")
          elseif table.concat(lines, "\n"):find("%z") then
            table.insert(skipped, path .. " (binary file)")
          else
            local ft = vim.filetype.match({ filename = full }) or vim.fn.fnamemodify(full, ":e")
            add_snippet(display, ft, lines)
          end
        end
      end
    end
  end

  if #snippets == 0 then
    local reason = #skipped > 0 and (": " .. table.concat(skipped, ", ")) or ""
    vim.notify("[agentfile] No context files added" .. reason, vim.log.levels.WARN)
    return 0
  end

  local chat_buf = M.open(chat_path)
  append_chat_lines(chat_buf, snippets)

  local added = file_count

  local msg = string.format("[agentfile] Added %d file(s) as context.", added)
  if #skipped > 0 then
    msg = msg .. " Skipped: " .. table.concat(skipped, ", ")
  end
  vim.notify(msg, vim.log.levels.INFO)
  return added
end

--- Send the current visual selection to the chat buffer.
--- Modes:
---   "snippet" (default): paste the selected lines as a fenced code block
---   "tool": insert an @read_file call referencing the file + line range
---@param opts? table # { mode = "snippet"|"tool" }
function M.send_selection(opts)
  opts = opts or {}
  local mode = opts.mode or "snippet"

  local src_buf = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.getpos("'<")[2]
  local end_line = vim.fn.getpos("'>")[2]

  if start_line == 0 or end_line == 0 then
    vim.notify("[agentfile] No visual selection found.", vim.log.levels.WARN)
    return
  end
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local total_lines = end_line - start_line + 1
  local selected = vim.api.nvim_buf_get_lines(src_buf, start_line - 1, end_line, false)

  if #selected > MAX_SELECTION_LINES then
    selected = vim.list_slice(selected, 1, MAX_SELECTION_LINES)
    table.insert(selected, string.format("... [truncated: %d more lines]", total_lines - MAX_SELECTION_LINES))
  end

  local full_name = vim.api.nvim_buf_get_name(src_buf)
  local display_name = full_name ~= "" and vim.fn.fnamemodify(full_name, ":.") or "[No Name]"
  local ft = vim.bo[src_buf].filetype
  local lang = (ft:match("^[^%.]+") or "text")

  local insert_lines = {}

  if mode == "tool" then
    if full_name == "" then
      vim.notify("[agentfile] Cannot use tool mode on an unnamed buffer.", vim.log.levels.WARN)
      return
    end
    local args = vim.json.encode({
      path = display_name,
      start_line = start_line,
      end_line = end_line,
    })
    table.insert(insert_lines, "@read_file(" .. args .. ")")
  else
    table.insert(insert_lines, string.format("File: `%s` (lines %d-%d)", display_name, start_line, end_line))
    table.insert(insert_lines, "")
    table.insert(insert_lines, "```" .. lang)
    vim.list_extend(insert_lines, selected)
    table.insert(insert_lines, "```")
  end

  local chat_path = M.last_chat_path or "chat.agentfile"
  local chat_buf = M.open(chat_path)
  append_chat_lines(chat_buf, insert_lines)
end

--- Scroll all windows displaying bufnr to the bottom
local function scroll_to_bottom(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local last_line = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ""
      pcall(vim.api.nvim_win_set_cursor, win, { line_count, #last_line })
    end
  end
end

--- Append text to buffer with 30ms flush buffer support
local function create_buffer_writer(bufnr)
  local queue = ""
  local timer = vim.uv.new_timer()

  local function flush()
    if #queue == 0 or not vim.api.nvim_buf_is_valid(bufnr) then return end
    local text = queue
    queue = ""

    local lines = vim.split(text, "\n")
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local last_line = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ""

    lines[1] = last_line .. lines[1]
    vim.api.nvim_buf_set_lines(bufnr, line_count - 1, line_count, false, lines)

    -- Auto scroll to bottom as chunks stream in
    scroll_to_bottom(bufnr)
  end

  timer:start(30, 30, vim.schedule_wrap(flush))

  return {
    write = function(chunk)
      queue = queue .. chunk
    end,
    close = function()
      flush()
      timer:stop()
      timer:close()
    end
  }
end

--- Append a new block header to buffer (e.g. >>think, >>agent, >>me)
local function append_block_header(bufnr, header)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)
  local last_line = lines[1] or ""

  local to_add = {}
  if last_line ~= "" then
    table.insert(to_add, "")
  end

  table.insert(to_add, header)
  table.insert(to_add, "")

  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, to_add)
  scroll_to_bottom(bufnr)
end

--- Append a block header followed by text content.
local function append_text_block(bufnr, header, text)
  append_block_header(bufnr, header)
  if text and text ~= "" then
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, line_count - 1, line_count, false, vim.split(text, "\n"))
  end
  scroll_to_bottom(bufnr)
end

--- Ensure the buffer ends with an empty [me] block so the user can retry.
local function ensure_me_block(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local _, end_fm = parser.parse_frontmatter(lines)
  local blocks = parser.parse_blocks(lines, end_fm + 1)
  local last = blocks[#blocks]
  if last and last.role == "user" and last.content == "" then
    return
  end
  append_block_header(bufnr, markers.format("me"))
end

local DEFAULT_CONTEXT_WINDOW = 32768

--- Build the system-side prompt with environment info plus available tools.
--- Relative tool paths resolve from Neovim's current working directory.
---@param config table
---@return string
local function build_tools_prompt(config)
  local tools_prompt = tools.get_schema_prompt(config.skills)
  local env = string.format(
    "Current working directory: %s\nRelative paths used by tools are resolved from this directory.",
    vim.fn.getcwd()
  )
  env = env .. "\nFor read/understand/explain requests, only inspect files; do not write, edit, or run programs unless requested."
    .. "\nListing a directory does not change the working directory. Use returned paths exactly: settings/settings.go, not settings.go."
    .. "\nTo understand a project, prioritize README, module/build files and source files. Read chat transcripts only if relevant to the request."
    .. "\nDo not read the active chat file: this conversation is already in context. Entries marked [directory] require list_files, not read_file."
    .. "\nWait for results of all tool calls before choosing the next action. Do not repeat a successful read unless needed."
    .. "\nUse list_files for directories, read_file for files. Summarize when you have enough information."

  local parts = { env }
  if tools_prompt and tools_prompt ~= "" then
    parts[#parts + 1] = tools_prompt
  end

  -- Distilled, human-approved lessons from previous failures in this project.
  local memory_prompt = require("agentfile.memory").prompt_text(config)
  if memory_prompt ~= "" then
    parts[#parts + 1] = memory_prompt
  end

  return table.concat(parts, "\n\n")
end

--- Whether failed [think] blocks should be replayed once on the next request.
---@param config table
---@return boolean
local function keep_think_on_error(config)
  if config.thinking_keep_on_error == true then
    return true
  end
  return type(config.thinking) == "table" and config.thinking.keep_on_error == true
end

--- Total characters in a serialized payload (proxy for token count).
---@param messages table[]
---@return number
local function payload_chars(messages)
  local chars = 0
  for _, msg in ipairs(messages or {}) do
    chars = chars + vim.fn.strchars(msg.content or "") + 16
  end
  return chars
end

--- Rough token estimate, calibrated with the provider's real usage when known.
---@param messages table[]
---@param chars_per_token? number
---@return number
local function estimate_context_tokens(messages, chars_per_token)
  local cpt = tonumber(chars_per_token) or 4
  if cpt <= 0 then cpt = 4 end
  return math.ceil(payload_chars(messages) / cpt)
end

--- Rewrite the latest [me] line with an inline context-size suffix:
---   [me](context 1234/8192)
--- The suffix is UI only and is stripped by the parser.
---@param bufnr number
---@param config? table # frontmatter config (uses context_window/max_context)
function M.update_context_marker(bufnr, config)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  config = config or {}

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local _, end_fm = parser.parse_frontmatter(lines)
  local blocks = parser.parse_blocks(lines, end_fm + 1)

  local target = nil
  for i = #blocks, 1, -1 do
    if blocks[i].role == "user" then
      target = blocks[i]
      break
    end
  end
  if not target then
    return
  end

  local buf_state = state.get(bufnr)
  local tools_prompt = build_tools_prompt(config)
  local messages = serializer.serialize_messages(blocks, tools_prompt, config.max_turns, {
    keep_think_on_error = keep_think_on_error(config),
  })
  local used = estimate_context_tokens(messages, buf_state.chars_per_token)
  local limit = tonumber(config.context_window)
    or tonumber(config.max_context)
    or DEFAULT_CONTEXT_WINDOW

  local extras = {}
  local agent = select(1, agent_config.resolve(config))
  if agent and agent.enabled and (buf_state.agent_steps or 0) > 0 then
    extras[#extras + 1] = string.format("step %d/%d", buf_state.agent_steps, agent.max_steps)
  end
  if buf_state.turn_started_at then
    local now = (vim.uv or vim.loop).now()
    extras[#extras + 1] = string.format("%ds", math.max(0, math.floor((now - buf_state.turn_started_at) / 1000)))
  end
  local detail = #extras > 0 and (" · " .. table.concat(extras, " · ")) or ""
  local suffix = string.format("(context %d/%d%s)", used, limit, detail)
  local new_line = markers.format("me") .. suffix

  if lines[target.start_line] == new_line then
    return
  end

  local was_modified = vim.bo[bufnr].modified
  local was_suppressed = buf_state.suppress_save_hook
  buf_state.suppress_save_hook = true
  local ok = pcall(
    vim.api.nvim_buf_set_lines,
    bufnr,
    target.start_line - 1,
    target.start_line,
    false,
    { new_line }
  )
  buf_state.suppress_save_hook = was_suppressed

  -- Updating our own meter must not leave a clean buffer marked as modified.
  if ok and not was_modified then
    pcall(function()
      vim.bo[bufnr].modified = false
    end)
  end
end

--- Show a request/connection error directly in the buffer using the error marker.
---@param bufnr number
---@param err string|table
function M.show_error(bufnr, err)
  local message = tostring(err or "Unknown error")
  local buf_state = state.get(bufnr)

  -- A cancelled request is not an error the user needs to see.
  if buf_state.cancelled then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("[agentfile] " .. message, vim.log.levels.ERROR)
    return
  end

  local was_suppressed = buf_state.suppress_save_hook
  buf_state.suppress_save_hook = true
  append_text_block(bufnr, markers.format("error"), message)
  ensure_me_block(bufnr)
  buf_state.suppress_save_hook = was_suppressed

  local config = select(1, parser.parse_frontmatter(
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  ))
  M.update_context_marker(bufnr, config)

  vim.notify("[agentfile] " .. message, vim.log.levels.ERROR)
end

--- Convert native tool_call deltas into the same shape as parsed @tool calls.
---@param native table[]|nil
---@return table[]
local function calls_from_native(native)
  local calls = {}
  for _, tc in ipairs(native or {}) do
    local fn = type(tc) == "table" and tc["function"] or nil
    local name = fn and fn.name or nil
    if name and name ~= "" then
      local args = {}
      if type(fn.arguments) == "string" and fn.arguments ~= "" then
        local ok, decoded = pcall(vim.json.decode, fn.arguments)
        if ok and type(decoded) == "table" then
          args = decoded
        end
      end
      calls[#calls + 1] = {
        name = name,
        args = args,
        raw = "@" .. name .. "(" .. tostring(fn.arguments or "{}") .. ")",
        native = true,
        id = tc.id,
      }
    end
  end
  return calls
end

--- Write native tool calls into the transcript so it stays the source of truth.
---@param bufnr number
---@param calls table[]
local function render_native_calls(bufnr, calls)
  if #calls == 0 then return end
  local lines = {}
  for _, call in ipairs(calls) do
    lines[#lines + 1] = tostring(call.raw or ""):gsub("[\r\n]+", " ")
  end
  append_text_block(bufnr, markers.format("agent"), table.concat(lines, "\n"))
end

--- Count repeated failures and offer a distilled lesson to project memory.
---@param bufnr number
---@param call table
---@param result_text string
---@param config table
local function note_failure(bufnr, call, result_text, config)
  local memory = require("agentfile.memory")
  local opts = memory.resolve(config)
  if not opts.enabled or not opts.remember_repeated_failures then
    return
  end

  local buf_state = state.get(bufnr)
  local sig = memory.signature(call.name, result_text)
  local count = (buf_state.failure_counts[sig] or 0) + 1
  buf_state.failure_counts[sig] = count
  if count < 2 or buf_state.memory_offered[sig] then
    return
  end
  buf_state.memory_offered[sig] = true

  local text = tostring(result_text or ""):gsub("[\r\n]+", " "):sub(1, 160)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    memory.propose(opts, {
      tool = call.name,
      text = "Failed twice with the same cause. " .. text,
      source = "repeated_failure",
    })
  end)
end

--- Stop or retry after an invalid/truncated model response.
---@param bufnr number
---@param config table
---@param agent table|nil
---@param buf_state table
---@param reason string
local function retry_format_error(bufnr, config, agent, buf_state, reason)
  buf_state.format_errors = (buf_state.format_errors or 0) + 1
  buf_state.last_format_error = reason
  local max_errors = (agent and agent.max_format_errors) or 3

  if max_errors > 0 and buf_state.format_errors >= max_errors then
    buf_state.exit_status = "format_error"
    M.show_error(bufnr, string.format(
      "Repeated invalid responses (%d/%d): %s. Send a new [me] request to continue.",
      buf_state.format_errors, max_errors, reason
    ))
    return
  end

  vim.notify(string.format(
    "[agentfile] %s Asking the model to retry (%d/%s).",
    reason, buf_state.format_errors, max_errors > 0 and tostring(max_errors) or "∞"
  ), vim.log.levels.WARN)

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) and not state.get(bufnr).cancelled then
      M.send(bufnr)
    end
  end)
end

--- Main send trigger
---@param bufnr number
function M.send(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buf_state = state.get(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local file_config, end_fm = parser.parse_frontmatter(lines)
  local config = vim.tbl_deep_extend("force", {}, M.defaults or {}, file_config or {})
  local blocks = parser.parse_blocks(lines, end_fm + 1)

  if #blocks == 0 then return end

  -- A new send always clears a previous cancellation flag.
  buf_state.cancelled = false

  -- Clean up empty trailing [me] blocks if user typed under an earlier [me]
  while #blocks > 1 and blocks[#blocks].role == "user" and blocks[#blocks].content == "" do
    table.remove(blocks)
  end

  -- A new user prompt starts a fresh agent loop (tool-loop turns end with [result]).
  if blocks[#blocks] and blocks[#blocks].role == "user" then
    buf_state.iteration_count = 0
    buf_state.agent_steps = 0
    buf_state.format_errors = 0
    buf_state.last_format_error = nil
    buf_state.turn_started_at = (vim.uv or vim.loop).now()
    buf_state.exit_status = nil
    buf_state.submission = nil
  end

  local agent, config_error = agent_config.resolve(config)
  if not agent then
    M.show_error(bufnr, config_error)
    return
  end

  -- Wall-clock limit for one user request; the step budget alone does not
  -- protect against a slow model or a stuck command.
  if agent.enabled and agent.wall_time_limit > 0 and buf_state.turn_started_at then
    local elapsed = ((vim.uv or vim.loop).now() - buf_state.turn_started_at) / 1000
    if elapsed > agent.wall_time_limit then
      buf_state.exit_status = "time_exceeded"
      M.show_error(bufnr, string.format(
        "Reached agent.wall_time_limit (%ss). Send a new [me] request to continue.",
        agent.wall_time_limit
      ))
      return
    end
  end

  -- Check if user called a tool in their [me] prompt (e.g. @read_file(...)) that has no [result] yet
  local last_block = blocks[#blocks]
  if last_block and last_block.role == "user" then
    local pairs = parser.pair_tools_and_results(blocks)
    for _, pair in ipairs(pairs) do
      if pair.block_index == #blocks and not pair.result then
        -- Execute user-invoked tool before sending to LLM!
        state.transition(bufnr, "tools_running")
        tools.execute(pair.tool.name, pair.tool.args, function(ok, result)
          buf_state.suppress_save_hook = true
          local status = ok and "ok" or "error"
          append_block_header(bufnr, markers.format("result", { id = pair.id, status = status }))

          local line_count = vim.api.nvim_buf_line_count(bufnr)
          local result_lines = tool_result.lines(result)
          vim.api.nvim_buf_set_lines(bufnr, line_count - 1, line_count, false, result_lines)
          scroll_to_bottom(bufnr)
          buf_state.suppress_save_hook = false

          state.transition(bufnr, "idle")

          -- Automatically continue to send prompt with tool result included
          vim.schedule(function()
            M.send(bufnr)
          end)
        end, { id = pair.id, chat_path = vim.api.nvim_buf_get_name(bufnr), config = config })
        return
      end
    end
  end

  local is_compact_request = last_block and last_block.role == "user" and (last_block.content:match("^%s*/compact%s*$") or last_block.content:match("/compact"))

  if agent.enabled and (buf_state.agent_steps or 0) >= agent.max_steps then
    buf_state.exit_status = "limits_exceeded"
    M.show_error(bufnr, "Reached agent.max_steps (" .. agent.max_steps .. "). Send a new [me] request to continue.")
    return
  end

  -- Transition state
  if not state.transition(bufnr, "streaming") then
    -- Maybe currently idle -> parsing -> streaming
    state.transition(bufnr, "parsing")
    if not state.transition(bufnr, "streaming") then
      vim.notify("[agentfile] Buffer is busy: " .. buf_state.status, vim.log.levels.WARN)
      return
    end
  end

  state.record_sent(bufnr, lines)
  buf_state.agent_steps = (buf_state.agent_steps or 0) + 1

  local messages
  if is_compact_request then
    -- Compact flow: instruct the model to produce a concise summary
    local history_messages = serializer.serialize_messages(blocks, nil, nil)
    -- Remove the /compact command itself from history
    table.remove(history_messages)

    messages = {
      {
        role = "system",
        content = "You are an expert summarizer. Summarize the key facts, decisions, file modifications, and current context from the conversation so far in concise bullet points. This summary will replace older history to save context."
      }
    }
    for _, msg in ipairs(history_messages) do
      table.insert(messages, msg)
    end
    table.insert(messages, {
      role = "user",
      content = "Please summarize all essential points of our conversation so far into a concise summary block."
    })
  else
    -- Standard turn flow
    local tools_prompt = build_tools_prompt(config)
    local max_turns = config.max_turns -- optional sliding window limit
    messages = serializer.serialize_messages(blocks, tools_prompt, max_turns, {
      keep_think_on_error = keep_think_on_error(config),
    })

    -- Delegate system-prompt augmentation to the configured planner strategy
    -- (progress note, thinking controls, recovery nudges, optional plan).
    local augment = loop.run_planner({
      bufnr = bufnr,
      config = config,
      agent = agent,
      buf_state = buf_state,
      blocks = blocks,
    })
    if augment ~= "" then
      messages[1].content = messages[1].content .. "\n\n" .. augment
    end
  end

  -- Show the context size of the payload we are about to send.
  buf_state.payload_chars = payload_chars(messages)
  M.update_context_marker(bufnr, config)

  local current_section = nil -- "think" | "agent"
  local writer = create_buffer_writer(bufnr)
  local full_agent_text = ""

  -- Temporarily disable save hook while writing
  buf_state.suppress_save_hook = true
  buf_state.writer = writer

  local callbacks = {
    on_think_chunk = function(chunk)
      if current_section ~= "think" then
        current_section = "think"
        writer.close()
        append_block_header(bufnr, markers.format("think"))
        writer = create_buffer_writer(bufnr)
        buf_state.writer = writer
      end
      writer.write(chunk)
    end,
    on_agent_chunk = function(chunk)
      if current_section ~= "agent" then
        current_section = "agent"
        writer.close()
        append_block_header(bufnr, markers.format("agent"))
        writer = create_buffer_writer(bufnr)
        buf_state.writer = writer
      end
      full_agent_text = full_agent_text .. chunk
      writer.write(chunk)
    end,
    on_usage = function(usage)
      if type(usage) ~= "table" then return end
      buf_state.usage = usage
      local prompt_tokens = tonumber(usage.prompt_tokens)
      if prompt_tokens and prompt_tokens > 0 and (buf_state.payload_chars or 0) > 0 then
        -- Calibrate the character/4 estimate with the provider's real count.
        buf_state.chars_per_token = buf_state.payload_chars / prompt_tokens
      end
      buf_state.total_prompt_tokens = (buf_state.total_prompt_tokens or 0) + (prompt_tokens or 0)
      buf_state.total_completion_tokens = (buf_state.total_completion_tokens or 0)
        + (tonumber(usage.completion_tokens) or 0)
    end,
    on_retry = function(attempt, delay, reason)
      vim.notify(string.format(
        "[agentfile] %s. Retrying in %dms (attempt %d).", reason, delay, attempt + 1
      ), vim.log.levels.WARN)
    end,
    on_complete = function(info)
      info = info or {}
      writer.close()
      buf_state.writer = nil
      buf_state.active_job = nil
      buf_state.last_finish_reason = info.finish_reason

      if is_compact_request then
        -- Insert reset marker after summary so future turns only see the summary
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, {
          "",
          markers.format("reset"),
          ""
        })
        buf_state.format_errors = 0
        buf_state.exit_status = "completed"
        M.update_context_marker(bufnr, config)
        buf_state.suppress_save_hook = false
        state.transition(bufnr, "idle")
        return
      end

      local native_calls = calls_from_native(info.tool_calls)
      local tool_calls = {}
      local reason = nil

      if agent.enabled then
        if info.finish_reason == "length" then
          -- A truncated response may contain half a tool call; never run it.
          reason = "response was cut off by max_tokens (finish_reason=length)"
        else
          tool_calls = native_calls
          if #tool_calls == 0 then
            tool_calls = parser.extract_tool_calls(full_agent_text, { allow_fenced = true })
          end
          if #tool_calls == 0 and full_agent_text:gsub("%s", "") == "" then
            reason = "model returned an empty response"
          end
        end
      end

      if reason then
        buf_state.suppress_save_hook = false
        state.transition(bufnr, "idle")
        M.update_context_marker(bufnr, config)
        retry_format_error(bufnr, config, agent, buf_state, reason)
        return
      end

      -- A clean response resets the consecutive-invalid counter.
      buf_state.format_errors = 0
      buf_state.last_format_error = nil

      -- Native calls are rendered into the transcript so the buffer remains
      -- the source of truth for the next turn.
      if #native_calls > 0 and not full_agent_text:find("@", 1, true) then
        render_native_calls(bufnr, native_calls)
      end

      -- Tools must be handled before starting a new [me] block, otherwise the
      -- [result] would be appended after it.
      if #tool_calls == 0 then
        -- Nothing left to run: start a new turn for the user.
        buf_state.exit_status = "completed"
        append_block_header(bufnr, markers.format("me"))
        scroll_to_bottom(bufnr)

        -- Refresh the meter with the response included (it is the context of
        -- the next turn). The latest [me] line carries the suffix.
        M.update_context_marker(bufnr, config)
        buf_state.suppress_save_hook = false
        state.transition(bufnr, "idle")
        return
      end

      local batch_ok, batch_err = tools.validate_batch(tool_calls)
      if not batch_ok then
        buf_state.suppress_save_hook = false
        state.transition(bufnr, "idle")
        M.update_context_marker(bufnr, config)
        retry_format_error(bufnr, config, agent, buf_state, batch_err)
        return
      end

      M.update_context_marker(bufnr, config)
      buf_state.suppress_save_hook = false
      state.transition(bufnr, "idle")
      M.handle_tool_calls(bufnr, tool_calls, config)
    end,
    on_error = function(err)
      writer.close()
      buf_state.writer = nil
      buf_state.active_job = nil
      buf_state.exit_status = "error"
      buf_state.suppress_save_hook = false
      state.transition(bufnr, "idle")
      M.show_error(bufnr, err)
    end
  }

  local request_config = config
  if config.tool_mode == "native" then
    request_config = vim.tbl_extend("force", {}, config)
    request_config.tools = tools.schemas(config.skills)
    request_config.tool_choice = config.tool_choice or "auto"
  end

  buf_state.model_calls = (buf_state.model_calls or 0) + 1
  buf_state.active_job = client.stream_chat(request_config, messages, callbacks)
end

local function shorten_head(s, max)
  s = tostring(s or "")
  if #s <= max then
    return s
  end
  return s:sub(1, max - 3) .. "..."
end

local function shorten_tail(s, max)
  s = tostring(s or "")
  if #s <= max then
    return s
  end
  return "..." .. s:sub(-(max - 3))
end

--- One-line summary of a tool call for the [ask] marker.
---@param call table
---@return string
local function ask_summary(call)
  local name = call.name or "tool"
  local args = call.args or {}

  if name == "run_command" then
    return string.format("Run `%s`?", shorten_head(args.command, 80))
  elseif args.path ~= nil then
    -- Keep the file name visible even for long absolute paths.
    return string.format("Allow @%s on `%s`?", name, shorten_tail(args.path, 70))
  end
  return string.format("Allow @%s?", name)
end

--- Find an [ask] block (the last one, since only one tool is pending at a time).
---@param blocks table[]
---@return table|nil
local function find_ask_block(blocks)
  for i = #blocks, 1, -1 do
    if blocks[i].role == "ask" then
      return blocks[i]
    end
  end
  return nil
end

--- Read the answer from an [ask] block's marker line.
---@param block table
---@return string|nil answer, string|nil reason # "y", "n", "" (unanswered), "invalid", or nil
local function parse_ask_answer(block)
  local text = block.ask_text or ""
  local after = text:match("%(%s*[yY]/[nN]%s*%)%s*:%s*(.*)$")
  if after == nil then
    return nil, nil
  end

  after = (after:gsub("^%s*(.-)%s*$", "%1"))
  if after == "" then
    return "", nil
  end

  local lower = after:lower()
  if lower == "y" or lower == "yes" then
    return "y", nil
  end

  local n_word, reason = after:match("^([nN][oO]?)[%s:%-]*(.*)$")
  if n_word then
    reason = (reason:gsub("^%s*(.-)%s*$", "%1"))
    return "n", (reason ~= "" and reason or nil)
  end

  return "invalid", nil
end

--- Run a single tool call: explicit @done, approval gate, or execution.
--- Calls cb("continue" | "done" | "stop") to tell the executor how to proceed.
---@param bufnr number
---@param config table
---@param call table
---@param cb function # receives "continue" | "done" | "stop"
local function run_one_tool(bufnr, config, call, cb)
  local buf_state = state.get(bufnr)
  local tool_spec = tools.get(call.name)
  local is_dangerous = tool_spec and tool_spec.is_dangerous
  local auto_run = config.auto_run_tools

  buf_state.tool_counter = buf_state.tool_counter + 1
  local tool_id = buf_state.tool_counter

  -- Explicit completion. Without it, "no tool call" is ambiguous: the model may
  -- have finished, or it may have forgotten the tool syntax.
  if call.name == "done" then
    local summary = tostring(call.args.summary or ""):gsub("[\r\n]+", " ")
    summary = summary:gsub("%s+$", "")
    buf_state.exit_status = "submitted"
    buf_state.submission = summary

    buf_state.suppress_save_hook = true
    append_text_block(bufnr, markers.format("result", { id = tool_id, status = "ok" }),
      table.concat(tool_result.lines(summary ~= "" and summary or "Task marked complete."), "\n"))
    append_text_block(bufnr, markers.format("done"), summary ~= "" and summary or "Task complete.")
    ensure_me_block(bufnr)
    buf_state.suppress_save_hook = false

    state.transition(bufnr, "idle")
    M.update_context_marker(bufnr, config)
    cb("done")
    return
  end

  if is_dangerous and not auto_run then
    -- Keep an audit/result slot in the chat; approval happens in Neovim UI.
    buf_state.suppress_save_hook = true
    append_text_block(bufnr, markers.format("result", { id = tool_id, status = "pending" }),
      table.concat(tool_result.lines("Waiting for approval in Neovim."), "\n"))
    buf_state.suppress_save_hook = false
    buf_state.pending_tool = {
      id = tool_id,
      call = call,
      config = config,
      resume = cb,
    }
    state.transition(bufnr, "awaiting_approval")
    local pending = buf_state.pending_tool
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) or buf_state.cancelled
        or buf_state.pending_tool ~= pending then return end
      vim.ui.select({ "Deny", "Allow" }, {
        prompt = "Agentfile: " .. ask_summary(call),
      }, function(choice)
        if not vim.api.nvim_buf_is_valid(bufnr) or buf_state.cancelled
          or buf_state.pending_tool ~= pending then return end
        if choice == "Allow" then
          M.approve_tool(bufnr)
        else
          M.reject_tool(bufnr)
        end
      end)
    end)
    return
  end

  -- Auto-run or read-only tool
  tools.execute(call.name, call.args, function(ok, result)
    if buf_state.cancelled or not vim.api.nvim_buf_is_valid(bufnr) then return end
    buf_state.suppress_save_hook = true
    local status = ok and "ok" or "error"
    append_block_header(bufnr, markers.format("result", { id = tool_id, status = status }))

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local result_lines = tool_result.lines(result)
    vim.api.nvim_buf_set_lines(bufnr, line_count - 1, line_count, false, result_lines)
    scroll_to_bottom(bufnr)
    buf_state.suppress_save_hook = false

    if not ok then
      note_failure(bufnr, call, result, config)
    end

    cb("continue")
  end, { id = tool_id, chat_path = vim.api.nvim_buf_get_name(bufnr), config = config })
end

--- Handle tool calls emitted by the agent, delegating order/parallelism to the
--- configured executor strategy.
---@param bufnr number
---@param tool_calls table[]
---@param config table
function M.handle_tool_calls(bufnr, tool_calls, config)
  local buf_state = state.get(bufnr)
  if buf_state.cancelled or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if #tool_calls == 0 then return end
  buf_state.iteration_count = buf_state.iteration_count + 1

  state.transition(bufnr, "tools_running")

  local agent = select(1, agent_config.resolve(config))
  loop.run_executor({
    bufnr = bufnr,
    config = config,
    agent = agent,
    buf_state = buf_state,
    calls = tool_calls,
    run_one = function(call, cb)
      run_one_tool(bufnr, config, call, cb)
    end,
    finish = function()
      state.transition(bufnr, "idle")
      M.send(bufnr)
    end,
  })
end

--- Find a result block by id (and optionally status).
---@param lines string[]
---@param id number
---@param status? string
---@return table|nil
local function find_result_block(lines, id, status)
  local _, end_fm = parser.parse_frontmatter(lines)
  local blocks = parser.parse_blocks(lines, end_fm + 1)
  for _, block in ipairs(blocks) do
    if block.role == "result" and block.id == id then
      if not status or block.status == status then
        return block
      end
    end
  end
  return nil
end

--- Mark an [ask] block as stale (e.g. pending state was lost after a restart).
---@param bufnr number
---@param message string
---@return boolean replaced
local function invalidate_ask_block(bufnr, message)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local _, end_fm = parser.parse_frontmatter(lines)
  local block = find_ask_block(parser.parse_blocks(lines, end_fm + 1))
  if not block then
    return false
  end

  local was_suppressed = state.get(bufnr).suppress_save_hook
  state.get(bufnr).suppress_save_hook = true
  vim.api.nvim_buf_set_lines(bufnr, block.start_line - 1, block.end_line, false, {
    markers.format("error"),
    message,
  })
  ensure_me_block(bufnr)
  state.get(bufnr).suppress_save_hook = was_suppressed
  return true
end

--- Approve pending tool
function M.approve_tool(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buf_state = state.get(bufnr)
  if buf_state.status ~= "awaiting_approval" or not buf_state.pending_tool then
    local stale = invalidate_ask_block(
      bufnr,
      "This approval request is no longer active (pending tool state was lost). Re-send your prompt to try again."
    )
    vim.notify(
      stale and "[agentfile] Stale [ask] request cleared. Re-send your prompt."
        or "[agentfile] No pending tool call to approve.",
      vim.log.levels.WARN
    )
    return
  end

  local pending = buf_state.pending_tool
  local resume = pending.resume
  buf_state.pending_tool = nil
  state.transition(bufnr, "tools_running")

  tools.execute(pending.call.name, pending.call.args, function(ok, result)
    if buf_state.cancelled or not vim.api.nvim_buf_is_valid(bufnr) then return end
    buf_state.suppress_save_hook = true
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local _, end_fm = parser.parse_frontmatter(lines)
    local block = find_ask_block(parser.parse_blocks(lines, end_fm + 1))
      or find_result_block(lines, pending.id, "pending")
    if block then
      local status = ok and "ok" or "error"
      local replace_lines = {
        markers.format("result", { id = pending.id, status = status })
      }
      for _, rl in ipairs(tool_result.lines(result)) do
        table.insert(replace_lines, rl)
      end
      -- Replace only the ask/pending block, keep everything after it.
      vim.api.nvim_buf_set_lines(bufnr, block.start_line - 1, block.end_line, false, replace_lines)
    end
    buf_state.suppress_save_hook = false
    if resume then
      resume("continue")
    end
  end, { id = pending.id, chat_path = vim.api.nvim_buf_get_name(bufnr), config = pending.config })
end

--- Reject pending tool
---@param bufnr? number
---@param reason? string
function M.reject_tool(bufnr, reason)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buf_state = state.get(bufnr)
  if buf_state.status ~= "awaiting_approval" or not buf_state.pending_tool then
    if invalidate_ask_block(
      bufnr,
      "This approval request is no longer active (pending tool state was lost). Re-send your prompt to try again."
    ) then
      vim.notify("[agentfile] Stale [ask] request cleared. Re-send your prompt.", vim.log.levels.WARN)
    end
    return
  end

  local pending = buf_state.pending_tool
  buf_state.pending_tool = nil

  buf_state.suppress_save_hook = true
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local _, end_fm = parser.parse_frontmatter(lines)
  local block = find_ask_block(parser.parse_blocks(lines, end_fm + 1))
    or find_result_block(lines, pending.id, "pending")
  if block then
    local msg = "Tool execution was rejected by user."
    if reason and reason ~= "" then
      msg = "Tool execution was rejected by user: " .. reason
    end
    local replacement = { markers.format("result", { id = pending.id, status = "rejected" }) }
    vim.list_extend(replacement, tool_result.lines(msg))
    vim.api.nvim_buf_set_lines(bufnr, block.start_line - 1, block.end_line, false, replacement)
  end
  ensure_me_block(bufnr)
  buf_state.suppress_save_hook = false
  state.transition(bufnr, "idle")

  -- A human rejection reason is the highest-signal lesson we can persist:
  -- it is already validated by the person steering the agent.
  if reason and reason ~= "" and pending.call and pending.call.name ~= "done" then
    local memory = require("agentfile.memory")
    local opts = memory.resolve(pending.config or {})
    if opts.enabled and opts.remember_rejections then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          memory.propose(opts, {
            tool = pending.call.name,
            text = reason,
            source = "user_rejection",
          })
        end
      end)
    end
  end
end

--- Cancel ongoing request/stream
function M.cancel(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buf_state = state.get(bufnr)
  local had_job = buf_state.active_job ~= nil

  buf_state.cancelled = true
  buf_state.exit_status = "cancelled"

  if buf_state.writer then
    pcall(function() buf_state.writer.close() end)
    buf_state.writer = nil
  end

  if buf_state.active_job then
    pcall(function() buf_state.active_job:kill(9) end)
    buf_state.active_job = nil
  end
  buf_state.suppress_save_hook = false
  state.transition(bufnr, "idle")

  if had_job then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        buf_state.suppress_save_hook = true
        ensure_me_block(bufnr)
        buf_state.suppress_save_hook = false
      end
    end)
  end

  vim.notify("[agentfile] Request cancelled.", vim.log.levels.INFO)
end

--- Called on BufWritePost
function M.on_save(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local _, end_fm = parser.parse_frontmatter(lines)
  local blocks = parser.parse_blocks(lines, end_fm + 1)
  local last = blocks[#blocks]

  -- Answering an [ask] block is also done by saving the buffer.
  if last and last.role == "ask" then
    local answer, reason = parse_ask_answer(last)
    if answer == "y" then
      M.approve_tool(bufnr)
    elseif answer == "n" then
      M.reject_tool(bufnr, reason)
    elseif answer == "invalid" then
      vim.notify("[agentfile] Invalid answer. Edit the [ask] line to use y or n, then save.", vim.log.levels.WARN)
    elseif answer == nil then
      vim.notify("[agentfile] Could not read the answer. Keep (y/N): and add y or n, then save.", vim.log.levels.WARN)
    end
    -- Empty answer means "not answered yet": stay put.
    return
  end

  local should_send = state.should_trigger_send(bufnr, lines)
  if should_send then
    M.send(bufnr)
  end
end

local function find_cursor_tool_id(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local _, end_fm = parser.parse_frontmatter(lines)
  local blocks = parser.parse_blocks(lines, end_fm + 1)
  local cursor_l = vim.api.nvim_win_get_cursor(0)[1]

  -- Check if cursor is on a result block with an id
  for _, b in ipairs(blocks) do
    if cursor_l >= b.start_line and cursor_l <= b.end_line and b.role == "result" and b.id then
      return b.id, b
    end
  end

  -- Fallback: most recent result block with an id
  for i = #blocks, 1, -1 do
    local b = blocks[i]
    if b.role == "result" and b.id then
      return b.id, b
    end
  end

  return nil, nil
end

--- Revert file modification performed by tool under cursor (or latest tool).
---@param bufnr? number
function M.undo_tool(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local id, block = find_cursor_tool_id(bufnr)
  if not id then
    vim.notify("[agentfile] No tool [result] block found to undo.", vim.log.levels.WARN)
    return
  end

  local snapshot = require("agentfile.snapshot")
  local ok, msg = snapshot.revert(id)
  if not ok then
    vim.notify("[agentfile] " .. msg, vim.log.levels.WARN)
    return
  end

  if block then
    local buf_state = state.get(bufnr)
    buf_state.suppress_save_hook = true
    local path_info = snapshot.history[id] and snapshot.history[id].path or ""
    local lines = {
      markers.format("result", { id = id, status = "reverted" }),
      "(Tool modification reverted: " .. vim.fn.fnamemodify(path_info, ":.") .. ")"
    }
    vim.api.nvim_buf_set_lines(bufnr, block.start_line - 1, block.end_line, false, lines)
    buf_state.suppress_save_hook = false
  end

  vim.notify("[agentfile] " .. msg, vim.log.levels.INFO)
end

--- Show diff for file modification performed by tool under cursor (or latest tool).
---@param bufnr? number
function M.diff_tool(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local id = find_cursor_tool_id(bufnr)
  if not id then
    vim.notify("[agentfile] No tool [result] block found to diff.", vim.log.levels.WARN)
    return
  end

  local snapshot = require("agentfile.snapshot")
  local diff_text, err = snapshot.diff(id)
  if not diff_text then
    vim.notify("[agentfile] " .. (err or "No diff available"), vim.log.levels.WARN)
    return
  end

  local ui = require("agentfile.ui")
  ui.show_diff_split(diff_text, "Diff Tool #" .. tostring(id))
end

--- Create and open a new session file for a topic.
---@param topic? string
function M.new_session(topic)
  local session = require("agentfile.session")
  local path = session.generate_path(topic)
  M.open(path)
  vim.notify("[agentfile] Created session: " .. vim.fn.fnamemodify(path, ":."), vim.log.levels.INFO)
end

--- Pick and open an existing session in the project.
function M.pick_session()
  local session = require("agentfile.session")
  local files = session.list()
  if #files == 0 then
    vim.notify("[agentfile] No existing sessions found. Use :Agentfile or :AgentfileNew to start.", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, f in ipairs(files) do
    table.insert(items, vim.fn.fnamemodify(f, ":."))
  end

  vim.ui.select(items, { prompt = "Select Agentfile Session: " }, function(choice)
    if choice then
      M.open(choice)
    end
  end)
end

--- Branch current chat up to cursor line into a new session.
---@param topic? string
function M.branch_chat(topic)
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_l = vim.api.nvim_win_get_cursor(0)[1]
  local session = require("agentfile.session")
  local new_path = session.branch(bufnr, cursor_l, topic)
  M.open(new_path)
  vim.notify("[agentfile] Branched conversation to: " .. vim.fn.fnamemodify(new_path, ":."), vim.log.levels.INFO)
end

--- Toggle side-panel chat window.
---@param path? string
function M.toggle(path)
  local ui = require("agentfile.ui")
  ui.toggle_chat(path)
end

--- Ingest LSP diagnostics into chat.
---@param bufnr? number
function M.add_diagnostics(bufnr)
  local context_extra = require("agentfile.context_extra")
  local text = context_extra.get_diagnostics(bufnr)
  local chat_buf = M.open()
  append_chat_lines(chat_buf, vim.split(text, "\n", { plain = true }))
  vim.notify("[agentfile] Added LSP diagnostics to chat.", vim.log.levels.INFO)
end

--- Ingest Git diff into chat.
---@param staged_only? boolean
function M.add_git_diff(staged_only)
  local context_extra = require("agentfile.context_extra")
  local text = context_extra.get_git_diff(staged_only)
  local chat_buf = M.open()
  append_chat_lines(chat_buf, vim.split(text, "\n", { plain = true }))
  vim.notify("[agentfile] Added Git diff to chat.", vim.log.levels.INFO)
end

--- Export the current transcript as a machine-readable JSON trajectory.
---@param path? string
function M.export_trajectory(path)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local config, end_fm = parser.parse_frontmatter(lines)
  local blocks = parser.parse_blocks(lines, end_fm + 1)
  local merged = vim.tbl_deep_extend("force", {}, M.defaults or {}, config or {})
  local buf_state = state.get(bufnr)
  local agent = select(1, agent_config.resolve(merged))
  local trajectory = require("agentfile.trajectory")

  path = path or trajectory.default_path()
  local ok, result = trajectory.export(blocks, path, {
    config = merged,
    agent = agent,
    tools_prompt = build_tools_prompt(merged),
    serializer_opts = { keep_think_on_error = keep_think_on_error(merged) },
    usage = buf_state.usage,
    steps = buf_state.agent_steps,
    exit_status = buf_state.exit_status,
    submission = buf_state.submission,
  })

  if not ok then
    vim.notify("[agentfile] " .. result, vim.log.levels.ERROR)
    return
  end
  vim.notify(
    "[agentfile] Trajectory exported to " .. vim.fn.fnamemodify(result, ":."),
    vim.log.levels.INFO
  )
end

--- Open (and create if needed) the project memory file.
function M.open_memory()
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
  local config = select(1, parser.parse_frontmatter(lines))
  local merged = vim.tbl_deep_extend("force", {}, M.defaults or {}, config or {})
  local memory = require("agentfile.memory")
  local opts = memory.resolve(merged)
  -- The command is explicit user intent; allow it even when memory is disabled.
  opts.enabled = true
  local path = memory.open(opts)
  vim.notify(
    "[agentfile] Project memory: " .. vim.fn.fnamemodify(path, ":."),
    vim.log.levels.INFO
  )
end

--- Setup autocmds and keymaps
function M.setup(opts)
  opts = opts or {}
  M.defaults = opts.defaults or opts.config or {}
  markers.setup(opts.markers)
  local ui = require("agentfile.ui")

  local group = vim.api.nvim_create_augroup("AgentfileAutoCmds", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.agentfile",
    callback = function(ev)
      M.on_save(ev.buf)
    end
  })

  -- Any .agentfile file opened directly (not just via :Agentfile) gets the
  -- markdown filetype plus Agentfile features.
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWinEnter" }, {
    group = group,
    pattern = "*.agentfile",
    callback = function(ev)
      attach_agentfile_buffer(ev.buf)
    end
  })

  -- Backward compatibility for buffers already set to an older Agentfile
  -- filetype (e.g. agentfile.md from an existing config).
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "agentfile", "agentfile.md", "agentfile.markdown", "markdown.agentfile" },
    callback = function(ev)
      attach_agentfile_buffer(ev.buf)
    end
  })

  -- Fix buffers that were opened before this plugin/config was loaded.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and name:match("%.agentfile$") then
      attach_agentfile_buffer(buf)
    end
  end

  -- User commands
  vim.api.nvim_create_user_command("Agentfile", function(args)
    local path = args.args ~= "" and args.args or "chat.agentfile"
    M.open(path)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("AgentfileSelection", function(args)
    M.send_selection({ mode = args.args ~= "" and args.args or nil })
  end, { range = true, nargs = "?" })

  -- Global keymap for visual selection quick action: <leader>ac
  vim.keymap.set("v", "<leader>ac", ":<C-u>AgentfileSelection<CR>", {
    silent = true,
    desc = "Send selected lines to Agentfile chat",
  })

  -- Normal mode: add the current file as context
  vim.keymap.set("n", "<leader>af", function()
    M.add_context()
  end, { silent = true, desc = "Add current file as context to Agentfile chat" })

  -- Normal mode: prompt for one or more context files
  vim.keymap.set("n", "<leader>aF", function()
    vim.ui.input({ prompt = "Context files (space-separated, globs allowed): " }, function(input)
      if input and input ~= "" then
        M.add_context(vim.split(input, "%s+", { trimempty = true }))
      end
    end)
  end, { silent = true, desc = "Add files as context to Agentfile chat" })

  -- Keymaps for core features
  vim.keymap.set("n", "<leader>at", function() M.toggle() end, { silent = true, desc = "Toggle Agentfile side panel" })
  vim.keymap.set("n", "<leader>ad", function() M.add_diagnostics() end, { silent = true, desc = "Add LSP diagnostics to Agentfile" })
  vim.keymap.set("n", "<leader>ag", function() M.add_git_diff() end, { silent = true, desc = "Add git diff to Agentfile" })
  vim.keymap.set("n", "<leader>ab", function() M.branch_chat() end, { silent = true, desc = "Branch Agentfile conversation" })
  vim.keymap.set("n", "<leader>ae", function() M.export_trajectory() end, { silent = true, desc = "Export Agentfile trajectory as JSON" })
  vim.keymap.set("n", "<leader>am", function() M.open_memory() end, { silent = true, desc = "Open Agentfile project memory" })

  vim.api.nvim_create_user_command("AgentfileToggle", function(args)
    M.toggle(args.args ~= "" and args.args or nil)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("AgentfileNew", function(args)
    M.new_session(args.args ~= "" and args.args or nil)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("AgentfileSessions", function()
    M.pick_session()
  end, {})

  vim.api.nvim_create_user_command("AgentfileBranch", function(args)
    M.branch_chat(args.args ~= "" and args.args or nil)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("AgentfileDiag", function()
    M.add_diagnostics()
  end, {})

  vim.api.nvim_create_user_command("AgentfileGitDiff", function(args)
    local staged = args.args == "--cached" or args.args == "staged"
    M.add_git_diff(staged)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("AgentfileUndo", function()
    M.undo_tool(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command("AgentfileDiff", function()
    M.diff_tool(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command("AgentfileContext", function(args)
    M.add_context(args.fargs)
  end, { nargs = "*", complete = "file" })

  vim.api.nvim_create_user_command("AgentfileSend", function()
    M.send(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command("AgentfileCancel", function()
    M.cancel(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command("AgentfileApprove", function()
    M.approve_tool(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command("AgentfileReject", function(args)
    M.reject_tool(vim.api.nvim_get_current_buf(), args.args ~= "" and args.args or nil)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("AgentfileExport", function(args)
    M.export_trajectory(args.args ~= "" and args.args or nil)
  end, { nargs = "?", complete = "file" })

  vim.api.nvim_create_user_command("AgentfileMemory", function()
    M.open_memory()
  end, {})
end

return M
