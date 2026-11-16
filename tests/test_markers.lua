-- tests/test_markers.lua
local t = require("tests.minimal_init")
local markers = require("agentfile.markers")
local parser = require("agentfile.parser")
local serializer = require("agentfile.serializer")

t.run("Default markers", function()
  t.assert_eq(markers.kind_of("[system]"), "system", "detects [system]")
  t.assert_eq(markers.kind_of("[me]"), "me", "detects [me]")
  t.assert_eq(markers.kind_of("[agent]"), "agent", "detects [agent]")
  t.assert_eq(markers.kind_of("[think]"), "think", "detects [think]")
  t.assert_eq(markers.kind_of("[reset]"), "reset", "detects [reset]")
  t.assert_eq(markers.kind_of("[error]"), "error", "detects [error]")

  local kind, extra = markers.kind_of("[result id=7 status=ok]")
  t.assert_eq(kind, "result", "detects result marker")
  local id, status = markers.parse_result_attrs(extra)
  t.assert_eq(id, 7, "parses result id")
  t.assert_eq(status, "ok", "parses result status")

  t.assert_eq(markers.format("me"), "[me]", "formats me marker")
  t.assert_eq(
    markers.format("result", { id = 7, status = "ok" }),
    "[result id=7 status=ok]",
    "formats result marker with attributes"
  )
end)

t.run("Legacy markers are still accepted", function()
  t.assert_eq(markers.kind_of(">>me"), "me", "detects legacy >>me")
  t.assert_eq(markers.kind_of(">>agent"), "agent", "detects legacy >>agent")
  t.assert_eq(markers.kind_of("#think"), "think", "detects legacy #think")
  t.assert_eq(markers.kind_of("[result id=1 status=pending]"), "result", "detects legacy result")
end)

t.run("Ask marker", function()
  local kind, extra = markers.kind_of("[ask] Allow @write_file? (y/N): y")
  t.assert_eq(kind, "ask", "detects ask marker")
  t.assert_eq(extra, "Allow @write_file? (y/N): y", "ask text is kept")

  t.assert_eq(
    markers.format("ask", "Allow? (y/N): "),
    "[ask] Allow? (y/N): ",
    "formats ask marker with question"
  )
  t.assert_eq(
    markers.format("ask", "100% sure? (y/N): "),
    "[ask] 100% sure? (y/N): ",
    "percent in question is not treated as a pattern"
  )

  local blocks = parser.parse_blocks({
    "[ask] Allow? (y/N): ",
    '@write_file({"path": "a.txt"})',
    "",
  })
  t.assert_eq(#blocks, 1, "ask block parsed")
  t.assert_eq(blocks[1].role, "ask", "ask role")
  t.assert_eq(blocks[1].ask_text, "Allow? (y/N):", "ask text stored")
  t.assert_eq(blocks[1].content, '@write_file({"path": "a.txt"})', "ask body stored")

  local messages = serializer.serialize_messages(blocks)
  t.assert_eq(#messages, 0, "ask block is never sent to the model")
end)

t.run("Context size suffix", function()
  t.assert_eq(
    markers.kind_of("[me](context 1234/8192)"),
    "me",
    "context suffix does not hide the me marker"
  )
  t.assert_eq(
    markers.kind_of("[me][context 1234/8192]"),
    "me",
    "legacy bracket context suffix is still accepted"
  )

  local blocks = parser.parse_blocks({
    "[me](context 12/100)",
    "hello",
  })
  t.assert_eq(blocks[1].role, "user", "me block parsed with context suffix")
  t.assert_eq(blocks[1].content, "hello", "context suffix is not part of content")

  markers.setup({ me = "USER:" })
  t.assert_eq(markers.kind_of("USER:(context 3/4)"), "me", "custom me marker with suffix")
  markers.reset()
end)

t.run("Custom markers", function()
  markers.setup({
    system = "SYSTEM:",
    me = "USER:",
    think = "THOUGHTS:",
    agent = "ASSISTANT:",
    result = "<<result%s>>",
    reset = "RESET",
    error = "ERROR:",
  })

  t.assert_eq(markers.kind_of("USER:"), "me", "detects custom me marker")
  t.assert_eq(markers.kind_of("ASSISTANT:"), "agent", "detects custom agent marker")
  t.assert_eq(markers.kind_of("ERROR:"), "error", "detects custom error marker")

  local kind, extra = markers.kind_of("<<result id=2 status=error>>")
  t.assert_eq(kind, "result", "detects custom result marker")
  local id, status = markers.parse_result_attrs(extra)
  t.assert_eq(id, 2, "parses custom result id")
  t.assert_eq(status, "error", "parses custom result status")

  t.assert_eq(
    markers.format("result", { id = 2, status = "error" }),
    "<<result id=2 status=error>>",
    "formats custom result marker"
  )

  -- Old buffers keep working after switching styles.
  t.assert_eq(markers.kind_of("[me]"), "me", "legacy [me] still accepted")

  local blocks = parser.parse_blocks({
    "SYSTEM:",
    "You are helpful.",
    "",
    "USER:",
    "hello",
    "ASSISTANT:",
    "hi",
    "<<result id=2 status=ok>>",
    "data",
  })
  t.assert_eq(#blocks, 4, "custom markers produce four blocks")
  t.assert_eq(blocks[1].role, "system", "first block is system")
  t.assert_eq(blocks[2].role, "user", "second block is user")
  t.assert_eq(blocks[3].role, "agent", "third block is agent")
  t.assert_eq(blocks[4].role, "result", "fourth block is result")
  t.assert_eq(blocks[4].id, 2, "custom result keeps id")

  markers.reset()
  t.assert_eq(markers.get("me"), "[me]", "reset restores defaults")
end)

t.run("Error blocks never reach the model", function()
  local blocks = {
    { role = "system", content = "system prompt" },
    { role = "error", content = "connection refused" },
    { role = "user", content = "hello" },
    { role = "agent", content = "hi" },
  }
  local messages = serializer.serialize_messages(blocks)
  t.assert_eq(#messages, 3, "error block is dropped from payload")
  t.assert_eq(messages[1].role, "system", "system message kept")
  t.assert_eq(messages[2].role, "user", "user message kept")
  t.assert_eq(messages[3].role, "assistant", "assistant message kept")
end)
