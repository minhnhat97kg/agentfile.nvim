-- lua/agentfile/tools/init.lua
local fs = require("agentfile.tools.fs")
local shell = require("agentfile.tools.shell")
local image = require("agentfile.tools.image")
local search = require("agentfile.tools.search")
local symbols = require("agentfile.tools.symbols")

local M = {}

local registry = {}

--- Register a tool in the registry
---@param name string
---@param spec table # { description: string, parameters: table, is_dangerous: boolean, run: function(args, cb), hidden?: boolean }
function M.register(name, spec)
  registry[name] = spec
end

--- Get a registered tool spec
---@param name string
---@return table|nil
function M.get(name)
  return registry[name]
end

--- Whether a tool requires approval (writes files, runs commands, ...).
---@param name string
---@return boolean
function M.is_dangerous(name)
  local spec = registry[name]
  return spec ~= nil and spec.is_dangerous == true
end

--- Enforce a safe tool batch policy.
---
--- Read-only calls may be batched, but at most one file-modifying/command call
--- per turn. A batch that silently runs two edits is hard to audit and easy to
--- apply in the wrong order; asking the model to split the turn keeps the
--- transcript honest.
---@param calls table[] # { name = string, ... }
---@return boolean ok, string|nil error
function M.validate_batch(calls)
  local dangerous = {}
  local has_done = false
  for _, call in ipairs(calls or {}) do
    if call.name == "done" then
      has_done = true
    end
    if M.is_dangerous(call.name) then
      dangerous[#dangerous + 1] = call.name
    end
  end

  if has_done and #calls > 1 then
    return false, "@done must be the only tool call in its turn."
  end
  if #dangerous > 1 then
    return false, string.format(
      "Only one file-modifying or command tool is allowed per turn; got %d (%s). "
        .. "Run the first one, inspect its result, then continue.",
      #dangerous, table.concat(dangerous, ", ")
    )
  end
  return true, nil
end

--- Render one registry entry as a compact prompt line.
---@param name string
---@param spec table
---@return string
local function schema_line(name, spec)
  local params = {}
  for param, desc in pairs(spec.parameters or {}) do
    params[#params + 1] = string.format("%s (%s)", param, tostring(desc))
  end
  table.sort(params)
  local param_text = #params > 0 and table.concat(params, ", ") or "none"
  local line = string.format("- @%s: %s\n  params: %s", name, spec.description or "", param_text)
  if spec.example then
    line = line .. "\n  Example: " .. spec.example
  end
  return line
end

--- Generate system prompt documentation for requested skills/tools
---@param skill_names? string[]
---@return string
function M.get_schema_prompt(skill_names)
  local list = {}
  local requested_set = nil
  if skill_names and #skill_names > 0 then
    requested_set = {}
    for _, name in ipairs(skill_names) do
      requested_set[name] = true
    end
  end

  for name, spec in pairs(registry) do
    if not spec.hidden and (not requested_set or requested_set[name]) then
      table.insert(list, schema_line(name, spec))
    end
  end

  table.sort(list)

  return [[AVAILABLE TOOLS:
]] .. table.concat(list, "\n") .. [[

TOOL CALLING RULES:
1. Write tool calls at the start of a line in format: @tool_name({"param": "value"})
2. Never wrap tool calls in code fences or quotes.
3. Call tools yourself directly; do NOT ask the user to run commands.
4. Batch read-only calls, but use at most ONE file-modifying or command call (@write_file, @edit_file, @run_command) per turn.
5. If a tool fails, read the error message carefully and fix the issue; do not repeat identical failing calls.
6. When the task is complete, call @done({"summary": "what changed and how it was verified"}) as the only call in that turn.
7. For multi-line code or scripts, use a heredoc so you never have to escape quotes/newlines inside a JSON string:
   @write_file({"path": "src/main.go"}) <<'EOF'
   package main
   func main() { println("hi") }
   EOF
   The body between the markers is the file content (for write_file), the replacement (for edit_file), or the command (for run_command).
8. Locate files with @glob and search contents with @grep before reading many files. Prefer a narrow path/glob and a specific pattern.
9. Use @symbols to map a directory's structure and @skeleton to get a pruned view of a file before editing; read the real file range with @read_file only when you need exact code.

Correct:
@read_file({"path": "src/main.rs"})
@list_files({"path": "src"})

Wrong:
```bash
@list_files({"path": "."})
```]]
end

--- Parse a registry parameter description into a JSON-schema type.
---@param desc string
---@return string type, boolean optional
local function param_type(desc)
  local text = tostring(desc or "")
  local lower = text:lower()
  local optional = lower:find("optional", 1, true) ~= nil
  local kind = lower:match("^(%a+)")
  local map = {
    string = "string",
    number = "number",
    integer = "integer",
    boolean = "boolean",
    array = "array",
    object = "object",
  }
  return map[kind] or "string", optional
end

--- Build OpenAI-style function schemas for native tool calling.
---@param skill_names? string[]
---@return table[]
function M.schemas(skill_names)
  local requested_set = nil
  if skill_names and #skill_names > 0 then
    requested_set = {}
    for _, name in ipairs(skill_names) do requested_set[name] = true end
  end

  local names = {}
  for name, spec in pairs(registry) do
    if not spec.hidden and (not requested_set or requested_set[name]) then
      names[#names + 1] = name
    end
  end
  table.sort(names)

  local out = {}
  for _, name in ipairs(names) do
    local spec = registry[name]
    local properties, required = {}, {}
    local params = {}
    for param in pairs(spec.parameters or {}) do params[#params + 1] = param end
    table.sort(params)
    for _, param in ipairs(params) do
      local desc = tostring(spec.parameters[param])
      local typ, optional = param_type(desc)
      properties[param] = { type = typ, description = desc }
      if not optional then required[#required + 1] = param end
    end

    local parameters = { type = "object", properties = properties }
    if #required > 0 then parameters.required = required end

    out[#out + 1] = {
      type = "function",
      ["function"] = {
        name = name,
        description = spec.description or "",
        parameters = parameters,
      },
    }
  end
  return out
end

--- Execute a tool by name
---@param name string
---@param args table
---@param cb function(success: boolean, result: string)
---@param context? table # execution context, e.g. active chat path
function M.execute(name, args, cb, context)
  local spec = registry[name]
  if not spec then
    return cb(false, "Error: Unknown tool @" .. tostring(name))
  end

  local ok, err = pcall(spec.run, args, cb, context)
  if not ok then
    cb(false, "Execution error: " .. tostring(err))
  end
end

-- Register built-in tools
M.register("read_file", {
  description = "Read file contents with optional start_line and end_line",
  parameters = { path = "string", start_line = "number (optional)", end_line = "number (optional)" },
  example = '@read_file({"path": "src/main.rs", "start_line": 1, "end_line": 50})',
  is_dangerous = false,
  run = fs.read_file
})

M.register("write_file", {
  description = "Write full content to a file. Prefer a heredoc body for multi-line content: @write_file({\"path\": \"x\"}) <<'EOF' ... EOF",
  parameters = { path = "string", content = "string (or heredoc body)" },
  example = '@write_file({"path": "notes.txt", "content": "Hello World\\nSecond line"})',
  is_dangerous = true,
  run = fs.write_file
})

M.register("edit_file", {
  description = "Replace target substring with replacement. Target must be unique unless occurrence/replace_all is given; otherwise prefer write_file. Multi-line replacement: @edit_file({\"path\":\"x\",\"target\":\"old\"}) <<'EOF' ... EOF",
  parameters = { path = "string", target = "string", replacement = "string (or heredoc body)", occurrence = "number (optional, 1-based)", replace_all = "boolean (optional)" },
  example = '@edit_file({"path": "config.json", "target": "\"debug\": false", "replacement": "\"debug\": true"})',
  is_dangerous = true,
  run = fs.edit_file
})

M.register("list_files", {
  description = "List directory entries with paths ready to use in read_file/list_files; use recursive=true to walk a small tree",
  parameters = {
    path = "string (optional, defaults to .)",
    recursive = "boolean (optional, default false)",
    max_depth = "number (optional, default 3)",
    max_entries = "number (optional, default 500)",
  },
  example = '@list_files({"path": ".", "recursive": true, "max_depth": 2})',
  is_dangerous = false,
  run = fs.list_files
})

M.register("grep", {
  description = "Search file contents recursively (ripgrep when available). Prefer this over reading many files; returns path:line: text",
  parameters = {
    pattern = "string (regex; use fixed_strings for literal text)",
    path = "string (optional, defaults to .)",
    glob = "string (optional, e.g. *.lua or src/**/*.ts)",
    case_sensitive = "boolean (optional; default smart-case)",
    fixed_strings = "boolean (optional)",
    context_lines = "number (optional, default 0)",
    max_results = "number (optional, default 100)",
    timeout_ms = "number (optional, default 30000)",
  },
  example = '@grep({"pattern": "tool_calls", "path": "lua", "glob": "*.lua"})',
  is_dangerous = false,
  run = search.grep
})

M.register("glob", {
  description = "Find files or directories by glob pattern (e.g. **/*.lua) without reading file contents",
  parameters = {
    pattern = "string (optional, default **/*)",
    path = "string (optional, defaults to .)",
    type = "string (optional: file, dir, or all; default file)",
    max_results = "number (optional, default 500)",
  },
  example = '@glob({"pattern": "**/*.lua", "path": "lua"})',
  is_dangerous = false,
  run = search.glob
})

M.register("symbols", {
  description = "List top-level symbols (functions, classes, structs) in files matching a path/glob, to map code structure without reading whole files",
  parameters = {
    path = "string (optional, defaults to .)",
    glob = "string (optional, default **/*)",
    max_files = "number (optional, default 50)",
    max_symbols = "number (optional, default 500)",
  },
  example = '@symbols({"path": "lua/agentfile", "glob": "*.lua"})',
  is_dangerous = false,
  run = symbols.symbols
})

M.register("skeleton", {
  description = "Return a pruned view of a file: imports + declaration signatures, with full bodies only for the focused symbol. Saves context before editing",
  parameters = {
    path = "string",
    focus = "string (optional, symbol name to include in full)",
  },
  example = '@skeleton({"path": "lua/agentfile/ui.lua", "focus": "winbar"})',
  is_dangerous = false,
  run = symbols.skeleton
})

M.register("run_command", {
  description = "Execute a shell command in the background and capture stdout/stderr. Supports cwd, env, and timeout. Multi-line script: @run_command <<'EOF' ... EOF",
  parameters = {
    command = "string (or heredoc body)",
    cwd = "string (optional, defaults to Neovim's working directory)",
    env = "object (optional, extra environment variables)",
    timeout_ms = "number (optional, default 120000)",
    stdin = "string (optional)",
  },
  example = '@run_command({"command": "cargo test", "timeout_ms": 120000})',
  is_dangerous = true,
  run = shell.run_command
})

M.register("send_image", {
  description = "Attach and send an image file (PNG, JPG, WEBP, GIF, SVG) to the model for multimodal inspection",
  parameters = { path = "string", caption = "string (optional)" },
  example = '@send_image({"path": "doc/screenshot.png", "caption": "UI layout"})',
  is_dangerous = false,
  run = image.send_image
})

M.register("view_image", {
  description = "Alias for send_image: inspect an image file in the project",
  parameters = { path = "string", caption = "string (optional)" },
  example = '@view_image({"path": "doc/diagram.png"})',
  is_dangerous = false,
  hidden = true,
  run = image.send_image
})

M.register("done", {
  description = "Mark the task complete. Call ALONE as the final step, after verifying your work",
  parameters = { summary = "string (optional, what changed and how it was verified)" },
  example = '@done({"summary": "Fixed the parser and ran the test suite."})',
  is_dangerous = false,
  run = function(args, cb)
    local summary = tostring(args.summary or "")
    cb(true, summary ~= "" and summary or "Task marked complete.")
  end
})

return M
