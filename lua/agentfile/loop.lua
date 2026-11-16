-- lua/agentfile/loop.lua
-- Modular agent loop: the loop is decomposed into a small set of *phases*,
-- each implemented by a replaceable *strategy*. Frontmatter selects a strategy
-- per phase (e.g. `agent.planner`, `agent.executor`); new strategies register
-- via require("agentfile.loop").register(phase, name, impl).
--
-- Phases today:
--   planner   -> builds the system-prompt augmentation for the next model call
--                (progress note, thinking controls, recovery nudges, plan).
--   executor  -> runs a batch of tool calls (sequential vs parallel reads).
--
-- The heavy Neovim primitives (buffer writes, approval UI, tool execution)
-- stay in init.lua and are injected through `env` so strategies stay pure and
-- easy to swap.

local tools = require("agentfile.tools")

local M = {}

-- phase -> { name -> impl }
M._strategies = {}

-- Public strategy tables (referenced by default strategies and tests).
M.planners = {}
M.executors = {}

--- Register a strategy implementation for a phase.
---@param phase string # "planner" | "executor" | ...
---@param name string
---@param impl function
function M.register(phase, name, impl)
  M._strategies[phase] = M._strategies[phase] or {}
  M._strategies[phase][name] = impl
end

--- Pick the strategy name configured for a phase, falling back gracefully.
---@param phase string
---@param config table
---@param default string
---@return string
local function select_name(phase, config, default)
  local agent = (config and config.agent) or {}
  local name = agent[phase]
  if type(name) == "string" and M._strategies[phase] and M._strategies[phase][name] then
    return name
  end
  return default
end

----------------------------------------------------------------------
-- Planners
-- A planner receives ctx = { bufnr, config, agent, buf_state, blocks } and
-- returns a string appended to the system message (or "").
----------------------------------------------------------------------

--- Status of the most recent [result] in the active turn, or nil.
local function last_result_status(blocks)
  for i = #blocks, 1, -1 do
    local block = blocks[i]
    if block.role == "result" then
      return block.status
    end
    if block.role == "user" then
      return nil
    end
  end
  return nil
end

--- Default planner: ReAct progress note + thinking controls + recovery nudges.
function M.planners.react(ctx)
  local buf_state = ctx.buf_state
  local agent = ctx.agent
  local config = ctx.config
  local blocks = ctx.blocks
  local parts = {}

  if agent and agent.enabled then
    local progress = string.format("Agent step %d of %d.", buf_state.agent_steps, agent.max_steps)
    if buf_state.agent_steps == agent.max_steps then
      progress = progress .. " This is your FINAL step. Do not call tools. Answer the user's request using the results already available."
        .. " Clearly state anything you could not verify; do not invent unread file contents."
    else
      progress = progress .. " Avoid repeating successful reads/listings. Inspect relevant unread source files, then summarize."
    end
    parts[#parts + 1] = progress
  end

  local is_thinking_disabled = config.thinking == false
    or (type(config.thinking) == "table" and config.thinking.enabled == false)
  local is_thinking_concise = config.thinking_concise == true
    or (type(config.thinking) == "table" and config.thinking.concise == true)
  if is_thinking_disabled then
    parts[#parts + 1] = "Skip internal thinking (<think>...</think>). Provide the response directly."
  elseif is_thinking_concise then
    parts[#parts + 1] = "Think concisely: keep your internal reasoning brief, focused, and under 150 words before answering."
  end

  if (buf_state.format_errors or 0) > 0 and buf_state.last_format_error then
    parts[#parts + 1] = "Your previous response was invalid: " .. buf_state.last_format_error
      .. ". Respond with exactly one valid tool call or a concise final answer, and be brief."
  end

  if last_result_status(blocks) == "error" then
    parts[#parts + 1] = "The last tool call failed. State the root cause in one sentence in [think], then do something different. Do not repeat the identical call."
  end

  return table.concat(parts, "\n\n")
end

--- Plan-first planner: on the opening step, ask for a short plan before acting.
--- Helps small models stay on goal across many steps (Plan-and-Solve).
function M.planners.plan_first(ctx)
  local parts = {}
  if (ctx.buf_state.agent_steps or 0) <= 1 then
    parts[#parts + 1] = "Before calling tools, write a concise step-by-step plan first (one short line per step). Then execute it; if you get stuck, re-read and revise the plan."
  end
  local base = M.planners.react(ctx)
  if base ~= "" then
    parts[#parts + 1] = base
  end
  return table.concat(parts, "\n\n")
end

--- Run the configured planner and return its augmentation text.
---@param ctx table
---@return string
function M.run_planner(ctx)
  local name = select_name("planner", ctx.config, "react")
  local impl = M._strategies.planner[name] or M.planners.react
  return impl(ctx)
end

----------------------------------------------------------------------
-- Executors
-- An executor receives env = { bufnr, config, agent, buf_state, calls,
-- run_one, finish } where:
--   run_one(call, cb) runs one tool and calls cb("continue" | "done" | "stop")
--   finish() ends the batch normally (transition idle + next model call)
----------------------------------------------------------------------

--- Sequential executor: run tools one at a time in the given order.
function M.executors.sequential(env)
  local calls = env.calls
  local i = 1
  local function next_step()
    if i > #calls then
      env.finish()
      return
    end
    local call = calls[i]
    i = i + 1
    env.run_one(call, function(decision)
      if decision == "continue" then
        next_step()
      end
      -- "done" / "stop" end the batch without the next model call.
    end)
  end
  next_step()
end

--- Parallel-reads executor: run all read-only tools concurrently, then any
--- file-modifying/command tool sequentially (ReWOO-inspired: batch the reads,
--- feed results once). Falls back to sequential when there is nothing to
--- parallelize.
function M.executors.parallel_reads(env)
  local calls = env.calls
  local reads, rest = {}, {}
  local has_done = false
  for _, call in ipairs(calls) do
    if call.name == "done" then
      has_done = true
    elseif not tools.is_dangerous(call.name) then
      reads[#reads + 1] = call
    else
      rest[#rest + 1] = call
    end
  end

  if has_done or #reads == 0 then
    M.executors.sequential(env)
    return
  end

  local function run_rest()
    if #rest == 0 then
      env.finish()
    else
      local sub = {}
      for k, v in pairs(env) do sub[k] = v end
      sub.calls = rest
      M.executors.sequential(sub)
    end
  end

  local pending = #reads
  local finished = false
  local function one_done()
    pending = pending - 1
    if pending == 0 and not finished then
      finished = true
      run_rest()
    end
  end

  for _, call in ipairs(reads) do
    env.run_one(call, function(_) one_done() end)
  end
  if pending == 0 and not finished then
    finished = true
    run_rest()
  end
end

--- Run the configured executor for a tool batch.
---@param env table
function M.run_executor(env)
  local name = select_name("executor", env.config, "sequential")
  local impl = M._strategies.executor[name] or M.executors.sequential
  impl(env)
end

M.register("planner", "react", M.planners.react)
M.register("planner", "plan_first", M.planners.plan_first)
M.register("executor", "sequential", M.executors.sequential)
M.register("executor", "parallel_reads", M.executors.parallel_reads)

return M
