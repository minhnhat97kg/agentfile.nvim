-- lua/agentfile/tools/truncate.lua
-- Context-budget aware truncation for tool observations.
--
-- Tool output is the most common way a small model blows its context window.
-- Instead of a fixed byte cap (and instead of keeping only the head, which
-- usually drops the compiler error at the end), keep head AND tail, say how
-- much was elided, and tell the model how to fetch less next time.
local M = {}

M.DEFAULT_MAX_CHARS = 10000
M.MIN_MAX_CHARS = 2000
M.MAX_MAX_CHARS = 50000

--- Character budget for one tool observation.
--- Uses ~30% of the context window (4 chars/token is a rough average for
--- mixed prose/code); falls back to a sane default when unknown.
---@param config? table # frontmatter config (context_window / max_context)
---@return integer
function M.budget(config)
  config = config or {}
  local window = tonumber(config.context_window) or tonumber(config.max_context) or 32768
  if window <= 0 then
    window = 32768
  end
  local budget = math.floor(window * 4 * 0.30)
  if budget < M.MIN_MAX_CHARS then
    budget = M.MIN_MAX_CHARS
  elseif budget > M.MAX_MAX_CHARS then
    budget = M.MAX_MAX_CHARS
  end
  return budget
end

--- Keep head and tail of `text`, insert an explicit elision marker and an
--- optional actionable hint.
---@param text string
---@param opts? table # { max_chars, head_ratio, hint }
---@return string text, boolean truncated
function M.text(text, opts)
  text = tostring(text or "")
  opts = opts or {}
  local max_chars = tonumber(opts.max_chars) or M.DEFAULT_MAX_CHARS
  if max_chars < 0 then
    max_chars = 0
  end
  if #text <= max_chars then
    return text, false
  end

  local elided = #text - max_chars
  local marker = string.format("\n... [%d characters elided] ...\n", elided)
  local keep = max_chars - #marker
  if keep < 0 then
    keep = 0
  end

  local head_ratio = tonumber(opts.head_ratio) or 0.5
  if head_ratio < 0 then head_ratio = 0 elseif head_ratio > 1 then head_ratio = 1 end
  local head = math.floor(keep * head_ratio)
  local tail = keep - head

  local parts = { text:sub(1, head), marker }
  if tail > 0 then
    parts[#parts + 1] = text:sub(#text - tail + 1)
  end
  if opts.hint and opts.hint ~= "" then
    parts[#parts + 1] = "Hint: " .. opts.hint
  end

  return table.concat(parts), true
end

return M
