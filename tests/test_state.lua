-- tests/test_state.lua
local t = require("tests.minimal_init")
local state = require("agentfile.state")

t.run("State Machine Transitions", function()
  local bufnr = 1
  state.reset(bufnr)

  t.assert_eq(state.get(bufnr).status, "idle", "initial status is idle")

  -- Valid transition: idle -> parsing
  t.assert_true(state.transition(bufnr, "parsing"), "transition to parsing ok")
  t.assert_eq(state.get(bufnr).status, "parsing", "status is parsing")

  -- Valid transition: parsing -> streaming
  t.assert_true(state.transition(bufnr, "streaming"), "transition to streaming ok")

  -- Invalid transition: streaming directly to parsing is not allowed
  t.assert_eq(state.transition(bufnr, "parsing"), false, "invalid transition rejected")

  -- Valid transition: streaming -> idle
  t.assert_true(state.transition(bufnr, "idle"), "transition back to idle ok")
end)

t.run("Turn Detection on Save", function()
  local bufnr = 2
  state.reset(bufnr)

  local lines_save_header_only = {
    "---",
    "model: gpt-4o",
    "---",
    "",
    "[system]",
    "You are a test bot.",
    "",
    "[agent]",
    "I answered already."
  }

  -- Last block is agent, so saving should NOT trigger send
  local should_send, reason = state.should_trigger_send(bufnr, lines_save_header_only)
  t.assert_eq(should_send, false, "saving when last block is agent should not trigger send")

  local lines_with_new_me = {
    "---",
    "model: gpt-4o",
    "---",
    "",
    "[system]",
    "You are a test bot.",
    "",
    "[agent]",
    "I answered already.",
    "",
    "[me]",
    "Tell me more!"
  }

  -- Last block is [me], should trigger send
  should_send, reason = state.should_trigger_send(bufnr, lines_with_new_me)
  t.assert_eq(should_send, true, "saving with new [me] should trigger send")

  -- Simulate that turn was sent and hash recorded
  state.record_sent(bufnr, lines_with_new_me)

  -- Save again with exact same content -> should NOT send duplicate!
  should_send, reason = state.should_trigger_send(bufnr, lines_with_new_me)
  t.assert_eq(should_send, false, "identical content should not trigger duplicate send")
  t.assert_eq(reason, "unchanged_hash", "reason is unchanged_hash")
end)
