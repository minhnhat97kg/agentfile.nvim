-- tests/test_integration.lua
local t = require("tests.minimal_init")
local agentfile = require("agentfile")
local state = require("agentfile.state")
local parser = require("agentfile.parser")

t.run("End-to-End Orchestrator Simulation", function()
  -- Create a scratch buffer in neovim
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)

  local initial_lines = {
    "---",
    "host: https://api.openai.com/v1",
    "model: gpt-4o",
    "token: test_token",
    "auto_run_tools: false",
    "---",
    "",
    "[system]",
    "You are a test assistant.",
    "",
    "[me]",
    "Please run a command!"
  }
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, initial_lines)

  -- Check turn detection
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local should_send, reason = state.should_trigger_send(bufnr, lines)
  t.assert_true(should_send, "new buffer with [me] triggers send")

  -- Test tool approval flow simulation
  state.get(bufnr).pending_tool = {
    id = 1,
    call = { name = "read_file", args = { path = "tests/minimal_init.lua" } },
    config = {}
  }
  state.transition(bufnr, "awaiting_approval")

  -- Append pending result line to buffer
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
    "",
    "[result id=1 status=pending]",
    "Tool @read_file is waiting for confirmation."
  })

  -- Call approve_tool
  agentfile.approve_tool(bufnr)

  -- Verify state after approve
  local updated_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local found_ok = false
  for _, l in ipairs(updated_lines) do
    if l:find("%[result id=1 status=ok%]") then
      found_ok = true
      break
    end
  end
  t.assert_true(found_ok, "result block updated to status=ok upon approval")
end)

local function message_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

t.run("Answer [ask] with y approves the tool", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "[system]",
    "test",
    "",
    "[me]",
    "read the test file",
    "",
    "[agent]",
    '@read_file({"path": "tests/minimal_init.lua"})',
    "",
    "[ask] Allow @read_file on `tests/minimal_init.lua`? (y/N): y",
    '@read_file({"path": "tests/minimal_init.lua"})',
    "",
  })

  state.get(bufnr).pending_tool = {
    id = 1,
    call = { name = "read_file", args = { path = "tests/minimal_init.lua" } },
    config = {},
  }
  state.transition(bufnr, "awaiting_approval")

  local original_send = agentfile.send
  agentfile.send = function() end
  local ok, err = pcall(agentfile.on_save, bufnr)
  vim.wait(50, function() return false end)
  agentfile.send = original_send

  t.assert_true(ok, "on_save succeeded: " .. tostring(err))
  local text = message_text(bufnr)
  t.assert_true(text:find("%[result id=1 status=ok%]") ~= nil, "ask becomes result ok")
  t.assert_true(text:find("%[ask%]") == nil, "ask block removed")
end)

t.run("Answer [ask] with n rejects the tool", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "[me]",
    "write a file",
    "",
    "[agent]",
    '@write_file({"path": "a.txt", "content": "x"})',
    "",
    "[ask] Allow @write_file on `a.txt`? (y/N): n",
    '@write_file({"path": "a.txt", "content": "x"})',
    "",
  })

  state.get(bufnr).pending_tool = {
    id = 2,
    call = { name = "write_file", args = { path = "a.txt", content = "x" } },
    config = {},
  }
  state.transition(bufnr, "awaiting_approval")

  agentfile.on_save(bufnr)

  local text = message_text(bufnr)
  t.assert_true(text:find("%[result id=2 status=rejected%]") ~= nil, "ask becomes result rejected")
  t.assert_true(text:find("%[ask%]") == nil, "ask block removed after reject")
  t.assert_true(text:find("%[me%]") ~= nil, "fresh me block after reject")
end)

t.run("Answer [ask] with n and feedback note", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "[me]",
    "write a file",
    "",
    "[agent]",
    '@write_file({"path": "a.txt", "content": "x"})',
    "",
    "[ask] Allow @write_file on `a.txt`? (y/N): n: don't write a.txt, write b.txt instead",
    '@write_file({"path": "a.txt", "content": "x"})',
    "",
  })

  state.get(bufnr).pending_tool = {
    id = 3,
    call = { name = "write_file", args = { path = "a.txt", content = "x" } },
    config = {},
  }
  state.transition(bufnr, "awaiting_approval")

  agentfile.on_save(bufnr)

  local text = message_text(bufnr)
  t.assert_true(text:find("%[result id=3 status=rejected%]") ~= nil, "ask becomes result rejected")
  t.assert_true(text:find("don't write a%.txt, write b%.txt instead") ~= nil, "rejection reason included in result")
  t.assert_true(text:find("%[ask%]") == nil, "ask block removed after reject")
  t.assert_true(text:find("%[me%]") ~= nil, "fresh me block after reject")
end)

t.run("Context meter is written to the latest [me] line", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "---",
    "context_window: 1000",
    "---",
    "",
    "[system]",
    "test",
    "",
    "[me]",
    "hello",
  })

  local config = select(1, parser.parse_frontmatter(
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  ))
  agentfile.update_context_marker(bufnr, config)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local marker = nil
  for _, line in ipairs(lines) do
    if line:match("^%[me%]%(context %d+/1000%)$") then
      marker = line
    end
  end
  t.assert_true(marker ~= nil, "me line contains (context used/1000)")

  local blocks = parser.parse_blocks(lines, 3)
  local me = nil
  for _, block in ipairs(blocks) do
    if block.role == "user" then
      me = block
    end
  end
  t.assert_eq(me.content, "hello", "context suffix is not part of the message")
end)

t.run("Stale [ask] is replaced with an error", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "[me]",
    "write a file",
    "",
    "[ask] Allow @write_file on `a.txt`? (y/N): y",
    '@write_file({"path": "a.txt", "content": "x"})',
    "",
  })

  -- No pending_tool: simulates a Neovim restart.
  agentfile.on_save(bufnr)

  local text = message_text(bufnr)
  t.assert_true(text:find("%[error%]") ~= nil, "stale ask becomes an error block")
  t.assert_true(text:find("%[ask%]") == nil, "stale ask removed")
  t.assert_true(text:find("%[me%]") ~= nil, "fresh me block after stale ask")
end)

t.run("@done ends the loop explicitly", function()
  local client = require("agentfile.client")
  local stream = client.stream_chat
  local requests = 0
  client.stream_chat = function(_, _, callbacks)
    requests = requests + 1
    callbacks.on_agent_chunk('@done({"summary":"fixed"})')
    callbacks.on_complete({ finish_reason = "stop" })
  end

  local ok, err = pcall(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "---", "agent:", "  max_steps: 4", "---", "[me]", "fix it",
    })
    agentfile.send(buf)
    t.assert_true(vim.wait(1000, function()
      return message_text(buf):find("[done]", 1, true) ~= nil
    end), "done block written")

    t.assert_eq(requests, 1, "no second model request after @done")
    t.assert_eq(state.get(buf).exit_status, "submitted", "exit status recorded")
    local text = message_text(buf)
    t.assert_true(text:find("%[result id=1 status=ok%]") ~= nil, "completion result written")
    t.assert_true(text:find("[done]", 1, true) ~= nil, "done block present")
    t.assert_true(text:find("step 1/4", 1, true) ~= nil, "context meter shows the step")
  end)
  client.stream_chat = stream
  if not ok then error(err) end
end)

t.run("Truncated response retries instead of ending", function()
  local client = require("agentfile.client")
  local stream = client.stream_chat
  local requests = 0
  local second_system
  client.stream_chat = function(_, messages, callbacks)
    requests = requests + 1
    if requests == 1 then
      callbacks.on_agent_chunk('partial @read_file({"path')
      callbacks.on_complete({ finish_reason = "length" })
    else
      second_system = messages[1].content
      callbacks.on_agent_chunk("done now")
      callbacks.on_complete({ finish_reason = "stop" })
    end
  end

  local ok, err = pcall(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "---", "agent:", "  max_steps: 4", "  max_format_errors: 3", "---", "[me]", "read it",
    })
    agentfile.send(buf)
    t.assert_true(vim.wait(1000, function() return requests == 2 end), "retried once")
    t.assert_true(second_system:find("was invalid", 1, true) ~= nil, "corrective nudge injected")
    t.assert_true(second_system:find("finish_reason=length", 1, true) ~= nil, "reason mentioned")
    t.assert_true(message_text(buf):find("[me]", 1, true) ~= nil, "final answer opened a new turn")
  end)
  client.stream_chat = stream
  if not ok then error(err) end
end)

t.run("Repeated invalid responses stop the loop", function()
  local client = require("agentfile.client")
  local stream = client.stream_chat
  local requests = 0
  client.stream_chat = function(_, _, callbacks)
    requests = requests + 1
    callbacks.on_agent_chunk("cut off again")
    callbacks.on_complete({ finish_reason = "length" })
  end

  local ok, err = pcall(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "---", "agent:", "  max_steps: 8", "  max_format_errors: 2", "---", "[me]", "go",
    })
    agentfile.send(buf)
    t.assert_true(vim.wait(1000, function()
      return message_text(buf):find("Repeated invalid responses", 1, true) ~= nil
    end), "gives up after the budget")
    t.assert_eq(requests, 2, "bounded by max_format_errors")
    t.assert_eq(state.get(buf).exit_status, "format_error", "exit status recorded")
    t.assert_true(message_text(buf):find("[error]", 1, true) ~= nil, "error block shown")
  end)
  client.stream_chat = stream
  if not ok then error(err) end
end)

t.run("Multiple mutating tools in one turn are rejected", function()
  local client = require("agentfile.client")
  local tools = require("agentfile.tools")
  local stream, execute = client.stream_chat, tools.execute
  local requests, executions = 0, 0
  tools.execute = function() executions = executions + 1 end
  client.stream_chat = function(_, messages, callbacks)
    requests = requests + 1
    if requests == 1 then
      callbacks.on_agent_chunk(table.concat({
        '@write_file({"path":"a.go","content":"x"})',
        '@edit_file({"path":"b.go","target":"y","replacement":"z"})',
      }, "\n"))
    else
      callbacks.on_agent_chunk("ok, split them")
    end
    callbacks.on_complete({ finish_reason = "stop" })
  end

  local ok, err = pcall(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "---", "agent:", "  max_steps: 4", "---", "[me]", "edit two files",
    })
    agentfile.send(buf)
    t.assert_true(vim.wait(1000, function() return requests == 2 end), "asks the model to split the batch")
    t.assert_eq(executions, 0, "no mutating tool ran")
  end)
  client.stream_chat, tools.execute = stream, execute
  if not ok then error(err) end
end)
