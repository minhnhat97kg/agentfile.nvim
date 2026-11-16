-- tests/minimal_init.lua
local M = {}

local failures = 0
local total = 0

function M.assert_eq(actual, expected, msg)
  total = total + 1
  local ok = vim.deep_equal(actual, expected)
  if not ok then
    failures = failures + 1
    local err = string.format("FAIL: %s\n  expected: %s\n  actual:   %s", 
      msg or "", vim.inspect(expected), vim.inspect(actual))
    print(err)
    error(err)
  else
    if msg then
      print("  ✓ " .. msg)
    end
  end
end

function M.assert_true(val, msg)
  M.assert_eq(val == true, true, msg)
end

function M.run(suite_name, fn)
  print("\n=== Running Suite: " .. suite_name .. " ===")
  local ok, err = pcall(fn)
  if not ok then
    print("Suite FAILED: " .. tostring(err))
    os.exit(1)
  else
    print("=== Suite " .. suite_name .. " PASSED ===\n")
  end
end

-- Add project root to package.path
local current_dir = vim.fn.getcwd()
package.path = current_dir .. "/lua/?.lua;" .. current_dir .. "/lua/?/init.lua;" .. package.path
package.path = current_dir .. "/?.lua;" .. package.path

return M
