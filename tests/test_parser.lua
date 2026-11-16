-- tests/test_parser.lua
local t = require("tests.minimal_init")
local parser = require("agentfile.parser")

t.run("Parser Frontmatter", function()
  vim.env.TEST_TOKEN_VAR = "sk-secret-12345"

  local lines = {
    "---",
    "host: https://api.openai.com/v1",
    "model: gpt-4o",
    "token: env:TEST_TOKEN_VAR",
    "temperature: 0.7",
    "max_tokens: 2048",
    "skills: [read_file, write_file, run_command]",
    "auto_run_tools: true",
    "---",
    "",
    "[system]",
    "You are a test assistant."
  }

  local config, end_idx = parser.parse_frontmatter(lines)
  t.assert_eq(config.host, "https://api.openai.com/v1", "host parsed")
  t.assert_eq(config.model, "gpt-4o", "model parsed")
  t.assert_eq(config.token, "sk-secret-12345", "token expanded from env")
  t.assert_eq(config.temperature, 0.7, "temperature parsed as number")
  t.assert_eq(config.max_tokens, 2048, "max_tokens parsed as integer")
  t.assert_eq(config.auto_run_tools, true, "auto_run_tools parsed as boolean")
  t.assert_eq(config.skills, {"read_file", "write_file", "run_command"}, "skills parsed as array")
  t.assert_eq(end_idx, 9, "frontmatter ends at line 9")
end)

t.run("Parser Blocks", function()
  local lines = {
    "[system]",
    "You are a helpful assistant.",
    "",
    "[me]",
    "Hello world!",
    "",
    "[think]",
    "I should greet the user politely.",
    "",
    "[agent]",
    "Hello! How can I help you today?",
    "",
    "[result id=1 status=ok]",
    "file contents here"
  }

  local blocks = parser.parse_blocks(lines)
  t.assert_eq(#blocks, 5, "parsed 5 blocks")
  t.assert_eq(blocks[1].role, "system", "block 1 is system")
  t.assert_eq(blocks[1].content, "You are a helpful assistant.", "block 1 content")

  t.assert_eq(blocks[2].role, "user", "block 2 is user")
  t.assert_eq(blocks[2].content, "Hello world!", "block 2 content")

  t.assert_eq(blocks[3].role, "think", "block 3 is think")
  t.assert_eq(blocks[3].content, "I should greet the user politely.", "block 3 content")

  t.assert_eq(blocks[4].role, "agent", "block 4 is agent")
  t.assert_eq(blocks[4].content, "Hello! How can I help you today?", "block 4 content")

  t.assert_eq(blocks[5].role, "result", "block 5 is result")
  t.assert_eq(blocks[5].id, 1, "block 5 id parsed")
  t.assert_eq(blocks[5].status, "ok", "block 5 status parsed")
  t.assert_eq(blocks[5].content, "file contents here", "block 5 content")
end)
