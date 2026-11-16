local t = require("tests.minimal_init")
local markers = require("agentfile.markers")
local state = require("agentfile.state")
local ui = require("agentfile.ui")

t.run("Fold summaries show kind, status and preview", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "",
    markers.format("result", { id = 1, status = "error" }),
    "Error: boom",
    "more",
    "",
    markers.format("think"),
    "thinking...",
  })

  local summary = ui.fold_summary(2, 4)
  t.assert_true(summary:find("result error", 1, true) ~= nil, "status label")
  t.assert_true(summary:find("✗", 1, true) ~= nil, "error icon")
  t.assert_true(summary:find("Error: boom", 1, true) ~= nil, "first content line preview")
  t.assert_true(summary:find("3 lines", 1, true) ~= nil, "line count")

  local think_summary = ui.fold_summary(6, 7)
  t.assert_true(think_summary:find("think", 1, true) ~= nil, "think label")
  t.assert_true(think_summary:find("thinking...", 1, true) ~= nil, "think preview")
end)

t.run("Statusline reports state, step, context and model", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "---",
    "model: test-model",
    "context_window: 1000",
    "---",
    markers.format("me"),
    "hi",
  })

  local buf_state = state.get(buf)
  buf_state.status = "streaming"
  buf_state.agent_steps = 2
  buf_state.context_used = 950
  buf_state.context_limit = 1000

  local line = ui.statusline(buf)
  t.assert_true(line:find("generating", 1, true) ~= nil, "status text")
  t.assert_true(line:find("step 2/4", 1, true) ~= nil, "step budget")
  t.assert_true(line:find("950/1.0k (95%)", 1, true) ~= nil, "context meter")
  t.assert_true(line:find("test-model", 1, true) ~= nil, "model name")
  t.assert_true(ui.winbar():find("AgentfileContextError", 1, true) ~= nil, "red context at 95%")
end)

t.run("Context suffix highlight follows budget pressure", function()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace("agentfile_context")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "[me](context 1/1)" })

  ui.highlight_context(buf, 1, 0, 8, 750, 1000)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  t.assert_eq(#marks, 1, "one context highlight")
  t.assert_eq(marks[1][4].hl_group, "AgentfileContextWarn", "yellow at 75%")

  ui.highlight_context(buf, 1, 0, 8, 950, 1000)
  marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  t.assert_eq(#marks, 1, "old highlight replaced")
  t.assert_eq(marks[1][4].hl_group, "AgentfileContextError", "red at 95%")

  ui.clear_context(buf)
  marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  t.assert_eq(#marks, 0, "highlight cleared")
end)
