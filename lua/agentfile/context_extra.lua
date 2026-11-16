-- lua/agentfile/context_extra.lua
local M = {}

local severity_names = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

--- Format a list of diagnostic items into a readable markdown string.
---@param items table[]
---@return string
function M.format_diagnostic_items(items)
  if not items or #items == 0 then
    return ""
  end

  local lines = { "### LSP Diagnostics", "" }
  for _, d in ipairs(items) do
    local sev = severity_names[d.severity] or "INFO"
    local buf_name = vim.api.nvim_buf_is_valid(d.bufnr or 0) and vim.api.nvim_buf_get_name(d.bufnr) or "buffer"
    local rel_path = vim.fn.fnamemodify(buf_name, ":.")
    local lnum = (d.lnum or 0) + 1
    local col = (d.col or 0) + 1
    local src = d.source and (" (" .. d.source .. ")") or ""
    table.insert(lines, string.format("- `%s:%d:%d` [%s]%s: %s", rel_path, lnum, col, sev, src, d.message))
  end
  return table.concat(lines, "\n")
end

--- Get diagnostics for a buffer or the entire workspace.
---@param bufnr? number
---@return string
function M.get_diagnostics(bufnr)
  local items = {}
  if bufnr and bufnr ~= 0 and vim.api.nvim_buf_is_valid(bufnr) then
    items = vim.diagnostic.get(bufnr)
  else
    -- Try current buffer first, if none then all diagnostics
    items = vim.diagnostic.get(0)
    if #items == 0 then
      items = vim.diagnostic.get(nil)
    end
  end

  if #items == 0 then
    return "No LSP diagnostics found."
  end

  return M.format_diagnostic_items(items)
end

--- Format diff output into markdown code fence.
---@param diff_str string
---@return string
function M.format_diff_output(diff_str)
  diff_str = (diff_str or ""):gsub("^%s*(.-)%s*$", "%1")
  if diff_str == "" then
    return "No git changes detected."
  end
  return "```diff\n" .. diff_str .. "\n```"
end

--- Get git diff as formatted markdown string.
---@param staged_only? boolean
---@return string
function M.get_git_diff(staged_only)
  local cmd = staged_only and "git diff --cached" or "git diff HEAD"
  local handle = io.popen(cmd .. " 2>&1")
  if not handle then
    return "Failed to run git diff."
  end
  local result = handle:read("*a")
  handle:close()

  if not result or result:gsub("%s+", "") == "" then
    -- Fallback to unstaged diff
    local h2 = io.popen("git diff 2>&1")
    if h2 then
      result = h2:read("*a")
      h2:close()
    end
  end

  return M.format_diff_output(result)
end

return M
