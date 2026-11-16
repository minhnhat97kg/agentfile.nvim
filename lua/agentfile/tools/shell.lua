-- lua/agentfile/tools/shell.lua
local truncate = require("agentfile.tools.truncate")

local M = {}

--- Execute a shell command and return a machine-readable observation.
---
--- The observation always carries the exit code and keeps stderr separate from
--- stdout. Without an explicit return code a small model cannot tell a failed
--- command from a noisy successful one.
function M.run_command(args, cb, context)
  local command = args.command
  if not command or command == "" then
    return cb(false, "Error: 'command' argument is required for run_command")
  end

  local stdout_chunks = {}
  local stderr_chunks = {}

  local system_fn = vim.system or function(cmd, opts, on_exit)
    local out = vim.fn.system(command)
    on_exit({ code = 0, stdout = out, stderr = "" })
  end

  system_fn({ "sh", "-c", command }, {
    text = true,
  }, function(res)
    local out = (res.stdout or ""):gsub("%s+$", "")
    local err = (res.stderr or ""):gsub("%s+$", "")

    local budget = truncate.budget(context and context.config)
    local hint = "Use head, tail, grep or sed -n to produce less output, or redirect to a file."

    local function section(name, value)
      if value == "" then
        return ""
      end
      local trimmed = truncate.text(value, { max_chars = budget, hint = hint })
      return "<" .. name .. ">\n" .. trimmed .. "\n</" .. name .. ">\n"
    end

    local combined = string.format(
      "<returncode>%d</returncode>\n%s%s",
      tonumber(res.code) or -1,
      section("stderr", err),
      section("output", out)
    )

    local success = (res.code == 0)
    vim.schedule(function()
      cb(success, combined)
    end)
  end)
end

return M
