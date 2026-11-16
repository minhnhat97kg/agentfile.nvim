-- tests/test_client.lua
local t = require("tests.minimal_init")
local client = require("agentfile.client")

t.run("Request headers", function()
  local headers = client.build_headers({
    token = "test-token",
    session = "agentfile-session-1",
  })
  local text = table.concat(headers, "\n")
  t.assert_true(text:find("Authorization: Bearer test%-token") ~= nil, "adds auth header")
  t.assert_true(text:find("x%-opencode%-session: agentfile%-session%-1") ~= nil, "adds session header")
  t.assert_true(text:find("User%-Agent: agentfile%.nvim") ~= nil, "adds user agent")

  local no_session = table.concat(client.build_headers({}), "\n")
  t.assert_true(no_session:find("x%-opencode%-session") == nil, "session header is optional")
end)

t.run("SSE Chunk Parsing with reasoning_content", function()
  local parser_state = client.new_stream_parser()

  local chunks = {
    "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"I should \"}}]}\n\n",
    "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think first.\"}}]}\n\n",
    "data: {\"choices\":[{\"delta\":{\"content\":\"Hello \"}}]}\n\n",
    "data: {\"choices\":[{\"delta\":{\"content\":\"world!\"}}]}\n\n",
    "data: [DONE]\n\n"
  }

  local think_acc = ""
  local agent_acc = ""

  for _, chunk in ipairs(chunks) do
    parser_state:feed(chunk, {
      on_think_chunk = function(str) think_acc = think_acc .. str end,
      on_agent_chunk = function(str) agent_acc = agent_acc .. str end,
    })
  end

  t.assert_eq(think_acc, "I should think first.", "accumulated think from reasoning_content")
  t.assert_eq(agent_acc, "Hello world!", "accumulated agent from content")
end)

t.run("SSE Chunk Parsing with inline <think> tags", function()
  local parser_state = client.new_stream_parser()

  local chunks = {
    "data: {\"choices\":[{\"delta\":{\"content\":\"<think>Let me \"}}]}\n\n",
    "data: {\"choices\":[{\"delta\":{\"content\":\"ponder this.</think>Done!\"}}]}\n\n"
  }

  local think_acc = ""
  local agent_acc = ""

  for _, chunk in ipairs(chunks) do
    parser_state:feed(chunk, {
      on_think_chunk = function(str) think_acc = think_acc .. str end,
      on_agent_chunk = function(str) agent_acc = agent_acc .. str end,
    })
  end

  t.assert_eq(think_acc, "Let me ponder this.", "accumulated think from inline tag")
  t.assert_eq(agent_acc, "Done!", "accumulated agent after closing think tag")
end)

t.run("SSE Chunk Parsing with null content and reasoning (userdata values)", function()
  local parser_state = client.new_stream_parser()

  -- OpenAI / OpenRouter often send null in initial chunks or role-only chunks
  local chunks = {
    "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":null,\"reasoning_content\":null}}]}\n\n",
    "data: {\"choices\":[{\"delta\":{\"content\":\"Hello world\"}}]}\n\n",
    "data: {\"choices\":[{\"delta\":{\"content\":null}}]}\n\n",
    "data: [DONE]\n\n"
  }

  local think_acc = ""
  local agent_acc = ""
  local error_called = false

  for _, chunk in ipairs(chunks) do
    parser_state:feed(chunk, {
      on_think_chunk = function(str) think_acc = think_acc .. str end,
      on_agent_chunk = function(str) agent_acc = agent_acc .. str end,
      on_error = function() error_called = true end,
    })
  end

  t.assert_eq(error_called, false, "no error triggered by null content")
  t.assert_eq(think_acc, "", "no think accumulated for null reasoning")
  t.assert_eq(agent_acc, "Hello world", "correctly accumulated text ignoring null chunks")
end)

t.run("build_payload with sampling and thinking parameters", function()
  local msgs = { { role = "user", content = "hi" } }

  -- 1. Standard sampling options
  local p1 = client.build_payload({
    model = "deepseek-r1:7b",
    temperature = 0.6,
    top_p = 0.95,
    presence_penalty = 0.2,
    frequency_penalty = 0.3,
    max_tokens = 2048,
    stop = { "</think>" },
  }, msgs)

  t.assert_eq(p1.model, "deepseek-r1:7b", "sets model")
  t.assert_eq(p1.temperature, 0.6, "sets temperature")
  t.assert_eq(p1.top_p, 0.95, "sets top_p")
  t.assert_eq(p1.presence_penalty, 0.2, "sets presence_penalty")
  t.assert_eq(p1.frequency_penalty, 0.3, "sets frequency_penalty")
  t.assert_eq(p1.max_tokens, 2048, "sets max_tokens")
  t.assert_eq(p1.stop, { "</think>" }, "sets stop sequence")

  -- 2. Thinking budget (Anthropic & OpenRouter format)
  local p2 = client.build_payload({
    thinking = {
      budget_tokens = 1024,
      effort = "low",
    },
  }, msgs)

  t.assert_eq(p2.thinking, { type = "enabled", budget_tokens = 1024 }, "sets anthropic thinking budget")
  t.assert_eq(p2.reasoning.max_tokens, 1024, "sets openrouter reasoning max_tokens")
  t.assert_eq(p2.reasoning.effort, "low", "sets openrouter reasoning effort")
  t.assert_eq(p2.reasoning_effort, "low", "sets openai reasoning_effort")

  -- 3. Thinking disabled
  local p3 = client.build_payload({
    thinking = false,
  }, msgs)

  t.assert_eq(p3.thinking, { type = "disabled" }, "disables anthropic thinking")
  t.assert_eq(p3.include_reasoning, false, "sets openrouter include_reasoning = false")
end)

t.run("Stream parses finish_reason, usage and native tool calls", function()
  local ps = client.new_stream_parser()
  local usage, finish
  local chunks = {
    'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\\"path\\":"}}]}}]}\n\n',
    'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"a.go\\"}"}}]}}]}\n\n',
    'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":12,"completion_tokens":3}}\n\n',
    "data: [DONE]\n\n",
  }
  for _, chunk in ipairs(chunks) do
    ps:feed(chunk, {
      on_usage = function(u) usage = u end,
    })
  end

  t.assert_eq(ps.finish_reason, "tool_calls", "finish reason captured")
  t.assert_eq(usage.prompt_tokens, 12, "usage captured")
  t.assert_eq(ps.tool_calls[1].id, "call_1", "tool call id captured")
  t.assert_eq(ps.tool_calls[1]["function"].name, "read_file", "tool name accumulated")
  t.assert_eq(ps.tool_calls[1]["function"].arguments, '{"path":"a.go"}', "arguments accumulated across chunks")
end)

t.run("Payload usage request is opt-in", function()
  local msgs = { { role = "user", content = "hi" } }
  local payload = client.build_payload({
    tools = { { type = "function", ["function"] = { name = "read_file" } } },
    tool_choice = "auto",
  }, msgs)

  t.assert_eq(payload.stream_options, nil, "usage request is off by default")
  t.assert_eq(#payload.tools, 1, "tools forwarded")
  t.assert_eq(payload.tool_choice, "auto", "tool choice forwarded")

  local with = client.build_payload({ include_usage = true }, msgs)
  t.assert_eq(with.stream_options, { include_usage = true }, "usage requested when opted in")
end)

t.run("Retry classification", function()
  local retryable, reason = client.classify_retry(429, nil)
  t.assert_eq(retryable, true, "429 retries")
  t.assert_true(reason:find("429", 1, true) ~= nil, "reason mentions status")

  t.assert_eq(client.classify_retry(503, nil), true, "503 retries")
  t.assert_eq(client.classify_retry(500, nil), true, "500 retries")
  t.assert_eq(client.classify_retry(401, nil), false, "401 does not retry")
  t.assert_eq(client.classify_retry(404, nil), false, "404 does not retry")
  t.assert_eq(client.classify_retry(nil, 28), true, "timeout retries")
  t.assert_eq(client.classify_retry(nil, 60), false, "TLS failure does not retry")
end)
