-- lua/agentfile/snapshot.lua
local M = {}

M.history = {}

--- Record file state before modification.
---@param id number
---@param path string
function M.record_before(id, path)
  if not id or not path then return end
  local full = vim.fn.fnamemodify(path, ":p")
  local original = nil
  if vim.fn.filereadable(full) == 1 then
    local lines = vim.fn.readfile(full, "b")
    original = table.concat(lines, "\n")
  end
  M.history[id] = {
    path = full,
    original = original,
    existed = original ~= nil,
  }
end

--- Record file state after modification.
---@param id number
---@param path string
function M.record_after(id, path)
  if not id or not M.history[id] then return end
  local full = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(full) == 1 then
    local lines = vim.fn.readfile(full, "b")
    M.history[id].new_content = table.concat(lines, "\n")
  end
end

--- Get unified diff between snapshot and current/modified state.
---@param id number
---@return string|nil diff, string|nil err
function M.diff(id)
  local item = M.history[id]
  if not item then
    return nil, "No snapshot found for tool call id " .. tostring(id)
  end

  local orig = item.original or ""
  local new_c = item.new_content
  if not new_c and vim.fn.filereadable(item.path) == 1 then
    new_c = table.concat(vim.fn.readfile(item.path, "b"), "\n")
  end
  new_c = new_c or ""

  local diff_res = vim.diff(orig, new_c, { result_type = "unified" })
  return diff_res
end

--- Revert file to pre-modification state.
---@param id number
---@return boolean ok, string msg
function M.revert(id)
  local item = M.history[id]
  if not item then
    return false, "No snapshot found for tool call id " .. tostring(id)
  end

  if not item.existed then
    if vim.fn.filereadable(item.path) == 1 then
      vim.fn.delete(item.path)
    end
    return true, "Removed created file " .. item.path
  else
    local lines = vim.split(item.original, "\n", { plain = true })
    vim.fn.writefile(lines, item.path, "b")
    -- Reload buffer in Neovim if open
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == item.path then
        vim.api.nvim_buf_call(buf, function() vim.cmd("edit!") end)
      end
    end
    return true, "Reverted " .. item.path .. " to snapshot."
  end
end

return M
