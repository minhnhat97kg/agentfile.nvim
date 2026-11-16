-- tests/test_context.lua
local t = require("tests.minimal_init")
local agentfile = require("agentfile")

local function find_buf(path)
  local target = vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and vim.fn.resolve(name) == target then
      return buf
    end
  end
  return nil
end

t.run("Add multiple context files", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  local f1 = dir .. "/a.lua"
  local f2 = dir .. "/b.lua"
  vim.fn.writefile({ "local a = 1", "return a" }, f1)
  vim.fn.writefile({ "local b = 2" }, f2)

  local chat = dir .. "/chat.agentfile"
  agentfile.last_chat_path = chat

  local src = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(src)

  local added = agentfile.add_context({ f1, f2 })
  t.assert_eq(added, 2, "two files added")

  local chat_buf = find_buf(chat)
  t.assert_true(chat_buf ~= nil, "chat buffer created")

  local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  t.assert_true(text:find("File: `.-a%.lua`") ~= nil, "first file header")
  t.assert_true(text:find("local a = 1", 1, true) ~= nil, "first file content")
  t.assert_true(text:find("local b = 2", 1, true) ~= nil, "second file content")
  t.assert_true(text:find("%[me%]") ~= nil, "me block exists")

  vim.fn.delete(dir, "rf")
end)

t.run("Add current buffer with unsaved changes", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  agentfile.last_chat_path = dir .. "/chat.agentfile"

  local src = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(src)
  vim.api.nvim_buf_set_lines(src, 0, -1, false, { "unsaved_line_here" })

  local added = agentfile.add_context()
  t.assert_eq(added, 1, "current buffer added")

  local chat_buf = find_buf(dir .. "/chat.agentfile")
  t.assert_true(chat_buf ~= nil, "chat buffer created for current buffer")
  local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  t.assert_true(text:find("unsaved_line_here", 1, true) ~= nil, "unsaved content included")

  vim.fn.delete(dir, "rf")
end)

t.run("Glob expansion and deduplication", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "file one" }, dir .. "/one.lua")
  vim.fn.writefile({ "file two" }, dir .. "/two.lua")
  agentfile.last_chat_path = dir .. "/chat.agentfile"

  local src = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(src)

  local added = agentfile.add_context({ dir .. "/*.lua", dir .. "/one.lua" })
  t.assert_eq(added, 2, "glob matched two unique files")

  vim.fn.delete(dir, "rf")
end)
