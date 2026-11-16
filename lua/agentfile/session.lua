-- lua/agentfile/session.lua
local M = {}

--- Get or create the session directory (.agentfile in project root).
---@return string
function M.dir()
  local cwd = vim.fn.getcwd()
  local dir = cwd .. "/.agentfile"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

--- Format a topic slug into a filename.
---@param topic? string
---@return string
function M.generate_path(topic)
  local date_str = os.date("%Y-%m-%d")
  local slug = topic and topic:gsub("[^%w%-_]", "-"):lower() or "chat"
  slug = slug:gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if slug == "" then slug = "chat" end
  local dir = M.dir()
  local filename = string.format("%s/%s-%s.agentfile", dir, date_str, slug)
  local counter = 1
  while vim.fn.filereadable(filename) == 1 do
    filename = string.format("%s/%s-%s-%d.agentfile", dir, date_str, slug, counter)
    counter = counter + 1
  end
  return filename
end

--- List all session files in current project (.agentfile/*.agentfile and root *.agentfile).
---@return string[]
function M.list()
  local cwd = vim.fn.getcwd()
  local pattern = cwd .. "/.agentfile/*.agentfile"
  local files = vim.fn.glob(pattern, false, true)
  local root_files = vim.fn.glob(cwd .. "/*.agentfile", false, true)
  local seen = {}
  local result = {}
  for _, f in ipairs(files) do
    if not seen[f] then
      seen[f] = true
      table.insert(result, f)
    end
  end
  for _, f in ipairs(root_files) do
    if not seen[f] then
      seen[f] = true
      table.insert(result, f)
    end
  end
  table.sort(result)
  return result
end

--- Branch current chat buffer up to a specific line into a new session.
---@param src_bufnr number
---@param up_to_line? number
---@param topic? string
---@return string new_path
function M.branch(src_bufnr, up_to_line, topic)
  src_bufnr = src_bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(src_bufnr, 0, -1, false)
  local count = up_to_line or #lines
  if count > #lines then count = #lines end
  local branch_lines = vim.list_slice(lines, 1, count)

  local new_path = M.generate_path(topic or "branch")
  vim.fn.writefile(branch_lines, new_path)
  return new_path
end

return M
