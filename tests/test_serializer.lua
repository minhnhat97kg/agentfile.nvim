-- tests/test_serializer.lua
local t = require("tests.minimal_init")
local serializer = require("agentfile.serializer")

t.run("Serialize Messages (Strip [think])", function()
  local blocks = {
    {
      role = "system",
      content = "You are a coding assistant."
    },
    {
      role = "user",
      content = "Please examine main.rs"
    },
    {
      role = "think",
      content = "I should read the file first to know what is inside."
    },
    {
      role = "agent",
      content = "I will read the file:\n@read_file({\"path\": \"src/main.rs\"})"
    },
    {
      role = "result",
      id = 1,
      status = "ok",
      content = "fn main() { println!(\"hello\"); }"
    }
  }

  local tools_prompt = "AVAILABLE TOOLS:\n- read_file(path): Read file contents"
  local messages = serializer.serialize_messages(blocks, tools_prompt)

  -- Expect 4 messages: system (with tools_prompt appended), user, assistant, user (from [result])
  -- [think] MUST BE STRIPPED
  t.assert_eq(#messages, 4, "total messages serialized is 4 (no think block)")

  t.assert_eq(messages[1].role, "system", "message 1 is system")
  t.assert_true(messages[1].content:find("You are a coding assistant.") ~= nil, "message 1 contains original system content")
  t.assert_true(messages[1].content:find("AVAILABLE TOOLS:") ~= nil, "message 1 contains injected tools prompt")

  t.assert_eq(messages[2].role, "user", "message 2 is user")
  t.assert_eq(messages[2].content, "Please examine main.rs", "message 2 content")

  t.assert_eq(messages[3].role, "assistant", "message 3 is assistant")
  t.assert_eq(messages[3].content, "I will read the file:\n@read_file({\"path\": \"src/main.rs\"})", "message 3 content")

  t.assert_eq(messages[4].role, "user", "message 4 is user (result mapped to user context)")
  t.assert_true(messages[4].content:find("[result id=1 status=ok]") ~= nil, "message 4 contains formatted result header")
  t.assert_true(messages[4].content:find("fn main()") ~= nil, "message 4 contains result payload")
end)

t.run("Compute Turn Hash", function()
  local messages_a = {
    { role = "system", content = "System prompt" },
    { role = "user", content = "Hello" }
  }

  local messages_b = {
    { role = "system", content = "System prompt" },
    { role = "user", content = "Hello" }
  }

  local messages_c = {
    { role = "system", content = "System prompt" },
    { role = "user", content = "Hello there" }
  }

  local hash_a = serializer.compute_turn_hash(messages_a)
  local hash_b = serializer.compute_turn_hash(messages_b)
  local hash_c = serializer.compute_turn_hash(messages_c)

  t.assert_eq(hash_a, hash_b, "identical messages produce identical hash")
  t.assert_true(hash_a ~= hash_c, "different messages produce different hash")
end)

t.run("Failed think is replayed only when explicitly enabled", function()
  local blocks = {
    { role = "system", content = "system prompt" },
    { role = "user", content = "fix it" },
    { role = "think", content = "I will edit the wrong file" },
    { role = "agent", content = '@edit_file({"path":"a.go","target":"x","replacement":"y"})' },
    { role = "result", id = 1, status = "error", content = "target not found" },
    { role = "agent", content = "Let me retry." },
    { role = "result", id = 2, status = "ok", content = "done" },
  }

  local stripped = serializer.serialize_messages(blocks)
  for _, msg in ipairs(stripped) do
    t.assert_true(not msg.content:find("wrong file", 1, true), "think is stripped by default")
  end

  local replay = serializer.serialize_messages(blocks, nil, nil, { keep_think_on_error = true })
  local assistant = nil
  for _, msg in ipairs(replay) do
    if msg.role == "assistant" and msg.content:find("@edit_file", 1, true) then
      assistant = msg
    end
  end
  t.assert_true(assistant ~= nil, "failed assistant turn found")
  t.assert_true(assistant.content:find("wrong file", 1, true) ~= nil, "failed think replayed once")
  t.assert_true(assistant.content:find("[think]", 1, true) ~= nil, "think is labelled")

  -- The successful turn after the error is not annotated.
  for _, msg in ipairs(replay) do
    if msg.role == "assistant" and msg.content:find("Let me retry", 1, true) then
      t.assert_true(not msg.content:find("[think]", 1, true), "successful turn stays clean")
    end
  end
end)
