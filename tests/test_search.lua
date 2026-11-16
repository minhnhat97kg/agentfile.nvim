local t = require("tests.minimal_init")
local tools = require("agentfile.tools")
local state = require("agentfile.state")
local agentfile = require("agentfile")

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
  vim.fn.mkdir(root .. "/sub", "p")
  vim.fn.mkdir(root .. "/.hidden", "p")
  vim.fn.writefile({ "local foo = 1", "local zig = 2" }, root .. "/a.lua")
  vim.fn.writefile({ "foo bar", "baz" }, root .. "/sub/b.lua")
  vim.fn.writefile({ "foo in text" }, root .. "/sub/c.txt")
  vim.fn.writefile({ "hidden foo" }, root .. "/.hidden/d.lua")

  local ok, err = pcall(fn, root)
  vim.fn.delete(root, "rf")
  if not ok then
    error(err)
  end
end

t.run("glob finds files recursively and skips hidden trees", function()
  with_project(function(root)
    local result = wait_for(function(cb)
      tools.execute("glob", { pattern = "**/*.lua", path = root }, cb)
    end)
    t.assert_true(result and result.ok, "glob succeeded")
    t.assert_true(result.text:find("a.lua", 1, true) ~= nil, "root file found")
    t.assert_true(result.text:find("sub/b.lua", 1, true) ~= nil, "nested file found")
    t.assert_true(result.text:find("c.txt", 1, true) == nil, "glob filters extensions")
    t.assert_true(result.text:find(".hidden/d.lua", 1, true) == nil, "hidden tree skipped")

    local dirs = wait_for(function(cb)
      tools.execute("glob", { pattern = "**/*", path = root, type = "dir" }, cb)
    end)
    t.assert_true(dirs and dirs.ok, "glob dirs succeeded")
    t.assert_true(dirs.text:find("sub", 1, true) ~= nil, "directory listed")
  end)
end)

t.run("grep searches contents and respects the glob filter", function()
  with_project(function(root)
    local result = wait_for(function(cb)
      tools.execute("grep", { pattern = "foo", path = root, glob = "*.lua" }, cb)
    end)
    t.assert_true(result and result.ok, "grep succeeded")
    t.assert_true(result.text:find("a.lua:1", 1, true) ~= nil, "root match")
    t.assert_true(result.text:find("sub/b.lua:1", 1, true) ~= nil, "nested match")
    t.assert_true(result.text:find("c.txt", 1, true) == nil, "glob excludes txt")
    t.assert_true(result.text:find(".hidden", 1, true) == nil, "hidden tree skipped")
  end)
end)

t.run("grep supports fixed strings and no-match output", function()
  with_project(function(root)
    local literal = wait_for(function(cb)
      tools.execute("grep", {
        pattern = "foo =",
        path = root,
        glob = "*.lua",
        fixed_strings = true,
      }, cb)
    end)
    t.assert_true(literal and literal.ok, "literal grep succeeded")
    t.assert_true(literal.text:find("a.lua:1", 1, true) ~= nil, "literal match found")

    local none = wait_for(function(cb)
      tools.execute("grep", { pattern = "does-not-exist-xyz", path = root }, cb)
    end)
    t.assert_true(none and none.ok, "no-match is a successful search")
    t.assert_true(none.text:lower():find("no matches", 1, true) ~= nil, "no-match message")
  end)
end)

t.run("list_files can walk recursively", function()
  with_project(function(root)
    local result = wait_for(function(cb)
      tools.execute("list_files", { path = root, recursive = true, max_depth = 2 }, cb)
    end)
    t.assert_true(result and result.ok, "recursive list succeeded")
    t.assert_true(result.text:find("sub/b.lua", 1, true) ~= nil, "nested file listed")
    t.assert_true(result.text:find(".hidden", 1, true) == nil, "hidden tree skipped")
  end)
end)

t.run("run_command supports cwd, env, and timeout", function()
  with_project(function(root)
    local cwd = wait_for(function(cb)
      tools.execute("run_command", { command = "pwd", cwd = root }, cb)
    end)
    t.assert_true(cwd and cwd.ok, "cwd command succeeded")
    t.assert_true(cwd.text:find(root, 1, true) ~= nil, "command runs in cwd")

    local env = wait_for(function(cb)
      tools.execute("run_command", {
        command = 'printf "%s" "$AGENTFILE_TEST"',
        env = { AGENTFILE_TEST = "ok" },
      }, cb)
    end)
    t.assert_true(env and env.ok, "env command succeeded")
    t.assert_true(env.text:find("<output>\nok\n</output>", 1, true) ~= nil, "custom env passed")

    local timed = wait_for(function(cb)
      tools.execute("run_command", { command = "sleep 2", timeout_ms = 50 }, cb)
    end, 4000)
    t.assert_true(timed ~= nil, "timeout returned a result")
    t.assert_true(timed.ok == false, "timeout is a failure")
    t.assert_true(timed.text:find("<returncode>124</returncode>", 1, true) ~= nil, "timeout exit code")
    t.assert_true(timed.text:find("<timeout>50ms</timeout>", 1, true) ~= nil, "timeout note")
  end)
end)

t.run("AgentfileCancel kills a running command", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  local buf_state = state.get(buf)
  buf_state.status = "tools_running"

  local done, result
  tools.execute("run_command", { command = "sleep 5" }, function(ok, text)
    done = true
    result = { ok = ok, text = text }
  end, { buf_state = buf_state })

  t.assert_true(vim.wait(2000, function()
    return buf_state.active_command ~= nil
  end), "command started")

  agentfile.cancel(buf)
  t.assert_true(vim.wait(2000, function() return done == true end), "cancelled command exits")
  t.assert_true(result and result.ok == false, "cancelled command reports failure")
  t.assert_eq(buf_state.active_command, nil, "active command cleared")
end)
