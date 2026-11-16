-- lua/agentfile/serializer.lua
local markers = require("agentfile.markers")

local M = {}

--- Precompute which [think] blocks should be replayed once after a failure.
--- A think block is attached to the assistant message that follows it when the
--- next tool result in the same turn has status=error. It is never persisted
--- into later turns, so failed reasoning cannot accumulate in the context.
---@param blocks table[]
---@param start_index number
---@return table<number, string> # assistant block index -> think content
local function think_after_error(blocks, start_index)
  local include = {}
  for i = start_index, #blocks do
    local block = blocks[i]
    if block.role == "think" and block.content and block.content ~= "" then
      local agent_idx, result_idx
      for j = i + 1, #blocks do
        local next_block = blocks[j]
        if next_block.role == "user" or next_block.role == "system"
          or next_block.role == "reset" then
          break
        end
        if next_block.role == "agent" and not agent_idx then
          agent_idx = j
        elseif next_block.role == "result" then
          result_idx = j
          break
        end
      end
      if agent_idx and result_idx and blocks[result_idx].status == "error" then
        include[agent_idx] = block.content
      end
    end
  end
  return include
end

--- Serialize parsed blocks into OpenAI-compatible messages payload
--- Note: [think] blocks are STRIPPED completely from the payload, unless
--- `opts.keep_think_on_error` is set and the reasoning led to a failed tool.
---@param blocks table[]
---@param tools_prompt? string
---@param max_turns? number # optional sliding window limit of recent turns
---@param opts? table # { keep_think_on_error = boolean }
---@return table[] # list of { role = string, content = string }
function M.serialize_messages(blocks, tools_prompt, max_turns, opts)
  opts = opts or {}
  local messages = {}
  local system_messages = {}
  local conversation_messages = {}

  -- Check if user inserted a [reset] cut marker in buffer
  local start_index = 1
  for i = #blocks, 1, -1 do
    if blocks[i].role == "reset" then
      start_index = i + 1
      break
    end
  end

  local think_extra = {}
  if opts.keep_think_on_error then
    think_extra = think_after_error(blocks, start_index)
  end

  for i = 1, #blocks do
    local block = blocks[i]
    if block.role == "system" then
      if block.content and block.content ~= "" then
        table.insert(system_messages, block.content)
      end
    elseif i >= start_index then
      if block.role == "user" then
        table.insert(conversation_messages, {
          role = "user",
          content = block.content
        })
      elseif block.role == "agent" then
        local content = block.content
        local replay = think_extra[i]
        if replay then
          content = "[think]\n" .. replay .. "\n[/think]\n\n" .. content
        end
        table.insert(conversation_messages, {
          role = "assistant",
          content = content
        })
      elseif block.role == "result" then
        local header = markers.format("result", {
          id = block.id,
          status = block.status,
        }) .. "\n"

        table.insert(conversation_messages, {
          role = "user",
          content = header .. (block.content or "")
        })
      end
    end
    -- [think] blocks and blocks before [reset] are skipped.
    -- [error] and [ask] blocks are plugin UI, never sent to the model.
  end

  -- Apply sliding window max_turns if configured
  if max_turns and max_turns > 0 and #conversation_messages > max_turns then
    local trimmed = {}
    for idx = (#conversation_messages - max_turns + 1), #conversation_messages do
      table.insert(trimmed, conversation_messages[idx])
    end
    conversation_messages = trimmed
  end

  -- Combine system messages and append tools prompt if provided
  local combined_system = table.concat(system_messages, "\n\n")
  if tools_prompt and tools_prompt ~= "" then
    if combined_system ~= "" then
      combined_system = combined_system .. "\n\n" .. tools_prompt
    else
      combined_system = tools_prompt
    end
  end

  if combined_system ~= "" then
    table.insert(messages, {
      role = "system",
      content = combined_system
    })
  end

  for _, msg in ipairs(conversation_messages) do
    table.insert(messages, msg)
  end

  return messages
end

--- Compute a deterministic hash for turn detection
---@param canonical_messages table[]
---@return string
function M.compute_turn_hash(canonical_messages)
  local parts = {}
  for _, msg in ipairs(canonical_messages) do
    table.insert(parts, (msg.role or "") .. ":" .. (msg.content or ""))
  end
  local concatenated = table.concat(parts, "|||")
  return vim.fn.sha256(concatenated)
end

return M
