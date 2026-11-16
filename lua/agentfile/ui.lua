-- lua/agentfile/ui.lua
local markers = require("agentfile.markers")

local M = {}
local fold_cache

--- Custom foldexpr for agentfile buffer
--- Automatically folds think blocks and result blocks
function M.foldexpr(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local marker_key = vim.inspect(markers.all())
  if not fold_cache or fold_cache.bufnr ~= bufnr or fold_cache.tick ~= tick
    or fold_cache.marker_key ~= marker_key then
    local parser = require("agentfile.parser")
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local _, end_fm = parser.parse_frontmatter(lines)
    local headers = {}
    for _, block in ipairs(parser.parse_blocks(lines, end_fm + 1)) do
      headers[block.start_line] = block.kind
    end
    fold_cache = { bufnr = bufnr, tick = tick, marker_key = marker_key, headers = headers }
  end
  local kind = fold_cache.headers[lnum]

  if kind == "think" or kind == "result" then
    return ">1"
  end

  if kind == "system" or kind == "me" or kind == "agent" or kind == "ask" or kind == "reset" or kind == "error" or kind == "done" then
    return "0"
  end

  -- Keep current fold level
  return "="
end

function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  local count = vim.v.foldend - vim.v.foldstart + 1
  return string.format("+-- %d lines: %s ... ", count, line)
end

--- Show floating hover doc for @tool_name under cursor
function M.hover_tool(bufnr)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  -- Look for @tool_name pattern on current line
  local tool_name = nil
  for match in line:gmatch("@([a-zA-Z0-9_]+)") do
    local s, e = line:find("@" .. match, 1, true)
    if s and e and col >= s and col <= e + 1 then
      tool_name = match
      break
    end
  end

  if not tool_name then
    -- Fallback: check if line contains any tool call
    tool_name = line:match("@([a-zA-Z0-9_]+)")
  end

  if not tool_name then
    vim.notify("[agentfile] No tool under cursor (e.g. @read_file)", vim.log.levels.INFO)
    return
  end

  local tools = require("agentfile.tools")
  local spec = tools.get(tool_name)
  if not spec then
    vim.notify("[agentfile] Tool @" .. tool_name .. " not found in registry", vim.log.levels.WARN)
    return
  end

  local docs = {
    "# @" .. tool_name,
    "",
    spec.description or "No description provided.",
    "",
    "### Parameters:",
  }

  for k, v in pairs(spec.parameters or {}) do
    table.insert(docs, string.format("- `%s`: %s", k, tostring(v)))
  end

  if spec.example then
    table.insert(docs, "")
    table.insert(docs, "### Example:")
    table.insert(docs, "```text")
    table.insert(docs, spec.example)
    table.insert(docs, "```")
  end

  if spec.is_dangerous then
    table.insert(docs, "")
    table.insert(docs, "> ⚠️ **Dangerous tool**: Requires user confirmation when auto_run_tools=false.")
  end

  vim.lsp.util.open_floating_preview(docs, "markdown", {
    border = "rounded",
    focus = false,
  })
end

local SYNTAX_GROUPS = {
  system = "agentfileSystem",
  me = "agentfileMe",
  think = "agentfileThinkHeader",
  agent = "agentfileAgent",
  result = "agentfileResult",
  ask = "agentfileAsk",
  reset = "agentfileReset",
  error = "agentfileError",
  done = "agentfileDone",
}

--- Highlight the active (possibly custom) markers in this buffer.
function M.apply_marker_syntax(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    for kind, group in pairs(SYNTAX_GROUPS) do
      local pattern = markers.vim_pattern(kind)
      if pattern then
        pcall(vim.cmd, "syntax match " .. group .. " /" .. pattern .. "/")
      end
    end
  end)
end

function M.setup_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Window options are per-window, so apply them to every window showing
  -- this buffer (the buffer may be hidden; BufWinEnter will retry later).
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win].foldmethod = "expr"
    vim.wo[win].foldexpr = "v:lua.require('agentfile.ui').foldexpr(v:lnum)"
    vim.wo[win].foldtext = "v:lua.require('agentfile.ui').foldtext()"
    vim.wo[win].foldenable = true
  end

  -- Make sure custom markers are highlighted too (only once per buffer).
  if not vim.b[bufnr].agentfile_marker_syntax then
    vim.b[bufnr].agentfile_marker_syntax = true
    M.apply_marker_syntax(bufnr)
  end

  -- Set buffer local keymaps
  local opts = { buffer = bufnr, silent = true, noremap = true }
  vim.keymap.set("n", "K", function() M.hover_tool(bufnr) end, vim.tbl_extend("force", opts, { desc = "Show tool hover doc" }))
  vim.keymap.set("n", "<leader>ay", "<cmd>AgentfileApprove<CR>", vim.tbl_extend("force", opts, { desc = "Approve pending tool (or edit [ask] to y)" }))
  vim.keymap.set("n", "<leader>an", "<cmd>AgentfileReject<CR>", vim.tbl_extend("force", opts, { desc = "Reject pending tool (or edit [ask] to n)" }))
  vim.keymap.set("n", "<leader>ax", "<cmd>AgentfileCancel<CR>", vim.tbl_extend("force", opts, { desc = "Cancel running stream" }))
  vim.keymap.set("n", "<leader>as", "<cmd>AgentfileSend<CR>", vim.tbl_extend("force", opts, { desc = "Force send turn" }))
  vim.keymap.set("n", "<leader>au", "<cmd>AgentfileUndo<CR>", vim.tbl_extend("force", opts, { desc = "Undo file modification of tool under cursor" }))
  vim.keymap.set("n", "<leader>aD", "<cmd>AgentfileDiff<CR>", vim.tbl_extend("force", opts, { desc = "Show diff of tool modification" }))
end

--- Toggle a side panel vertical split for the chat buffer.
---@param path? string
---@param width_ratio? number
function M.toggle_chat(path, width_ratio)
  path = path or require("agentfile").last_chat_path or "chat.agentfile"
  local target_full = vim.fn.fnamemodify(path, ":p")

  -- Check if a window is already displaying this chat buffer
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local b = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == target_full then
        -- Close the window
        vim.api.nvim_win_close(win, true)
        return
      end
    end
  end

  -- Not visible: open in a vertical split on the right
  local width = math.floor(vim.o.columns * (width_ratio or 0.38))
  if width < 30 then width = 30 end

  vim.cmd("botright " .. tostring(width) .. "vsplit")
  require("agentfile").open(path)
end

--- Show unified diff in a temporary scratch split.
---@param diff_text string
---@param title? string
function M.show_diff_split(diff_text, title)
  title = title or "Tool Diff"
  vim.cmd("botright 45vsplit")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "diff"
  pcall(vim.api.nvim_buf_set_name, bufnr, title)

  local lines = vim.split(diff_text, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  -- Map q to close
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = bufnr, silent = true })
end

return M
