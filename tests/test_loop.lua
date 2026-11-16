local t = require("tests.minimal_init")
local loop = require("agentfile.loop")

local function base_ctx(step)
  return {
    config = { agent = { enabled = true, max_steps = 4 } },
    agent = { enabled = true, max_steps = 4 },
    buf_state = { agent_steps = step or 1, format_errors = 0 },
    blocks = {},
  }
end

t.run("planner strategies: react vs plan_first", function()
  local react1 = loop.planners.react(base_ctx(1))
  t.assert_true(react1:find("Agent step 1 of 4", 1, true) ~= nil, "react reports step")

  local react4 = loop.planners.react(base_ctx(4))
  t.assert_true(react4:find("This is your FINAL step", 1, true) ~= nil, "react flags final step")

  local plan = loop.planners.plan_first(base_ctx(1))
  t.assert_true(plan:find("step-by-step plan", 1, true) ~= nil, "plan_first asks for a plan")
  t.assert_true(plan:find("Agent step 1 of 4", 1, true) ~= nil, "plan_first keeps react notes")

  local plan_late = loop.planners.plan_first(base_ctx(3))
  t.assert_true(plan_late:find("step-by-step plan", 1, true) == nil, "plan_first only on opening step")
end)

t.run("register overrides the default strategy with graceful fallback", function()
  loop.register("planner", "minimal", function() return "MINIMAL" end)
  local out = loop.run_planner({
    config = { agent = { planner = "minimal" } },
    buf_state = { agent_steps = 1 },
    blocks = {},
  })
  t.assert_eq(out, "MINIMAL", "custom planner selected via frontmatter")

  local fallback = loop.run_planner({
    config = { agent = { planner = "does_not_exist" } },
    agent = { enabled = true, max_steps = 4 },
    buf_state = { agent_steps = 1 },
    blocks = {},
  })
  t.assert_true(fallback:find("Agent step", 1, true) ~= nil, "unknown planner falls back to react")
end)

t.run("scope planner clarifies vague requests and states scope otherwise", function()
  local vague_ctx = base_ctx(1)
  vague_ctx.blocks = { { role = "user", content = "fix the bug" } }
  local vague = loop.planners.scope(vague_ctx)
  t.assert_true(vague:find("underspecified", 1, true) ~= nil, "vague request asks to clarify")
  t.assert_true(vague:find("Agent step 1 of 4", 1, true) ~= nil, "scope keeps react notes")

  local specific_ctx = base_ctx(1)
  specific_ctx.blocks = { { role = "user", content = "Fix lua/agentfile/ui.lua winbar rendering" } }
  local specific = loop.planners.scope(specific_ctx)
  t.assert_true(specific:find("underspecified", 1, true) == nil, "specific request does not clarify")
  t.assert_true(specific:find("concrete scope", 1, true) ~= nil, "specific request asks for a scope statement")

  local late = loop.planners.scope(base_ctx(3))
  t.assert_true(late:find("underspecified", 1, true) == nil
    and late:find("concrete scope", 1, true) == nil, "scope only on opening step")
end)

t.run("sequential executor runs tools in order", function()
  local order = {}
  local finished = false
  loop.run_executor({
    config = {},
    calls = {
      { name = "read_file", args = { path = "a" } },
      { name = "read_file", args = { path = "b" } },
      { name = "write_file", args = { path = "c" } },
    },
    run_one = function(call, cb)
      order[#order + 1] = call.name
      cb("continue")
    end,
    finish = function() finished = true end,
  })
  t.assert_eq(order, { "read_file", "read_file", "write_file" }, "in order")
  t.assert_true(finished, "finish called after batch")
end)

t.run("parallel_reads launches all reads before the write", function()
  local started = {}
  local finished = false
  loop.run_executor({
    config = { agent = { executor = "parallel_reads" } },
    calls = {
      { name = "read_file", args = { path = "a" } },
      { name = "read_file", args = { path = "b" } },
      { name = "write_file", args = { path = "c" } },
    },
    run_one = function(call, cb)
      started[#started + 1] = call.name
      vim.schedule(function() cb("continue") end)
    end,
    finish = function() finished = true end,
  })
  t.assert_eq(started, { "read_file", "read_file" }, "reads launched before write")
  t.assert_true(vim.wait(1000, function() return finished end), "finishes after async callbacks")
end)

t.run("parallel_reads falls back to sequential for done-only batches", function()
  local order = {}
  loop.run_executor({
    config = { agent = { executor = "parallel_reads" } },
    calls = { { name = "done", args = {} } },
    run_one = function(call, cb)
      order[#order + 1] = call.name
      cb("done")
    end,
    finish = function() order[#order + 1] = "finish" end,
  })
  t.assert_eq(order, { "done" }, "done handled, finish not called")
end)
