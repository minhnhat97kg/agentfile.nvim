-- lua/agentfile/tools/search.lua
local truncate = require("agentfile.tools.truncate")

local M = {}
local uv = vim.uv or vim.loop

local DEFAULT_MAX_RESULTS = 100
local DEFAULT_MAX_FILES = 2000
local MAX_FILE_BYTES = 1024 * 1024

local SKIP_DIRS = {
  [".git"] = true,
  [".hg"] = true,
  [".svn"] = true,
  [".agentfile"] = true,
  [".venv"] = true,
  ["venv"] = true,
  ["node_modules"] = true,
}

local function normalize_root(path)
  path = type(path) == "string" and path or "."
  if path == "" then
    path = "."
  end
  local full = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  full = full:gsub("[/\\]+$", "")
  if full == "" then
    full = "/"
  end
  return vim.fs.normalize(full)
end

local function display_path(path)
  local rel = vim.fn.fnamemodify(path, ":.")
  return rel ~= "" and rel or path
end

local function is_ignored(path, root)
  local rel = path
  if path:sub(1, #root) == root then
    rel = path:sub(#root + 1):gsub("^[/\\]+", "")
  end
  for part in rel:gmatch("[^/\\]+") do
    if SKIP_DIRS[part] or part:sub(1, 1) == "." then
      return true
    end
  end
  return false
end

local function expand_glob(root, pattern)
  if vim.fn.isdirectory(root) == 0 then
    return vim.fn.filereadable(root) == 1 and { root } or {}
  end

  pattern = type(pattern) == "string" and pattern or ""
  if pattern == "" then
    pattern = "**/*"
  end
  -- `*.lua` means "any file named *.lua below the root", matching what users
  -- expect from a search tool. Patterns with a slash are used as-is.
  if not pattern:find("[/\\]", 1) then
    pattern = "**/" .. pattern
  end

  local matches = vim.fn.globpath(root, pattern, false, true)
  local out = {}
  for _, path in ipairs(matches) do
    local full = path
    if full:sub(1, 1) ~= "/" then
      full = root .. "/" .. full
    end
    full = vim.fs.normalize(full)
    if not is_ignored(full, root) then
      local readable = vim.fn.filereadable(full) == 1
      local directory = vim.fn.isdirectory(full) == 1
      if readable or directory then
        out[#out + 1] = full
      end
    end
  end
  table.sort(out)
  return out
end

local function read_lines(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > MAX_FILE_BYTES then
    return nil
  end

  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local data = file:read("*a")
  file:close()
  if not data or data:find("\0", 1, true) then
    return nil
  end
  return vim.split(data, "\n", { plain = true })
end

local function result_text(header, lines, footer, context)
  local text = table.concat(lines, "\n")
  if footer and footer ~= "" then
    text = text .. "\n" .. footer
  end
  text = header .. "\n" .. text
  return truncate.text(text, {
    max_chars = truncate.budget(context and context.config),
    hint = "Narrow the pattern or path, add a glob, or lower max_results.",
  })
end

--- Run ripgrep and return compact `path:line: text` results.
local function rg_grep(pattern, args, root, cb, context)
  local max_results = tonumber(args.max_results) or DEFAULT_MAX_RESULTS
  if max_results < 1 then max_results = 1 end
  local context_lines = tonumber(args.context_lines) or 0
  if context_lines < 0 then context_lines = 0 end

  local cmd = {
    "rg", "--json", "--color", "never",
    "--max-columns", "300", "--max-filesize", "1M",
    "--max-count", tostring(math.max(5, math.min(50, max_results))),
  }
  if args.case_sensitive == true then
    table.insert(cmd, "-s")
  elseif args.case_sensitive == false then
    table.insert(cmd, "-i")
  else
    table.insert(cmd, "--smart-case")
  end
  if args.fixed_strings == true then
    table.insert(cmd, "-F")
  end
  if context_lines > 0 then
    table.insert(cmd, "-C")
    table.insert(cmd, tostring(context_lines))
  end
  if type(args.glob) == "string" and args.glob ~= "" then
    table.insert(cmd, "-g")
    table.insert(cmd, args.glob)
  end
  table.insert(cmd, "--")
  table.insert(cmd, pattern)
  table.insert(cmd, root)

  local timeout = tonumber(args.timeout_ms) or 30000
  local ok, err = pcall(function()
    vim.system(cmd, {
      text = true,
      cwd = vim.fn.getcwd(),
      timeout = timeout,
    }, function(res)
      vim.schedule(function()
        if res.code == 1 then
          cb(true, string.format("No matches for %q in %s", pattern, display_path(root)))
          return
        end
        if res.code == 124 then
          cb(false, string.format("Error: search timed out after %dms", timeout))
          return
        end
        if res.code ~= 0 then
          local msg = (res.stderr or ""):gsub("%s+$", "")
          if msg == "" then msg = "ripgrep exited with code " .. tostring(res.code) end
          cb(false, "Error: search failed: " .. msg)
          return
        end

        local lines = {}
        local matches = 0
        local truncated = false
        for line in (res.stdout or ""):gmatch("[^\n]+") do
          local decoded_ok, data = pcall(vim.json.decode, line)
          if decoded_ok and type(data) == "table"
            and (data.type == "match" or data.type == "context") then
            local d = data.data or {}
            local path = type(d.path) == "table" and d.path.text or nil
            local lnum = tonumber(d.line_number)
            local text = type(d.lines) == "table" and d.lines.text or ""
            if path and lnum then
              if data.type == "match" then
                matches = matches + 1
              end
              if matches <= max_results or data.type == "context" then
                text = text:gsub("\r?\n$", "")
                local sep = data.type == "match" and ":" or "-"
                lines[#lines + 1] = string.format("%s%s%d%s %s", display_path(path), sep, lnum, sep, text)
              else
                truncated = true
              end
            end
          end
        end

        local footer = string.format("[%d match(es)%s]", matches,
          truncated and (", truncated at " .. max_results) or "")
        cb(true, result_text("Search: " .. pattern .. " in " .. display_path(root), lines, footer, context))
      end)
    end)
  end)
  if not ok then
    cb(false, "Error: could not run ripgrep: " .. tostring(err))
  end
end

--- Fallback search used when ripgrep is not installed.
local function lua_grep(pattern, args, root, cb, context)
  local max_results = tonumber(args.max_results) or DEFAULT_MAX_RESULTS
  if max_results < 1 then max_results = 1 end
  local context_lines = tonumber(args.context_lines) or 0
  if context_lines < 0 then context_lines = 0 end
  local files = expand_glob(root, args.glob)
  local fixed = args.fixed_strings == true
  local case_sensitive = args.case_sensitive
  if case_sensitive == nil then
    case_sensitive = pattern:find("%u") ~= nil
  end

  local regex = nil
  if not fixed then
    local ok, compiled = pcall(vim.regex, (case_sensitive and "\\C" or "\\c") .. pattern)
    if not ok then
      return cb(false, "Error: invalid regex pattern: " .. tostring(compiled))
    end
    regex = compiled
  end

  local needle = case_sensitive and pattern or pattern:lower()
  local out = {}
  local matches = 0
  local scanned = 0
  local truncated = false

  for _, file in ipairs(files) do
    if scanned >= DEFAULT_MAX_FILES then
      truncated = true
      break
    end
    if vim.fn.filereadable(file) == 1 then
      scanned = scanned + 1
      local lines = read_lines(file)
      if lines then
        local shown = {}
        for i, line in ipairs(lines) do
          local hit
          if fixed then
            local haystack = case_sensitive and line or line:lower()
            hit = haystack:find(needle, 1, true) ~= nil
          else
            hit = regex:match_str(line) ~= nil
          end
          if hit then
            matches = matches + 1
            local from = math.max(1, i - context_lines)
            local to = math.min(#lines, i + context_lines)
            for j = from, to do
              if not shown[j] then
                shown[j] = true
                local sep = j == i and ":" or "-"
                out[#out + 1] = string.format("%s%s%d%s %s", display_path(file), sep, j, sep, lines[j])
              end
            end
          end
          if matches >= max_results then
            truncated = true
            break
          end
        end
      end
    end
    if matches >= max_results then
      break
    end
  end

  local footer = string.format("[%d match(es) in %d file(s)%s]",
    matches, scanned, truncated and ", truncated" or "")
  cb(true, result_text("Search: " .. pattern .. " in " .. display_path(root), out, footer, context))
end

--- Search file contents recursively.
---@param args table # { pattern, path?, glob?, case_sensitive?, fixed_strings?, context_lines?, max_results?, timeout_ms? }
---@param cb function(success: boolean, result: string)
---@param context? table
function M.grep(args, cb, context)
  local pattern = args.pattern
  if type(pattern) ~= "string" or pattern == "" then
    return cb(false, "Error: 'pattern' argument is required for grep")
  end

  local root = normalize_root(args.path)
  if vim.fn.isdirectory(root) == 0 and vim.fn.filereadable(root) == 0 then
    return cb(false, "Error: search path not found: " .. tostring(args.path))
  end

  if vim.fn.executable("rg") == 1 then
    return rg_grep(pattern, args, root, cb, context)
  end
  return lua_grep(pattern, args, root, cb, context)
end

--- Find files or directories by glob pattern.
---@param args table # { pattern?, path?, type?, max_results? }
---@param cb function(success: boolean, result: string)
---@param context? table
function M.glob(args, cb, context)
  local pattern = type(args.pattern) == "string" and args.pattern or ""
  if pattern == "" then
    pattern = "**/*"
  end

  local root = normalize_root(args.path)
  if vim.fn.isdirectory(root) == 0 and vim.fn.filereadable(root) == 0 then
    return cb(false, "Error: glob path not found: " .. tostring(args.path))
  end

  local kind = args.type or "file"
  if kind ~= "file" and kind ~= "dir" and kind ~= "all" then
    return cb(false, "Error: type must be 'file', 'dir', or 'all'")
  end

  local max_results = tonumber(args.max_results) or 500
  if max_results < 1 then max_results = 1 end

  local out = {}
  for _, path in ipairs(expand_glob(root, pattern)) do
    local is_dir = vim.fn.isdirectory(path) == 1
    local include = kind == "all"
      or (kind == "dir" and is_dir)
      or (kind == "file" and not is_dir)
    if include then
      out[#out + 1] = display_path(path)
    end
    if #out >= max_results then
      break
    end
  end

  local truncated = #out >= max_results
  local header = string.format("Glob: %s in %s (%s)", pattern, display_path(root), kind)
  local lines = out
  if #lines == 0 then
    lines = { "(no matches)" }
  end
  local footer = string.format("[%d %s%s]", #out, kind == "dir" and "dir(s)" or "file(s)",
    truncated and ", truncated at " .. max_results or "")
  cb(true, result_text(header, lines, footer, context))
end

--- Shared file expansion for other tools.
---@param root string
---@param pattern? string
---@return string[]
function M.files(root, pattern)
  return expand_glob(normalize_root(root), pattern)
end

return M
