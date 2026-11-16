-- lua/agentfile/tools/symbols.lua
-- Lightweight "code map" tools: list declarations and return a pruned
-- (skeleton) view of a file. Both are language heuristics over source text —
-- cheap, dependency-free, and good enough for a small local model. They do
-- not replace grep/glob; they complement them by showing *structure* instead
-- of *matches*.
local truncate = require("agentfile.tools.truncate")
local search = require("agentfile.tools.search")

local M = {}

local MAX_FILE_BYTES = 1024 * 1024

-- Per-language symbol patterns. Each entry is { kind, pattern } where
-- `pattern` is a Lua pattern whose first capture is the symbol name.
local PATTERNS = {
  lua = {
    { "function", "^%s*local%s+function%s+([%w_%.%:]+)" },
    { "function", "^%s*function%s+([%w_%.%:]+)" },
    { "function", "^%s*([%w_]+)%s*=%s*function%s*%(" },
    { "module", "^%s*local%s+([%w_]+)%s*=%s*{%s*$" },
  },
  python = {
    { "class", "^%s*class%s+([%w_]+)" },
    { "function", "^%s*async%s+def%s+([%w_]+)" },
    { "function", "^%s*def%s+([%w_]+)" },
  },
  javascript = {
    { "class", "^%s*class%s+([%w_$]+)" },
    { "function", "^%s*async%s+function%s+([%w_$]+)" },
    { "function", "^%s*function%s+([%w_$]+)" },
    { "function", "^%s*const%s+([%w_$]+)%s*=%s*%([^)]*%)%s*=>" },
    { "function", "^%s*const%s+([%w_$]+)%s*=%s*async%s*%(" },
  },
  typescript = {
    { "class", "^%s*class%s+([%w_$]+)" },
    { "interface", "^%s*interface%s+([%w_$]+)" },
    { "function", "^%s*export%s+function%s+([%w_$]+)" },
    { "function", "^%s*function%s+([%w_$]+)" },
    { "function", "^%s*async%s+function%s+([%w_$]+)" },
    { "function", "^%s*const%s+([%w_$]+)%s*=%s*%([^)]*%)%s*=>" },
  },
  go = {
    { "type", "^type%s+([%w_]+)%s+(struct|interface)" },
    { "function", "^func%s+%(%s*[%w_]+%s+%*?[%w_%.%[%]]+%s*%)%s+([%w_]+)%(" },
    { "function", "^func%s+([%w_]+)%(" },
    { "function", "^func%s+%(%s*[%w_]+%s+%*?[%w_]+%s*%)%s+([%w_]+)" },
  },
  rust = {
    { "struct", "^%s*pub%s+struct%s+([%w_]+)" },
    { "struct", "^%s*struct%s+([%w_]+)" },
    { "enum", "^%s*pub%s+enum%s+([%w_]+)" },
    { "enum", "^%s*enum%s+([%w_]+)" },
    { "trait", "^%s*trait%s+([%w_]+)" },
    { "impl", "^%s*impl%s+([%w_]+)" },
    { "function", "^%s*pub%s+fn%s+([%w_]+)" },
    { "function", "^%s*fn%s+([%w_]+)" },
  },
  c = {
    { "function", "^%s*[%w_%*]+%s+([%w_]+)%s*%(" },
    { "struct", "^%s*struct%s+([%w_]+)" },
    { "function", "^%s*static%s+[%w_%*]+%s+([%w_]+)%s*%(" },
  },
  cpp = {
    { "class", "^%s*class%s+([%w_]+)" },
    { "struct", "^%s*struct%s+([%w_]+)" },
    { "function", "^%s*[%w_:<>%*&%s]+%s+([%w_]+)%s*%(" },
  },
  java = {
    { "class", "^%s*public%s+class%s+([%w_]+)" },
    { "class", "^%s*class%s+([%w_]+)" },
    { "interface", "^%s*interface%s+([%w_]+)" },
    { "enum", "^%s*enum%s+([%w_]+)" },
    { "function", "^%s*[%w_%[%]<>%s]+%s+([%w_]+)%s*%(" },
  },
  sh = {
    { "function", "^%s*function%s+([%w_]+)" },
    { "function", "^%s*([%w_]+)%s*%(%s*%)%s*{" },
  },
  vim = {
    { "function", "^%s*function!?%s+<[sS][iI][dD]>:([%w_#]+)" },
    { "function", "^%s*function!?%s+([%w_#]+)" },
  },
  markdown = {
    { "heading", "^#+%s+(.+)$" },
  },
}

local GENERIC = {
  { "class", "^%s*class%s+([%w_]+)" },
  { "function", "^%s*def%s+([%w_]+)" },
  { "function", "^%s*function%s+([%w_]+)" },
  { "function", "^%s*fn%s+([%w_]+)" },
  { "function", "^%s*func%s+([%w_]+)%(" },
  { "struct", "^%s*struct%s+([%w_]+)" },
  { "interface", "^%s*interface%s+([%w_]+)" },
}

local EXT_LANG = {
  lua = "lua",
  py = "python",
  js = "javascript",
  mjs = "javascript",
  jsx = "javascript",
  ts = "typescript",
  tsx = "typescript",
  go = "go",
  rs = "rust",
  c = "c",
  h = "c",
  cpp = "cpp",
  cc = "cpp",
  cxx = "cpp",
  hpp = "cpp",
  java = "java",
  sh = "sh",
  bash = "sh",
  zsh = "sh",
  vim = "vim",
  md = "markdown",
}

--- Detect the "language family" used to pick symbol patterns.
---@param path string
---@return string
local function detect_lang(path)
  local ft = ""
  pcall(function()
    ft = vim.filetype.match({ filename = path }) or ""
  end)
  ft = ft or ""
  ft = ft:gsub("react$", "") -- jsx/tsx -> js/ts patterns
  if ft == "javascript" or ft == "typescript" or ft == "javascriptreact" or ft == "typescriptreact" then
    return ft:gsub("react$", "")
  end
  if PATTERNS[ft] then
    return ft
  end

  local ext = vim.fn.fnamemodify(path, ":e"):lower()
  return EXT_LANG[ext] or "unknown"
end

---@param lang string
---@return table[]
local function patterns_for(lang)
  return PATTERNS[lang] or GENERIC
end

--- Match a line against a language's symbol patterns.
---@param lang string
---@param line string
---@return string|nil kind, string|nil name, boolean is_toplevel
local function match_symbol(lang, line)
  local stripped = line:gsub("^%s+", "")
  local is_toplevel = stripped == line
  for _, entry in ipairs(patterns_for(lang)) do
    local name = stripped:match(entry[2])
    if name and name ~= "" then
      return entry[1], name, is_toplevel
    end
  end
  return nil
end

--- Whether a line is an import/require/include line worth keeping in a skeleton.
---@param line string
---@return boolean
local function is_import(line)
  local s = line:gsub("^%s+", "")
  if s:find("^import%s") or s:find("^from%s+%S+%s+import%s") then return true end
  if s:find("^local%s+%w+%s*=%s*require%s*%(") then return true end
  if s:find("^use%s+%S") or s:find("^#include") or s:find("^#import") then return true end
  if s:find("^require%s*%(") then return true end
  return false
end

--- Read a file's lines, rejecting missing/binary/oversized files.
---@param path string
---@return string[]|nil
local function read_lines(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
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

--- Collect top-level declarations across a set of files.
local function scan_files(paths, max_files, max_symbols)
  local out = {}
  local files_scanned = 0
  local symbols = 0

  for _, path in ipairs(paths) do
    if files_scanned >= max_files or symbols >= max_symbols then
      break
    end
    local lang = detect_lang(path)
    if lang ~= "unknown" then
      local lines = read_lines(path)
      if lines then
        files_scanned = files_scanned + 1
        local rel = vim.fn.fnamemodify(path, ":.")
        for i, line in ipairs(lines) do
          if symbols >= max_symbols then break end
          local kind, name, toplevel = match_symbol(lang, line)
          if kind and name and toplevel then
            symbols = symbols + 1
            out[#out + 1] = string.format("%s:%d %s %s", rel, i, kind, name)
          end
        end
      end
    end
  end

  return out, files_scanned, symbols
end

--- List top-level symbols (classes, functions, ...) in files matching a path/glob.
---@param args table # { path?, glob?, max_files?, max_symbols? }
---@param cb function(success: boolean, result: string)
---@param context? table
function M.symbols(args, cb, context)
  local path = type(args.path) == "string" and args.path ~= "" and args.path or "."
  local glob = type(args.glob) == "string" and args.glob ~= "" and args.glob or "**/*"
  local max_files = tonumber(args.max_files) or 50
  local max_symbols = tonumber(args.max_symbols) or 500

  local files = search.files(path, glob)
  if #files == 0 and vim.fn.filereadable(path) == 1 then
    files = { vim.fs.normalize(vim.fn.expand(path)) }
  end

  local lines, scanned, count = scan_files(files, max_files, max_symbols)
  local header = string.format("Symbols in %s (glob %s)", vim.fn.fnamemodify(path, ":."), glob)
  if #lines == 0 then
    lines = { "(no symbols found)" }
  end
  local footer = string.format("[%d symbol(s) in %d file(s)]", count, scanned)
  local text = header .. "\n" .. table.concat(lines, "\n") .. "\n" .. footer
  cb(true, truncate.text(text, {
    max_chars = truncate.budget(context and context.config),
    hint = "Narrow the path/glob, or read a specific file with @skeleton.",
  }))
end

--- Return a pruned view of a file: imports + declaration signatures, with full
--- bodies only for the focused symbol(s).
---@param args table # { path, focus? }
---@param cb function(success: boolean, result: string)
---@param context? table
function M.skeleton(args, cb, context)
  local path = args.path
  if type(path) ~= "string" or path == "" then
    return cb(false, "Error: 'path' argument is required for skeleton")
  end

  local full = vim.fs.normalize(vim.fn.expand(path))
  if vim.fn.filereadable(full) == 0 then
    return cb(false, "Error: file not found: " .. path)
  end

  local lines = read_lines(full)
  if not lines then
    return cb(false, "Error: could not read file (missing, binary, or too large): " .. path)
  end

  local lang = detect_lang(full)
  local rel = vim.fn.fnamemodify(full, ":.")
  local focus = type(args.focus) == "string" and args.focus ~= "" and args.focus or nil

  -- Precompute declaration positions for focus body extraction.
  local decls = {} -- { line, kind, name, toplevel }
  for i, line in ipairs(lines) do
    local kind, name, toplevel = match_symbol(lang, line)
    if kind and name then
      decls[#decls + 1] = { line = i, kind = kind, name = name, toplevel = toplevel }
    end
  end

  local out = {}
  out[#out + 1] = string.format("# skeleton: %s (%s)", rel, lang)

  -- Imports first.
  local import_count = 0
  for _, line in ipairs(lines) do
    if is_import(line) then
      out[#out + 1] = line
      import_count = import_count + 1
    end
  end

  -- Focus bodies (full text), if requested.
  local focus_count = 0
  local body_lines = {}
  if focus then
    for _, decl in ipairs(decls) do
      if decl.name == focus or decl.name:match("[.:]" .. vim.pesc(focus) .. "$") then
        local start_line = decl.line
        local end_line = #lines
        for _, other in ipairs(decls) do
          if other.line > start_line and other.toplevel then
            end_line = other.line - 1
            break
          end
        end
        focus_count = focus_count + 1
        body_lines[#body_lines + 1] = string.format("## focus: %s (%s, lines %d-%d)",
          decl.name, decl.kind, start_line, end_line)
        for i = start_line, end_line do
          body_lines[#body_lines + 1] = lines[i]
        end
        body_lines[#body_lines + 1] = ""
      end
    end
  end

  -- Declaration signatures (top-level only).
  out[#out + 1] = "## declarations"
  local sig_count = 0
  for _, decl in ipairs(decls) do
    if decl.toplevel then
      sig_count = sig_count + 1
      out[#out + 1] = string.format("%-10s %-10s %s", decl.kind, decl.name, lines[decl.line])
    end
  end

  if focus and focus_count == 0 then
    out[#out + 1] = string.format("(focus %q not found)", focus)
  end

  for _, line in ipairs(body_lines) do
    out[#out + 1] = line
  end

  local footer = string.format(
    "[%d declaration(s), %d import line(s)%s]",
    sig_count, import_count, focus and string.format(", %d focus body", focus_count) or ""
  )
  out[#out + 1] = footer

  cb(true, truncate.text(table.concat(out, "\n"), {
    max_chars = truncate.budget(context and context.config),
    hint = "Use focus to include a specific symbol's body, or read a smaller range with @read_file.",
  }))
end

return M
