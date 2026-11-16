-- lua/agentfile/tools/shell.lua
local truncate = require("agentfile.tools.truncate")

local M = {}

local DEFAULT_TIMEOUT_MS = 120000

local function configured_timeout(context)
  local config = context and context.config or {}
  local agent = type(config.agent) == "table" and config.agent or {}
  local seconds = tonumber(config.command_timeout) or tonumber(agent.command_timeout)
  if seconds and seconds > 0 then
    return math.floor(seconds * 1000)
  end
  return DEFAULT_TIMEOUT_MS
end

local function shell_command(command)
  if vim.fn.has("win32") == 1 then
    return { "cmd.exe", "/d", "/s", "/c", command }
  end
  return { "sh", "-c", command }
end

local function resolve_cwd(cwd)
  if type(cwd) ~= "string" or cwd == "" then
    return vim.fn.getcwd()
  end
  local full = vim.fn.fnamemodify(vim.fn.expand(cwd), ":p")
  if vim.fn.isdirectory(full) == 0 then
    return nil, "Error: cwd is not a directory: " .. cwd
  end
  return full
end

local function normalize_env(env)
  if type(env) ~= "table" then
    return nil
  end
  local out = {}
  for key, value in pairs(env) do
    if type(key) == "string" and key ~= "" and (type(value) == "string" or type(value) == "number") then
      out[key] = tostring(value)
    end
  end
  return out
end

--- Execute a shell command and return a machine-readable observation.
---
--- The observation always carries the exit code and keeps stderr separate from
--- stdout. Without an explicit return code a small model cannot tell a failed
--- command from a noisy successful one.
function M.run_command(args, cb, context)
  local command = args.command
  if type(command) ~= "string" or command == "" then
    return cb(false, "Error: 'command' argument is required for run_command")
  end

  local cwd, cwd_error = resolve_cwd(args.cwd)
  if not cwd then
    return cb(false, cwd_error)
  end

  local timeout_ms = tonumber(args.timeout_ms) or configured_timeout(context)
  if timeout_ms <= 0 then
    timeout_ms = DEFAULT_TIMEOUT_MS
  end

  local env = normalize_env(args.env)
  local stdin = args.stdin
  if type(stdin) ~= "string" then
    stdin = ""
  end

  local stdout_chunks = {}
  local stderr_chunks = {}
  local finished = false
  local handle = nil

  local function on_chunk(stream, data)
    if not data or data == "" then
      return
    end
    local target = stream == "stderr" and stderr_chunks or stdout_chunks
    target[#target + 1] = data
    if context and type(context.on_output) == "function" then
      vim.schedule(function()
        pcall(context.on_output, data, stream)
      end)
    end
  end

  local function on_exit(res)
    finished = true
    local out = table.concat(stdout_chunks):gsub("%s+$", "")
    local err = table.concat(stderr_chunks):gsub("%s+$", "")
    local code = tonumber(res.code) or -1
    local timed_out = code == 124
    local signal = tonumber(res.signal) or 0

    if context and context.buf_state and context.buf_state.active_command == handle then
      context.buf_state.active_command = nil
    end

    local budget = truncate.budget(context and context.config)
    local hint = "Use head, tail, grep or sed -n to produce less output, or redirect to a file."

    local function section(name, value)
      if value == "" then
        return ""
      end
      local trimmed = truncate.text(value, { max_chars = budget, hint = hint })
      return "<" .. name .. ">\n" .. trimmed .. "\n</" .. name .. ">\n"
    end

    local note = ""
    if timed_out then
      note = string.format("<timeout>%dms</timeout>\n", timeout_ms)
    elseif signal ~= 0 then
      note = string.format("<signal>%d</signal>\n", signal)
    end

    local combined = string.format(
      "<returncode>%d</returncode>\n%s%s%s",
      code,
      note,
      section("stderr", err),
      section("output", out)
    )

    local success = code == 0 and signal == 0
    vim.schedule(function()
      cb(success, combined)
    end)
  end

  local cmd = shell_command(command)
  local opts = {
    text = true,
    cwd = cwd,
    timeout = timeout_ms,
    stdin = stdin,
    stdout = function(_, data)
      on_chunk("stdout", data)
    end,
    stderr = function(_, data)
      on_chunk("stderr", data)
    end,
  }
  if env then
    opts.env = env
  end

  local start_ok, start_result = pcall(function()
    handle = vim.system(cmd, opts, on_exit)
  end)
  if not start_ok then
    return cb(false, "Error: could not start command: " .. tostring(start_result))
  end

  -- If the process finished synchronously, do not leave a dead handle behind.
  if not finished and context and context.buf_state then
    context.buf_state.active_command = handle
  end
end

return M
