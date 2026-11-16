local t = require("tests.minimal_init")
local parser = require("agentfile.parser")
local config = require("agentfile.agent_config")
local agentfile = require("agentfile")
local client = require("agentfile.client")
local tools = require("agentfile.tools")

t.run("Nested agent config and validation", function()
  local parsed = parser.parse_frontmatter({
    "---", "agent:", "  enabled: false", "  max_steps: 2",
    "max_tokens: 128", "skills: [read_file]", "---",
  })
  t.assert_eq(parsed.agent, { enabled = false, max_steps = 2 }, "nested mapping")
  t.assert_eq(parsed.max_tokens, 128, "root sibling stays at root")
  local resolved = config.resolve(parsed)
  t.assert_eq(resolved.enabled, false, "resolved enabled")
  t.assert_eq(resolved.max_steps, 2, "resolved step limit")
  t.assert_eq(resolved.max_format_errors, 3, "default format-error budget")
  t.assert_eq(resolved.wall_time_limit, 0, "no wall-time limit by default")
  t.assert_eq(resolved.retries, 2, "default retries")
  t.assert_eq(resolved.retry_delay_ms, 1000, "default retry delay")
  t.assert_eq(config.resolve({}).max_steps, 4, "small-model default")
  t.assert_eq(config.resolve({ max_iterations = 10 }).max_steps, 11, "legacy tool-round limit")
  for _, value in ipairs({ 0, -1, 1.5, "four", false }) do
    t.assert_eq(config.resolve({ agent = { max_steps = value } }), nil, "invalid step limit")
  end
  t.assert_eq(config.resolve({ agent = { max_format_errors = 0 } }).max_format_errors, 0,
    "zero format errors means no limit")
  t.assert_eq(config.resolve({ agent = { max_format_errors = -1 } }), nil,
    "negative format-error budget is invalid")
  t.assert_eq(config.resolve({ agent = { wall_time_limit = 30 } }).wall_time_limit, 30,
    "wall time limit accepted")
  t.assert_eq(config.resolve({ retries = 0 }).retries, 0, "retries can be disabled")
end)

t.run("Agent loop honors step budget and disabled mode", function()
  local original_stream, original_execute = client.stream_chat, tools.execute
  local requests, executions = 0, 0
  client.stream_chat = function(_, messages, callbacks)
    requests = requests + 1
    if requests == 2 then
      t.assert_true(messages[1].content:find("This is your FINAL step", 1, true) ~= nil,
        "last allowed request instructs the model to summarize")
    end
    callbacks.on_agent_chunk('@read_file({"path":"example.go"})')
    callbacks.on_complete()
  end
  tools.execute = function(_, _, callback)
    executions = executions + 1
    callback(true, "example contents")
  end
  local ok, err = pcall(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "---", "agent:", "  max_steps: 2", "---", "[me]", "read the file",
    })
    agentfile.send(buf)
    t.assert_true(vim.wait(1000, function()
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("Reached agent.max_steps", 1, true) ~= nil
    end), "loop reports budget exhaustion in buffer")
    t.assert_eq(requests, 2, "only two model requests")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "---", "agent:", "  enabled: false", "---", "[me]", "plain chat",
    })
    local before = executions
    agentfile.send(buf)
    t.assert_eq(requests, 3, "new user request still works")
    t.assert_eq(executions, before, "disabled agent does not execute model tools")
  end)
  client.stream_chat, tools.execute = original_stream, original_execute
  if not ok then error(err) end
end)

t.run("Tool batches finish before the next model turn, including approval", function()
  local original_stream, original_execute = client.stream_chat, tools.execute
  local original_select = vim.ui.select
  local answer
  vim.ui.select = function(_, opts, callback)
    t.assert_true(opts.prompt:find("b.go", 1, true) ~= nil, "Neovim prompt identifies target")
    answer = callback
  end
  local requests, executed, second_payload = 0, {}, nil
  tools.execute = function(name, args, callback)
    executed[#executed + 1] = name .. ":" .. args.path
    callback(true, "contents of " .. args.path)
  end
  client.stream_chat = function(_, messages, callbacks)
    requests = requests + 1
    if requests == 1 then
      callbacks.on_agent_chunk(table.concat({
        '@read_file({"path":"a.go"})',
        '@write_file({"path":"b.go","content":"example"})',
        '@read_file({"path":"c.go"})',
      }, "\n"))
    else
      second_payload = vim.inspect(messages)
      callbacks.on_agent_chunk("Done reading the results.")
    end
    callbacks.on_complete()
  end
  local ok, err = pcall(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "---", "agent:", "  max_steps: 2", "---", "[me]", "test a batch",
    })
    agentfile.send(buf)
    t.assert_true(vim.wait(1000, function()
      return answer ~= nil
    end), "batch pauses for approval")
    t.assert_eq(executed, { "read_file:a.go" }, "later calls wait for approval")
    t.assert_eq(requests, 1, "no model request between tools")
    t.assert_true(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("[ask]", 1, true) == nil,
      "approval does not add an ask block")
    answer("Allow")
    t.assert_true(vim.wait(1000, function() return requests == 2 end), "model continues after batch")
    t.assert_eq(executed, { "read_file:a.go", "write_file:b.go", "read_file:c.go" }, "all tools execute in order")
    for _, path in ipairs({ "a.go", "b.go", "c.go" }) do
      t.assert_true(second_payload:find("contents of " .. path, 1, true) ~= nil, "model receives result for " .. path)
    end
  end)
  client.stream_chat, tools.execute = original_stream, original_execute
  vim.ui.select = original_select
  if not ok then error(err) end
end)

t.run("Dismissing the Neovim approval prompt rejects without execution", function()
  local original_select, original_execute = vim.ui.select, tools.execute
  local executions, answer = 0, nil
  vim.ui.select = function(_, _, callback) answer = callback end
  tools.execute = function() executions = executions + 1 end
  local ok, err = pcall(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "[agent]", '@write_file({"path":"example.go","content":"x"})' })
    agentfile.handle_tool_calls(buf, {
      { name = "write_file", args = { path = "example.go", content = "x" } },
      { name = "read_file", args = { path = "other.go" } },
    }, {})
    t.assert_true(vim.wait(1000, function() return answer ~= nil end), "opens Neovim prompt")
    answer(nil)
    t.assert_eq(executions, 0, "dismissal executes no tools")
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    t.assert_true(text:find("status=rejected", 1, true) ~= nil, "records rejected result")
    t.assert_eq(require("agentfile.state").get(buf).status, "idle", "batch stops")
    answer("Allow")
    t.assert_eq(executions, 0, "stale prompt callback cannot execute a tool")
  end)
  vim.ui.select, tools.execute = original_select, original_execute
  if not ok then error(err) end
end)
