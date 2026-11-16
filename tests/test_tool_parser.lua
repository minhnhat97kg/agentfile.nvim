-- tests/test_tool_parser.lua
local t = require("tests.minimal_init")
local parser = require("agentfile.parser")

t.run("Tool Call Extraction", function()
  local text = [[
Here is my request. Please read this file:
@read_file({"path": "src/main.rs", "start_line": 1, "end_line": 20})

And run tests:
@run_command({"command": "cargo test"})

Ignore this code example:
```
@should_ignore({"param": true})
```
]]

  local calls = parser.extract_tool_calls(text)
  t.assert_eq(#calls, 2, "extracted exactly 2 tool calls (ignoring fenced code)")

  t.assert_eq(calls[1].name, "read_file", "first tool name")
  t.assert_eq(calls[1].args.path, "src/main.rs", "first tool path arg")
  t.assert_eq(calls[1].args.start_line, 1, "first tool start_line arg")

  t.assert_eq(calls[2].name, "run_command", "second tool name")
  t.assert_eq(calls[2].args.command, "cargo test", "second tool command arg")
end)

t.run("Tool Call Extraction ignores prose and inline code", function()
  local text = table.concat({
    "I can help with a variety of tasks! Here are some examples:",
    "1. **Read and Write Files**:",
    '- Reading a file: `@read_file({"path": "example.txt"})`',
    '- Writing: `@write_file({"path": "example.txt", "content": "hi"})`',
    '- A list item: @read_file({"path": "not-an-action.txt"})',
    "Feel free to ask me about @run_command(...) too.",
    "",
    "```",
    '@run_command({"command": "ignored"})',
    "```",
    "",
    '   @list_files({"path": "."})',
  }, "\n")

  local calls = parser.extract_tool_calls(text)
  t.assert_eq(#calls, 1, "only the standalone line is treated as an action")
  t.assert_eq(calls[1].name, "list_files", "standalone tool name")
  t.assert_eq(calls[1].args.path, ".", "standalone tool args")
end)

t.run("Agent fenced tool calls", function()
  local text = table.concat({
    "I will list the project:",
    "```plaintext",
    '@list_files({"path": "."})',
    "```",
  }, "\n")

  -- Documented examples stay ignored for user turns.
  t.assert_eq(#parser.extract_tool_calls(text), 0, "fenced calls are ignored by default")

  -- Agent output: a fence containing only a tool call is an action.
  local calls = parser.extract_tool_calls(text, { allow_fenced = true })
  t.assert_eq(#calls, 1, "agent fenced call is detected")
  t.assert_eq(calls[1].name, "list_files", "fenced tool name")

  local mixed = table.concat({
    "```text",
    "This tool reads a file:",
    '@read_file({"path": "README.md"})',
    "```",
  }, "\n")
  t.assert_eq(
    #parser.extract_tool_calls(mixed, { allow_fenced = true }),
    0,
    "fences with prose are not executed"
  )

  local code = table.concat({
    "```lua",
    '@read_file({"path": "README.md"})',
    "```",
  }, "\n")
  t.assert_eq(
    #parser.extract_tool_calls(code, { allow_fenced = true }),
    0,
    "programming-language code fences are not executed"
  )

  local blocks = {
    { role = "agent", content = text },
  }
  t.assert_eq(#parser.pair_tools_and_results(blocks), 1, "pairing sees agent fenced calls")
end)

t.run("Tool and Result Pairing", function()
  local blocks = {
    {
      role = "user",
      content = "Check this:\n@read_file({\"path\": \"README.md\"})",
    },
    {
      role = "result",
      id = 1,
      status = "ok",
      content = "# Readme info",
    },
    {
      role = "agent",
      content = "I will edit the file:\n@edit_file({\"path\": \"README.md\", \"target\": \"a\", \"replacement\": \"b\"})"
    }
  }

  local pairs = parser.pair_tools_and_results(blocks)
  t.assert_eq(#pairs, 2, "detected 2 tool calls across blocks")

  t.assert_eq(pairs[1].tool.name, "read_file", "tool 1 name")
  t.assert_eq(pairs[1].id, 1, "tool 1 assigned/matched id 1")
  t.assert_eq(pairs[1].result ~= nil, true, "tool 1 has matched result")
  t.assert_eq(pairs[1].result.status, "ok", "tool 1 result status ok")

  t.assert_eq(pairs[2].tool.name, "edit_file", "tool 2 name")
  t.assert_eq(pairs[2].id, 2, "tool 2 assigned next id 2")
  t.assert_eq(pairs[2].result == nil, true, "tool 2 does not have result yet (pending)")
end)

t.run("Heredoc body for write_file", function()
  local text = table.concat({
    '@write_file({"path": "src/main.go"}) <<\'EOF\'',
    'package main',
    'func main() { println("hi") }',
    'EOF',
    '@read_file({"path": "src/main.go"})',
  }, "\n")

  local calls = parser.extract_tool_calls(text)
  t.assert_eq(#calls, 2, "heredoc call plus the following read")
  t.assert_eq(calls[1].name, "write_file", "heredoc tool name")
  t.assert_eq(calls[1].args.path, "src/main.go", "JSON args preserved")
  t.assert_eq(calls[1].args.content, 'package main\nfunc main() { println("hi") }', "multi-line content verbatim")
  t.assert_true(calls[1].args.content:find('"', 1, true) ~= nil, "quotes need no escaping")
  t.assert_eq(calls[2].name, "read_file", "tool after heredoc still parsed")
end)

t.run("Heredoc body without parentheses for run_command", function()
  local text = table.concat({
    "@run_command <<'EOF'",
    "go test ./...",
    "go vet ./...",
    "EOF",
  }, "\n")

  local calls = parser.extract_tool_calls(text)
  t.assert_eq(#calls, 1, "one heredoc call")
  t.assert_eq(calls[1].name, "run_command", "run_command name")
  t.assert_eq(calls[1].args.command, "go test ./...\ngo vet ./...", "script body verbatim")
end)

t.run("Heredoc body for edit_file replacement", function()
  local text = table.concat({
    '@edit_file({"path": "a.lua", "target": "old"}) <<EOF',
    "new -- unquoted delimiter",
    "EOF",
  }, "\n")

  local calls = parser.extract_tool_calls(text)
  t.assert_eq(#calls, 1, "one call")
  t.assert_eq(calls[1].args.replacement, "new -- unquoted delimiter", "replacement set")
  t.assert_eq(calls[1].args.target, "old", "target stays in JSON")
end)

t.run("Markers inside a heredoc body stay literal", function()
  local lines = {
    "[me]",
    "write this",
    "",
    "[agent]",
    "@write_file({\"path\": \"doc.txt\"}) <<'EOF'",
    "[system]",
    "this is not a marker",
    "EOF",
    "",
    "[me]",
    "",
  }
  local blocks = parser.parse_blocks(lines)
  t.assert_eq(#blocks, 3, "heredoc body does not split the agent block")
  t.assert_eq(blocks[2].role, "agent", "second block is agent")
  t.assert_true(blocks[2].content:find("[system]", 1, true) ~= nil, "marker text preserved as content")

  local calls = parser.extract_tool_calls(blocks[2].content, { allow_fenced = true })
  t.assert_eq(#calls, 1, "heredoc call extracted from block")
  t.assert_eq(calls[1].args.content, "[system]\nthis is not a marker", "body preserved verbatim")
end)
