-- Markdown envelope for tool data. A delimiter longer than every backtick run
-- in the output prevents nested files/fences from ending the envelope early.
local M = {}

function M.lines(text)
  text = tostring(text or "")
  local size = 3
  for run in text:gmatch("`+") do
    size = math.max(size, #run + 1)
  end
  local fence = string.rep("`", size)
  local lines = { fence .. "agentfile-result" }
  vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  lines[#lines + 1] = fence
  return lines
end

return M
