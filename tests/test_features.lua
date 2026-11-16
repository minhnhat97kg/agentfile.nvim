-- tests/test_features.lua
local t = require("tests.minimal_init")
local agentfile = require("agentfile")
local snapshot = require("agentfile.snapshot")

t.run("AgentfileNew creates a new session buffer with template", function()
  agentfile.new_session("my-feature")
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  t.assert_true(name:find("my%-feature%.agentfile") ~= nil, "created my-feature session")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  t.assert_true(#lines > 0, "has template lines")
  t.assert_true(lines[1] == "---", "has frontmatter")
  vim.fn.delete(name)
end)

t.run("AgentfileUndo reverts file modification from snapshot", function()
  local test_file = "/tmp/agentfile_test_revert_feature.txt"
  vim.fn.writefile({ "initial text" }, test_file)

  -- Record snapshot with tool id 99
  snapshot.record_before(99, test_file)
  vim.fn.writefile({ "edited text" }, test_file)
  snapshot.record_after(99, test_file)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "---", "model: test", "---",
    "[me]", "edit file",
    "",
    "[agent]", "@edit_file(...)",
    "",
    "[result id=99 status=ok]",
    "Successfully edited",
    "",
  })
  -- Put cursor on line 7 ([result id=99])
  vim.api.nvim_win_set_cursor(0, { 7, 0 })

  agentfile.undo_tool(bufnr)

  local lines = vim.fn.readfile(test_file)
  t.assert_eq(lines, { "initial text" }, "restored original file content")

  local buf_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  t.assert_true(buf_text:find("%[result id=99 status=reverted%]") ~= nil, "updated status to reverted")

  vim.fn.delete(test_file)
end)

t.run("AgentfileToggle opens and closes chat split", function()
  local initial_wins = #vim.api.nvim_list_wins()
  agentfile.toggle("test_toggle.agentfile")
  t.assert_eq(#vim.api.nvim_list_wins(), initial_wins + 1, "split window opened")

  -- Toggle again to close
  agentfile.toggle("test_toggle.agentfile")
  t.assert_eq(#vim.api.nvim_list_wins(), initial_wins, "split window closed")

  local full = vim.fn.fnamemodify("test_toggle.agentfile", ":p")
  if vim.fn.filereadable(full) == 1 then vim.fn.delete(full) end
end)
