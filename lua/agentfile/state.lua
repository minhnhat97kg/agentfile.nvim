-- lua/agentfile/state.lua
local parser = require("agentfile.parser")
local serializer = require("agentfile.serializer")

local M = {}

-- Buffer local states indexed by bufnr
local buffers = {}

local VALID_TRANSITIONS = {
  idle = { parsing = true, awaiting_approval = true },
  parsing = { streaming = true, idle = true, tools_running = true },
  streaming = { tools_running = true, idle = true },
  tools_running = { awaiting_approval = true, parsing = true, idle = true },
  awaiting_approval = { tools_running = true, idle = true }
}

--- Reset or initialize buffer state
---@param bufnr number
---@return table
function M.reset(bufnr)
  buffers[bufnr] = {
    bufnr = bufnr,
    status = "idle",
    last_sent_hash = "",
    suppress_save_hook = false,
    active_job = nil,
    flush_timer = nil,
    writer = nil,
    pending_tool = nil,
    cancelled = false,
    tool_counter = 0,
    iteration_count = 0,
    agent_steps = 0,
    -- Response quality / telemetry
    format_errors = 0,
    last_format_error = nil,
    last_finish_reason = nil,
    usage = nil,
    total_prompt_tokens = 0,
    total_completion_tokens = 0,
    chars_per_token = nil,
    payload_chars = 0,
    model_calls = 0,
    turn_started_at = nil,
    exit_status = nil,
    submission = nil,
    -- Memory: avoid proposing the same lesson twice per buffer
    failure_counts = {},
    memory_offered = {},
  }
  return buffers[bufnr]
end

--- Get buffer state (auto-initialize if missing)
---@param bufnr number
---@return table
function M.get(bufnr)
  if not buffers[bufnr] then
    return M.reset(bufnr)
  end
  return buffers[bufnr]
end

--- Transition to a new state
---@param bufnr number
---@param new_status string
---@return boolean # true if transition valid and applied
function M.transition(bufnr, new_status)
  local state = M.get(bufnr)
  local current = state.status

  if current == new_status then
    return true
  end

  local allowed = VALID_TRANSITIONS[current]
  if allowed and allowed[new_status] then
    state.status = new_status
    return true
  end

  return false
end

--- Check if saving buffer should trigger sending prompt
---@param bufnr number
---@param lines string[]
---@return boolean, string|nil # should_send, reason
function M.should_trigger_send(bufnr, lines)
  local state = M.get(bufnr)

  if state.suppress_save_hook then
    return false, "suppressed_by_plugin"
  end

  if state.status ~= "idle" then
    return false, "busy_state_" .. state.status
  end

  local _, end_fm = parser.parse_frontmatter(lines)
  local blocks = parser.parse_blocks(lines, end_fm + 1)

  if #blocks == 0 then
    return false, "no_blocks"
  end

  -- Clean up empty trailing [me] blocks if any
  while #blocks > 1 and blocks[#blocks].role == "user" and blocks[#blocks].content == "" do
    table.remove(blocks)
  end

  local last_block = blocks[#blocks]

  -- Only trigger if the last block is [me]
  if last_block.role ~= "user" or (last_block.content == "" and #blocks == 1) then
    return false, "last_block_not_user"
  end

  -- Compute canonical hash to check if user actually edited/sent new text
  local canonical = serializer.serialize_messages(blocks)
  local current_hash = serializer.compute_turn_hash(canonical)

  if current_hash == state.last_sent_hash then
    return false, "unchanged_hash"
  end

  return true, nil
end

--- Record that this turn has been sent
---@param bufnr number
---@param lines string[]
function M.record_sent(bufnr, lines)
  local state = M.get(bufnr)
  local _, end_fm = parser.parse_frontmatter(lines)
  local blocks = parser.parse_blocks(lines, end_fm + 1)
  local canonical = serializer.serialize_messages(blocks)
  state.last_sent_hash = serializer.compute_turn_hash(canonical)
end

return M
