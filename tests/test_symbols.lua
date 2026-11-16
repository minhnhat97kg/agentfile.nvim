local t = require("tests.minimal_init")
local tools = require("agentfile.tools")

local function wait_for(fn, timeout)
  local done, result
  fn(function(ok, text)
    done = true
    result = { ok = ok, text = text }
  end)
  vim.wait(timeout or 5000, function()
    return done == true
  end)
  return result
end

local function with_project(fn)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({
    "local M = {}",
    "",
    "local function helper(x)",
    "  return x * 2",
    "end",
    "",
    "function M.run(args)",
    "  local function inner()",
    "    return 1",
    "  end",
    "  return helper(args)",
    "end",
    "",
    "function M.stop()",
    "  return nil",
    "end",
  }, root .. "/mod.lua")
  vim.fn.writefile({
    "local other = require('mod')",
    "",
    "function standalone()",
    "  return 1",
    "end",
  }, root .. "/other.lua")

  local ok, err = pcall(fn, root)
  vim.fn.delete(root, "rf")
  if not ok then
    error(err)
  end
end

t.run("symbols lists top-level declarations", function()
  with_project(function(root)
    local result = wait_for(function(cb)
      tools.execute("symbols", { path = root, glob = "*.lua" }, cb)
    end)
    t.assert_true(result and result.ok, "symbols succeeded")
    t.assert_true(result.text:find("mod.lua:7 function M.run", 1, true) ~= nil, "function listed with line")
    t.assert_true(result.text:find("mod.lua:14 function M.stop", 1, true) ~= nil, "second function listed")
    t.assert_true(result.text:find("other.lua:3 function standalone", 1, true) ~= nil, "file prefix present")
    t.assert_true(result.text:find("mod.lua:3 function helper", 1, true) ~= nil, "module-level local function listed")
    t.assert_true(result.text:find("inner", 1, true) == nil, "indented nested function is not top-level")
  end)
end)

t.run("skeleton prunes bodies except the focused symbol", function()
  with_project(function(root)
    local result = wait_for(function(cb)
      tools.execute("skeleton", { path = root .. "/mod.lua", focus = "M.run" }, cb)
    end)
    t.assert_true(result and result.ok, "skeleton succeeded")
    t.assert_true(result.text:find("## declarations", 1, true) ~= nil, "declarations section")
    t.assert_true(result.text:find("## focus: M.run", 1, true) ~= nil, "focus body header")
    t.assert_true(result.text:find("return helper(args)", 1, true) ~= nil, "focus body included")
    t.assert_true(result.text:find("return nil", 1, true) == nil, "unfocused body elided")
    t.assert_true(result.text:find("function M.stop()", 1, true) ~= nil, "unfocused signature kept")
  end)
end)

t.run("skeleton reports a missing focus", function()
  with_project(function(root)
    local result = wait_for(function(cb)
      tools.execute("skeleton", { path = root .. "/mod.lua", focus = "nope" }, cb)
    end)
    t.assert_true(result and result.ok, "skeleton succeeds with missing focus")
    t.assert_true(result.text:find("focus \"nope\" not found", 1, true) ~= nil, "missing focus note")
  end)
end)

t.run("skeleton rejects a missing file", function()
  local result = wait_for(function(cb)
    tools.execute("skeleton", { path = "/definitely/not/here.lua" }, cb)
  end)
  t.assert_true(result and result.ok == false, "missing file is an error")
  t.assert_true(result.text:find("not found", 1, true) ~= nil, "error names the problem")
end)
