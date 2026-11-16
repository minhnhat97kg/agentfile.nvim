-- tests/test_snapshot.lua
local t = require("tests.minimal_init")
local snapshot = require("agentfile.snapshot")

t.run("Snapshot record, diff and revert", function()
  local test_file = "/tmp/agentfile_test_snapshot.txt"
  -- Create initial file
  vim.fn.writefile({ "hello", "world" }, test_file)

  -- Record before
  snapshot.record_before(101, test_file)

  -- Modify file
  vim.fn.writefile({ "hello", "there", "world" }, test_file)
  snapshot.record_after(101, test_file)

  -- Check diff
  local diff_res = snapshot.diff(101)
  t.assert_true(diff_res ~= nil, "diff exists")
  t.assert_true(diff_res:find("%+there") ~= nil, "diff shows added line")

  -- Revert
  local ok, msg = snapshot.revert(101)
  t.assert_eq(ok, true, "revert succeeded")
  local restored = vim.fn.readfile(test_file)
  t.assert_eq(restored, { "hello", "world" }, "content restored to original")

  -- Clean up
  vim.fn.delete(test_file)
end)

t.run("Snapshot revert for newly created file", function()
  local test_file = "/tmp/agentfile_test_new_file.txt"
  if vim.fn.filereadable(test_file) == 1 then vim.fn.delete(test_file) end

  snapshot.record_before(102, test_file)
  vim.fn.writefile({ "brand new" }, test_file)
  snapshot.record_after(102, test_file)

  local ok, msg = snapshot.revert(102)
  t.assert_eq(ok, true, "revert succeeded")
  t.assert_eq(vim.fn.filereadable(test_file), 0, "newly created file deleted on revert")
end)
