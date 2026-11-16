-- tests/test_session.lua
local t = require("tests.minimal_init")
local session = require("agentfile.session")

t.run("Session generate path and list", function()
  local path = session.generate_path("auth-feature")
  t.assert_true(path:find("auth%-feature%.agentfile") ~= nil, "generates topic path")
  t.assert_true(path:find("%.agentfile") ~= nil, "uses .agentfile folder")

  -- Create a file and list
  vim.fn.writefile({ "test" }, path)
  local list = session.list()
  t.assert_true(#list > 0, "lists created sessions")
  vim.fn.delete(path)
end)

t.run("Session branch current buffer", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "---",
    "model: test",
    "---",
    "[me]",
    "First idea",
    "",
    "[agent]",
    "First answer",
    "",
    "[me]",
    "Second idea to drop",
  })

  -- Branch up to line 8 (stops after First answer)
  local new_path = session.branch(bufnr, 8, "alt-idea")
  t.assert_true(vim.fn.filereadable(new_path) == 1, "branched file was created")
  local lines = vim.fn.readfile(new_path)
  t.assert_eq(#lines, 8, "branched exact line count")
  t.assert_eq(lines[8], "First answer", "stops at line 8")

  vim.fn.delete(new_path)
end)
