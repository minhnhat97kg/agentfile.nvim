-- tests/test_context_extra.lua
local t = require("tests.minimal_init")
local context_extra = require("agentfile.context_extra")

t.run("Format diagnostics", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/test_context_file.lua")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = 1", "y = 2" })

  local fake_diags = {
    {
      bufnr = bufnr,
      lnum = 1,
      col = 0,
      severity = vim.diagnostic.severity.ERROR,
      message = "undefined variable y",
      source = "lua_ls",
    },
    {
      bufnr = bufnr,
      lnum = 0,
      col = 6,
      severity = vim.diagnostic.severity.WARN,
      message = "unused variable x",
      source = "lua_ls",
    }
  }

  local formatted = context_extra.format_diagnostic_items(fake_diags)
  t.assert_true(formatted ~= nil, "returns formatted string")
  t.assert_true(formatted:find("%[ERROR%]") ~= nil, "contains ERROR")
  t.assert_true(formatted:find("%[WARN%]") ~= nil, "contains WARN")
  t.assert_true(formatted:find("undefined variable y") ~= nil, "contains message")
  t.assert_true(formatted:find("test_context_file%.lua") ~= nil, "contains file name")
end)

t.run("Format git diff", function()
  -- Using a mock runner for git diff
  local formatted = context_extra.format_diff_output("diff --git a/foo b/foo\n+new line")
  t.assert_true(formatted:find("```diff") ~= nil, "fences diff")
  t.assert_true(formatted:find("%+new line") ~= nil, "includes diff content")
end)
