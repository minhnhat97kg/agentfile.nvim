-- tests/test_tools.lua
local t = require("tests.minimal_init")
local tools = require("agentfile.tools")

t.run("Tool Registry & Schema Prompt", function()
  tools.register("custom_greet", {
    description = "Greet someone by name",
    parameters = {
      name = "string (person to greet)"
    },
    is_dangerous = false,
    run = function(args, cb)
      cb(true, "Hello, " .. (args.name or "world") .. "!")
    end
  })

  local prompt = tools.get_schema_prompt({"custom_greet"})
  t.assert_true(prompt:find("AVAILABLE TOOLS:") ~= nil, "prompt contains header")
  t.assert_true(prompt:find("custom_greet") ~= nil, "prompt contains registered tool name")
  t.assert_true(prompt:find("Greet someone by name") ~= nil, "prompt contains description")
end)

t.run("Filesystem Tools: read_file and write_file", function()
  local test_file = "tests/scratch_test.txt"
  -- write file
  local done = false
  tools.execute("write_file", { path = test_file, content = "Line 1\nLine 2\nLine 3" }, function(ok, result)
    t.assert_true(ok, "write_file succeeded")
    done = true
  end)
  t.assert_true(done, "write_file callback fired")

  -- read file
  done = false
  tools.execute("read_file", { path = test_file, start_line = 1, end_line = 2 }, function(ok, result)
    t.assert_true(ok, "read_file succeeded")
    t.assert_true(result:find("Line 1") ~= nil, "read_file contains Line 1")
    t.assert_true(result:find("Line 2") ~= nil, "read_file contains Line 2")
    done = true
  end)
  t.assert_true(done, "read_file callback fired")

  -- clean up
  os.remove(test_file)
end)

t.run("Shell Tool: run_command", function()
  local done = false
  local res_ok, res_text
  tools.execute("run_command", { command = "echo 'hello from shell'" }, function(ok, result)
    res_ok = ok
    res_text = result
    done = true
  end)

  -- Wait briefly for async execution if needed
  vim.wait(1000, function() return done end, 50)
  t.assert_true(done, "run_command finished")
  t.assert_true(res_ok, "run_command returned ok")
  t.assert_true(res_text:find("hello from shell") ~= nil, "run_command stdout matches")
end)

t.run("Directory listings provide reusable paths without changing cwd", function()
  local root = vim.fn.tempname()
  local cwd = vim.fn.getcwd()
  vim.fn.mkdir(root .. "/settings", "p")
  root = (vim.uv or vim.loop).fs_realpath(root)
  vim.fn.writefile({ "package settings" }, root .. "/settings/settings.go")
  vim.fn.writefile({ "hidden" }, root .. "/settings/.hidden")
  vim.fn.mkdir(root .. "/empty", "p")
  local ok, err = pcall(function()
    vim.api.nvim_set_current_dir(root)
    tools.execute("list_files", { path = "settings" }, function(success, text)
      t.assert_true(success, "lists nested directory")
      t.assert_true(text:find("[file] settings/settings.go", 1, true) ~= nil, "file path includes directory")
      t.assert_true(text:find("[file] settings/.hidden", 1, true) ~= nil, "hidden entries included")
      t.assert_eq(vim.fn.getcwd(), root, "listing leaves working directory unchanged")
      local path
      for _, line in ipairs(vim.split(text, "\n")) do
        local candidate = line:match("^%[file%] (.+)$")
        if candidate and candidate:match("settings%.go$") then path = candidate end
      end
      tools.execute("read_file", { path = path }, function(read_ok, content)
        t.assert_true(read_ok, "listed path can be passed directly to read_file")
        t.assert_eq(content, "package settings", "reads correct file")
      end)
    end)
    tools.execute("list_files", { path = root .. "/settings" }, function(success, text)
      t.assert_true(success, "absolute directory supported")
      t.assert_true(text:find("[file] " .. root .. "/settings/settings.go", 1, true) ~= nil, "absolute paths preserved")
    end)
    tools.execute("list_files", { path = "empty" }, function(success, text)
      t.assert_true(success, "empty directory succeeds")
      t.assert_true(text:find("(empty directory)", 1, true) ~= nil, "empty listing is explicit")
    end)
    tools.execute("list_files", { path = "missing" }, function(success, text)
      t.assert_eq(success, false, "missing directory is an error")
      t.assert_true(text:find("missing", 1, true) ~= nil, "error names requested path")
    end)
    tools.execute("read_file", { path = "settings.go" }, function(success, text)
      t.assert_eq(success, false, "wrong basename fails")
      t.assert_true(text:find(root, 1, true) ~= nil, "read error explains working directory")
    end)
    tools.execute("read_file", { path = "settings" }, function(success, text)
      t.assert_eq(success, false, "read_file rejects directories before reading")
      t.assert_true(text:find("is a directory", 1, true) ~= nil, "directory error is explicit")
      t.assert_true(text:find('@list_files({"path":"settings"})', 1, true) ~= nil, "directory error suggests the exact next call")
      t.assert_true(text:find("Execution error", 1, true) == nil, "no internal Lua stack location leaks")
    end)
    tools.execute("read_file", { path = "./settings/../settings/settings.go" }, function(success, text)
      t.assert_eq(success, false, "agent cannot recursively read its active chat")
      t.assert_true(text:find("already in your conversation context", 1, true) ~= nil, "self-read result explains recovery")
      t.assert_true(text:find("package settings", 1, true) == nil, "active chat content is not returned")
    end, { chat_path = root .. "/settings/settings.go" })
    tools.execute("read_file", { path = "settings/settings.go" }, function(success, text)
      t.assert_true(success, "a different chat path does not block ordinary reads")
      t.assert_eq(text, "package settings", "ordinary file content preserved")
    end, { chat_path = root .. "/other-chat.agentfile" })
  end)
  vim.api.nvim_set_current_dir(cwd)
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end)

t.run("edit_file rejects an ambiguous target", function()
  local path = "tests/scratch_ambig.txt"
  vim.fn.writefile({ "foo", "bar", "foo", "baz" }, path)

  -- Unique target still works.
  tools.execute("edit_file", { path = path, target = "bar", replacement = "BAR" }, function(ok)
    t.assert_true(ok, "unique target edits")
  end)
  t.assert_true(vim.fn.readfile(path)[2] == "BAR", "first line replaced")

  -- Ambiguous target is refused with actionable guidance.
  tools.execute("edit_file", { path = path, target = "foo", replacement = "X" }, function(ok, result)
    t.assert_eq(ok, false, "ambiguous target fails")
    t.assert_true(result:find("appears 2 times", 1, true) ~= nil, "counts occurrences")
    t.assert_true(result:find("occurrence", 1, true) ~= nil, "suggests occurrence arg")
  end)

  -- Explicit occurrence replaces the right one.
  tools.execute("edit_file", { path = path, target = "foo", replacement = "X", occurrence = 2 }, function(ok)
    t.assert_true(ok, "occurrence edit succeeds")
  end)
  local lines = vim.fn.readfile(path)
  t.assert_eq(lines[1], "foo", "first occurrence untouched")
  t.assert_eq(lines[3], "X", "second occurrence replaced")

  -- replace_all.
  tools.execute("edit_file", { path = path, target = "foo", replacement = "Y", replace_all = true }, function(ok)
    t.assert_true(ok, "replace_all succeeds")
  end)
  t.assert_eq(vim.fn.readfile(path)[1], "Y", "all occurrences replaced")

  os.remove(path)
end)

t.run("read_file reports a line-range note", function()
  local path = "tests/scratch_lines.txt"
  local lines = {}
  for i = 1, 5 do lines[i] = "line " .. i end
  vim.fn.writefile(lines, path)

  tools.execute("read_file", { path = path, start_line = 2, end_line = 3 }, function(ok, text)
    t.assert_true(ok, "range read ok")
    t.assert_true(text:find("line 2", 1, true) ~= nil, "start line present")
    t.assert_true(text:find("Showing lines 2-3 of 5", 1, true) ~= nil, "range note present")
  end)

  tools.execute("read_file", { path = path, start_line = 99 }, function(ok, text)
    t.assert_true(ok, "beyond-end read is a soft error")
    t.assert_true(text:find("beyond the end", 1, true) ~= nil, "explains the miss")
  end)

  os.remove(path)
end)

t.run("Long tool output is truncated with head and tail", function()
  local path = "tests/scratch_long.txt"
  local lines = {}
  for i = 1, 300 do lines[i] = string.rep("A", 40) end
  lines[#lines + 1] = "SECRET-END"
  vim.fn.writefile(lines, path)

  tools.execute("read_file", { path = path }, function(ok, text)
    t.assert_true(ok, "read ok")
    t.assert_true(text:find("characters elided", 1, true) ~= nil, "reports elision")
    t.assert_true(text:find("SECRET-END", 1, true) ~= nil, "tail preserved")
  end, { config = { context_window = 1000 } })

  os.remove(path)
end)

t.run("Shell results carry an explicit return code", function()
  local done = false
  tools.execute("run_command", { command = "echo hello" }, function(ok, result)
    t.assert_true(ok, "command succeeds")
    t.assert_true(result:find("<returncode>0</returncode>", 1, true) ~= nil, "exit code present")
    t.assert_true(result:find("<output>", 1, true) ~= nil, "output section present")
    t.assert_true(result:find("hello", 1, true) ~= nil, "stdout captured")
    done = true
  end)
  vim.wait(1000, function() return done end, 50)

  done = false
  tools.execute("run_command", { command = "exit 3" }, function(ok, result)
    t.assert_eq(ok, false, "non-zero exit fails")
    t.assert_true(result:find("<returncode>3</returncode>", 1, true) ~= nil, "failure code present")
    done = true
  end)
  vim.wait(1000, function() return done end, 50)
end)

t.run("Tool batch policy allows one mutating call", function()
  t.assert_eq(tools.validate_batch({ { name = "read_file" }, { name = "list_files" } }), true,
    "read-only batches are fine")
  t.assert_eq(tools.validate_batch({ { name = "read_file" }, { name = "write_file" } }), true,
    "one write is fine")
  local ok, err = tools.validate_batch({ { name = "write_file" }, { name = "edit_file" } })
  t.assert_eq(ok, false, "two writes are rejected")
  t.assert_true(err:find("Only one file-modifying", 1, true) ~= nil, "explains the rule")

  local ok2 = tools.validate_batch({ { name = "done" }, { name = "read_file" } })
  t.assert_eq(ok2, false, "@done must be alone")
end)

t.run("Native schemas hide aliases and expose parameters", function()
  local schemas = tools.schemas()
  local names = {}
  for _, s in ipairs(schemas) do names[s["function"].name] = true end
  t.assert_true(names["read_file"] ~= nil, "read_file exposed")
  t.assert_true(names["view_image"] == nil, "alias hidden")
  t.assert_true(names["done"] ~= nil, "done exposed")

  local read = nil
  for _, s in ipairs(schemas) do
    if s["function"].name == "read_file" then read = s["function"] end
  end
  t.assert_true(read ~= nil, "read_file schema found")
  t.assert_true(read.parameters.required[1] == "path", "path is required")
  t.assert_eq(read.parameters.properties.path.type, "string", "path is a string")
end)

t.run("Heredoc body writes a file end to end", function()
  local parser = require("agentfile.parser")
  local text = table.concat({
    '@write_file({"path": "tests/scratch_heredoc.txt"}) <<\'EOF\'',
    'local x = "no escape"',
    'print(x)',
    'EOF',
  }, "\n")

  local calls = parser.extract_tool_calls(text)
  t.assert_eq(#calls, 1, "one heredoc call")
  t.assert_eq(calls[1].args.content, 'local x = "no escape"\nprint(x)', "verbatim content")

  tools.execute("write_file", calls[1].args, function(ok)
    t.assert_true(ok, "write_file via heredoc succeeded")
  end)
  t.assert_eq(vim.fn.readfile("tests/scratch_heredoc.txt"),
    { 'local x = "no escape"', "print(x)" }, "file content matches exactly")

  os.remove("tests/scratch_heredoc.txt")
end)
