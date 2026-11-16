-- tests/test_trajectory.lua
local t = require("tests.minimal_init")
local trajectory = require("agentfile.trajectory")

local blocks = {
  { role = "system", content = "system prompt" },
  { role = "user", content = "hi" },
  { role = "think", content = "private reasoning" },
  { role = "agent", content = "hello" },
  { role = "result", id = 1, status = "ok", content = "tool output" },
}

t.run("Trajectory mirrors the model payload", function()
  local data = trajectory.build(blocks, {
    config = { model = "example-model", host = "http://localhost" },
    agent = { enabled = true, max_steps = 4 },
    steps = 2,
    usage = { prompt_tokens = 100, completion_tokens = 20 },
    exit_status = "completed",
  })

  t.assert_eq(data.info.trajectory_format, "agentfile-1.0", "format tag")
  t.assert_eq(data.info.model, "example-model", "model recorded")
  t.assert_eq(data.info.steps, 2, "steps recorded")
  t.assert_eq(data.info.exit_status, "completed", "exit status recorded")
  t.assert_eq(#data.messages, 4, "think block is stripped like the real payload")
  t.assert_eq(data.messages[1].role, "system", "system first")
  t.assert_eq(data.messages[3].content, "hello", "assistant text preserved")
  t.assert_eq(data.messages[4].content, "[result id=1 status=ok]\ntool output", "result envelope preserved")
end)

t.run("Export writes valid JSON", function()
  local path = vim.fn.tempname() .. "/trajectory.json"
  local ok, written = trajectory.export(blocks, path, { config = { model = "m" }, steps = 1 })
  t.assert_eq(ok, true, "export succeeded")
  t.assert_eq(written, path, "path returned")
  t.assert_true(vim.fn.filereadable(path) == 1, "file exists")

  local raw = table.concat(vim.fn.readfile(path), "\n")
  local decoded = vim.json.decode(raw)
  t.assert_eq(decoded.info.model, "m", "JSON round trip")
  t.assert_eq(#decoded.messages, 4, "messages exported")
  vim.fn.delete(vim.fn.fnamemodify(path, ":h"), "rf")
end)
