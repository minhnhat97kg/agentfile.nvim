-- Limits for the chat tool loop; independent of history's max_turns.
local M = {}

local function is_non_negative_int(value)
  return type(value) == "number" and value >= 0 and value ~= math.huge
    and value == math.floor(value)
end

function M.resolve(config)
  local agent = config.agent
  if agent ~= nil and type(agent) ~= "table" then
    return nil, "agent must be a mapping with enabled and max_steps"
  end
  agent = agent or {}
  if agent.enabled ~= nil and type(agent.enabled) ~= "boolean" then
    return nil, "agent.enabled must be true or false"
  end

  -- Legacy max_iterations counted tool rounds, followed by a model response.
  local max_steps = agent.max_steps
  if max_steps == nil then
    max_steps = config.max_iterations and (tonumber(config.max_iterations) or 0) + 1 or 4
  end
  if type(max_steps) ~= "number" or max_steps < 1 or max_steps == math.huge
    or max_steps ~= math.floor(max_steps) then
    return nil, "agent.max_steps must be a positive integer"
  end

  -- How many consecutive invalid/truncated responses to tolerate before
  -- stopping. 0 means "no limit" (the step budget still applies).
  local max_format_errors = agent.max_format_errors
  if max_format_errors == nil then
    max_format_errors = 3
  end
  if not is_non_negative_int(max_format_errors) then
    return nil, "agent.max_format_errors must be a non-negative integer"
  end

  -- Optional wall-clock limit for one user request, in seconds.
  local wall_time_limit = agent.wall_time_limit or agent.max_time or 0
  if type(wall_time_limit) ~= "number" or wall_time_limit < 0 then
    return nil, "agent.wall_time_limit must be a non-negative number of seconds"
  end

  -- Default timeout for @run_command, in seconds.
  local command_timeout = agent.command_timeout
  if command_timeout == nil then
    command_timeout = config.command_timeout
  end
  if command_timeout ~= nil and (type(command_timeout) ~= "number" or command_timeout <= 0) then
    return nil, "agent.command_timeout must be a positive number of seconds"
  end

  -- Transient HTTP failures (429/5xx/connection) are retried automatically.
  local retries = config.retries
  if retries == nil then retries = agent.retries end
  if retries == nil then retries = 2 end
  if not is_non_negative_int(retries) then
    return nil, "retries must be a non-negative integer"
  end

  local retry_delay_ms = config.retry_delay_ms or agent.retry_delay_ms or 1000
  if type(retry_delay_ms) ~= "number" or retry_delay_ms < 0 then
    return nil, "retry_delay_ms must be a non-negative number"
  end

  return {
    enabled = agent.enabled ~= false,
    max_steps = max_steps,
    max_format_errors = max_format_errors,
    wall_time_limit = wall_time_limit,
    command_timeout = command_timeout,
    retries = retries,
    retry_delay_ms = retry_delay_ms,
  }
end

return M
