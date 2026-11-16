-- tests/test_memory.lua
local t = require("tests.minimal_init")
local memory = require("agentfile.memory")

local function temp_memory(extra)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local config = {
    memory = vim.tbl_extend("force", {
      enabled = true,
      path = dir .. "/memory.md",
      max_chars = 400,
      require_approval = false,
    }, extra or {}),
  }
  return memory.resolve(config), dir
end

t.run("Memory is disabled by default", function()
  local opts = memory.resolve({})
  t.assert_eq(opts.enabled, false, "opt-in")
  t.assert_eq(opts.path, ".agentfile/memory.md", "default path")
  t.assert_eq(opts.require_approval, true, "writes need approval by default")
  t.assert_eq(memory.prompt_text({}), "", "no prompt block when disabled")
end)

t.run("Lessons are added, deduplicated and capped", function()
  local opts, dir = temp_memory()

  local added, path = memory.add_lesson(opts, {
    tool = "edit_file",
    text = "target must be unique; use write_file when it appears twice",
    source = "user_rejection",
    date = "2026-11-15",
  })
  t.assert_eq(added, true, "lesson added")
  t.assert_eq(path, opts.path, "returns memory path")
  t.assert_true(vim.fn.filereadable(opts.path) == 1, "file created")

  local duplicate = memory.add_lesson(opts, {
    tool = "edit_file",
    text = "target must be unique; use write_file when it appears twice",
    source = "user_rejection",
    date = "2026-11-15",
  })
  t.assert_eq(duplicate, false, "duplicate rejected")
  t.assert_eq(#memory.load(opts), 1, "only one lesson stored")

  for i = 1, 12 do
    memory.add_lesson(opts, {
      tool = "tool" .. i,
      text = "lesson " .. i .. " " .. string.rep("x", 60),
      source = "repeated_failure",
      date = "2026-11-15",
    })
  end

  local lessons = memory.load(opts)
  local total = 0
  for _, line in ipairs(lessons) do total = total + #line + 1 end
  t.assert_true(total <= opts.max_chars, "stored lessons respect max_chars")
  t.assert_true(lessons[#lessons]:find("lesson 12", 1, true) ~= nil, "newest lesson kept")
  t.assert_true(lessons[1]:find("lesson 1 ", 1, true) == nil, "oldest lessons dropped")

  vim.fn.delete(dir, "rf")
end)

t.run("System prompt block is bounded and explicit", function()
  local opts, dir = temp_memory()
  memory.add_lesson(opts, { tool = "run_command", text = "use go test ./...", date = "2026-11-15" })
  local prompt = memory.prompt_text({
    memory = { enabled = true, path = opts.path, max_chars = opts.max_chars },
  })
  t.assert_true(prompt:find("PROJECT MEMORY", 1, true) ~= nil, "header")
  t.assert_true(prompt:find("do not repeat", 1, true) ~= nil, "instruction")
  t.assert_true(prompt:find("[run_command]", 1, true) ~= nil, "tool tag")
  vim.fn.delete(dir, "rf")
end)

t.run("Failure signatures collapse paths and numbers", function()
  local a = memory.signature("read_file", "Error: could not open file src/a.go: No such file")
  local b = memory.signature("read_file", "Error: could not open file src/b.go: No such file")
  t.assert_eq(a, b, "same root cause yields the same signature")
  t.assert_true(a:find("<path>", 1, true) ~= nil, "paths normalized")
end)

t.run("Lesson text is single-line and length-limited", function()
  local opts, dir = temp_memory()
  local long = "line one\nline two\n" .. string.rep("y", 500)
  memory.add_lesson(opts, { tool = "write_file", text = long, date = "2026-11-15" })
  local lessons = memory.load(opts)
  t.assert_eq(#lessons, 1, "one line")
  t.assert_true(#lessons[1] <= 260, "lesson length capped")
  t.assert_true(lessons[1]:find("\n") == nil, "newlines removed")
  vim.fn.delete(dir, "rf")
end)
