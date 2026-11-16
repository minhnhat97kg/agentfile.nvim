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

local function read(path)
  local file = io.open(path, "r")
  local data = file:read("*a")
  file:close()
  return data:gsub("\n$", "")
end

local function with_file(content, fn)
  local path = vim.fn.tempname()
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
  local ok, err = pcall(fn, path)
  vim.fn.delete(path)
  if not ok then
    error(err)
  end
end

t.run("apply_patch applies a single hunk", function()
  with_file("alpha\nbeta\ngamma", function(path)
    local result = wait_for(function(cb)
      tools.execute("apply_patch", {
        path = path,
        patch = "@@ -2,1 +2,1 @@\n-beta\n+BETA\n",
      }, cb)
    end)
    t.assert_true(result and result.ok, "patch applied")
    t.assert_eq(read(path), "alpha\nBETA\ngamma", "single hunk applied")
  end)
end)

t.run("apply_patch applies multiple hunks", function()
  with_file("a\nb\nc\nd", function(path)
    local result = wait_for(function(cb)
      tools.execute("apply_patch", {
        path = path,
        patch = "@@ -2,1 +2,1 @@\n-b\n+B\n@@ -4,1 +4,1 @@\n-d\n+D\n",
      }, cb)
    end)
    t.assert_true(result and result.ok, "multi hunk applied")
    t.assert_eq(read(path), "a\nB\nc\nD", "both hunks applied")
  end)
end)

t.run("apply_patch tolerates line-offset fuzz", function()
  with_file("a\nb\nc", function(path)
    local result = wait_for(function(cb)
      tools.execute("apply_patch", {
        path = path,
        patch = "@@ -3,1 +3,1 @@\n-b\n+B\n",
      }, cb)
    end)
    t.assert_true(result and result.ok, "fuzzed hunk applied")
    t.assert_eq(read(path), "a\nB\nc", "offset corrected by fuzz")
  end)
end)

t.run("apply_patch reports an unfound hunk", function()
  with_file("a\nb\nc", function(path)
    local result = wait_for(function(cb)
      tools.execute("apply_patch", {
        path = path,
        patch = "@@ -20,1 +20,1 @@\n-zzz\n+ZZZ\n",
      }, cb)
    end)
    t.assert_true(result and result.ok == false, "unmatched hunk is an error")
    t.assert_true(result.text:find("does not match", 1, true) ~= nil, "error explains mismatch")
    t.assert_eq(read(path), "a\nb\nc", "file unchanged on failure")
  end)
end)

t.run("apply_patch rejects a patch without hunks", function()
  with_file("a\nb\nc", function(path)
    local result = wait_for(function(cb)
      tools.execute("apply_patch", { path = path, patch = "just some text\n" }, cb)
    end)
    t.assert_true(result and result.ok == false, "no hunks is an error")
    t.assert_true(result.text:find("No @@ hunks", 1, true) ~= nil, "error names the problem")
  end)
end)
