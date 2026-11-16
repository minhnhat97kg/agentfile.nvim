-- lua/agentfile/trajectory.lua
-- Export the single-buffer transcript as a machine-readable trajectory.
--
-- The .agentfile buffer stays the human source of truth. This JSON mirror is for
-- debugging, replay, evaluation and fine-tuning: it is exactly the message
-- list that would be sent to the model, plus run metadata.
local serializer = require("agentfile.serializer")

local M = {}

--- Build a JSON-serializable trajectory.
---@param blocks table[]
---@param opts? table # { config, agent, tools_prompt, serializer_opts, usage, steps, exit_status, submission }
---@return table
function M.build(blocks, opts)
  opts = opts or {}
  local config = opts.config or {}
  local messages = serializer.serialize_messages(
    blocks,
    opts.tools_prompt,
    nil,
    opts.serializer_opts
  )

  local info = {
    trajectory_format = "agentfile-1.0",
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    model = config.model,
    host = config.host,
    agent = opts.agent,
    steps = tonumber(opts.steps) or 0,
    usage = opts.usage,
    exit_status = opts.exit_status or "",
    submission = opts.submission or "",
  }

  return {
    info = info,
    messages = messages,
  }
end

--- Default output path (relative to the project).
---@return string
function M.default_path()
  return ".agentfile/trajectory-" .. os.date("%Y%m%d-%H%M%S") .. ".json"
end

--- Write the trajectory as JSON.
---@param blocks table[]
---@param path string
---@param opts? table
---@return boolean ok, string path|string err
function M.export(blocks, path, opts)
  local data = M.build(blocks, opts)
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    return false, "could not encode trajectory: " .. tostring(encoded)
  end

  local dir = vim.fn.fnamemodify(path, ":h")
  if dir ~= "" and dir ~= "." and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  local write_ok, err = pcall(vim.fn.writefile, { encoded }, path)
  if not write_ok then
    return false, tostring(err)
  end
  return true, path
end

return M
