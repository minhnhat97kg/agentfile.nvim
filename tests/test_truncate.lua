-- tests/test_truncate.lua
local t = require("tests.minimal_init")
local truncate = require("agentfile.tools.truncate")

t.run("Budget scales with the context window", function()
  t.assert_eq(truncate.budget({ context_window = 8192 }), 9830, "30% of an 8k window in chars")
  t.assert_eq(truncate.budget({ context_window = 1000 }), 2000, "small windows get a floor")
  t.assert_eq(truncate.budget({ context_window = 1000000 }), 50000, "huge windows are capped")
  t.assert_eq(truncate.budget({}), 39321, "default 32k window")
end)

t.run("Short text is untouched", function()
  local out, truncated = truncate.text("hello", { max_chars = 100 })
  t.assert_eq(out, "hello", "content preserved")
  t.assert_eq(truncated, false, "not truncated")
end)

t.run("Long text keeps head and tail", function()
  local text = string.rep("H", 100) .. "MIDDLE" .. string.rep("T", 100)
  local out, truncated = truncate.text(text, { max_chars = 80 })
  t.assert_eq(truncated, true, "truncated")
  t.assert_true(out:find("characters elided", 1, true) ~= nil, "reports elided size")
  t.assert_eq(out:sub(1, 1), "H", "head is kept")
  t.assert_eq(out:sub(-1), "T", "tail is kept")
  t.assert_true(out:find("MIDDLE", 1, true) == nil, "middle is dropped")
  t.assert_true(#out <= 80, "stays within budget")
end)

t.run("Hint is appended after truncation", function()
  local out = truncate.text(string.rep("x", 500), {
    max_chars = 100,
    hint = "Read a smaller range.",
  })
  t.assert_true(out:find("Hint: Read a smaller range.", 1, true) ~= nil, "actionable hint present")
end)
