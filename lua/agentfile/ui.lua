-- lua/agentfile/ui.lua
local markers = require("agentfile.markers")
local state = require("agentfile.state")

local M = {}
local fold_cache

local context_ns = vim.api.nvim_create_namespace("agentfile_context")
local info_cache = {}

local DEFAULT_CONFIG = {
  -- Set to false to keep your own winbar (e.g. from a winbar plugin).
  winbar = true,
}

local config = vim.tbl_deep_extend("force", {}, DEFAULT_CONFIG)

local WINBAR_EXPR = "%{%v:lua.require'agentfile.ui'.winbar()%}"

local STATUS = {
  idle = { text = "ready", icon = "●", hl = "AgentfileWinbarIdle" },
  parsing = { text = "thinking", icon = "◌", hl = "AgentfileWinbarBusy" },
  streaming = { text = "generating", icon = "◐", hl = "AgentfileWinbarBusy" },
  tools_running = { text = "running tool", icon = "⚙", hl = "AgentfileWinbarBusy" },
  awaiting_approval = { text = "approval needed", icon = "!", hl = "AgentfileWinbarApproval" },
}

local STATUS_ICONS = {
  ok = "✓",
  error = "✗",
  pending = "◌",
  rejected = "⊘",
}

local function define_highlights()
  local groups = {
    AgentfileWinbarFile = { link = "Title" },
    AgentfileWinbarIdle = { link = "Comment" },
    AgentfileWinbarBusy = { link = "DiagnosticInfo" },
    AgentfileWinbarApproval = { link = "DiagnosticWarn" },
    AgentfileWinbarDone = { link = "DiagnosticOk" },
    AgentfileWinbarError = { link = "DiagnosticError" },
    AgentfileWinbarMuted = { link = "Comment" },
    AgentfileContext = { link = "DiagnosticInfo" },
    AgentfileContextWarn = { link = "DiagnosticWarn" },
    AgentfileContextError = { link = "DiagnosticError" },
  }

  for name, spec in pairs(groups) do
    spec.default = true
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
end

define_highlights()

--- Apply UI options from setup().
---@param opts? table|boolean
function M.setup(opts)
  if opts == false then
    config.winbar = false
  elseif type(opts) == "table" then
    config = vim.tbl_deep_extend("force", {}, DEFAULT_CONFIG, opts)
  end

  define_highlights()
  M.refresh_winbars()
end

local function truncate_text(s, max)
  s = tostring(s or "")
  if max <= 0 then
    return ""
  end
  if vim.fn.strchars(s) <= max then
    return s
  end
  return vim.fn.strcharpart(s, 0, max - 1) .. "…"
end

local function truncate_display(s, max)
  s = tostring(s or "")
  if max <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(s) <= max then
    return s
  end

  local chars = vim.fn.strchars(s)
  while chars > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(s, 0, chars)) > max - 1 do
    chars = chars - 1
  end
  return vim.fn.strcharpart(s, 0, chars) .. "…"
end

local function format_tokens(n)
  n = tonumber(n) or 0
  if n >= 1000000 then
    return string.format("%.1fm", n / 1000000)
  end
  if n >= 1000 then
    return string.format("%.1fk", n / 1000)
  end
  return tostring(math.floor(n))
end

--- Read cheap, buffer-local UI data (model, context limit, step budget).
--- Cached by changedtick because it is called from an expression winbar.
---@param bufnr number
---@return table
local function buffer_info(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = info_cache[bufnr]
  if cached and cached.tick == tick then
    return cached
  end

  local info = { tick = tick, model = nil, limit = nil, max_steps = nil }
  pcall(function()
    local parser = require("agentfile.parser")
    local agent_config = require("agentfile.agent_config")
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local fm = select(1, parser.parse_frontmatter(lines)) or {}
    info.model = fm.model or fm.host
    info.limit = tonumber(fm.context_window) or tonumber(fm.max_context)
    local agent = select(1, agent_config.resolve(fm))
    if agent then
      info.max_steps = agent.max_steps
    end
  end)

  info_cache[bufnr] = info
  return info
end

--- Structured pieces of the agent status, used by the winbar and by
--- external statuslines. Each part is { text = string, hl = highlight_group }.
---@param bufnr? number
---@return table[]
function M.status_parts(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local buf_state = state.get(bufnr)
  local info = buffer_info(bufnr)

  local status = buf_state.status or "idle"
  local spec = STATUS[status] or { text = status, icon = "●", hl = "AgentfileWinbarIdle" }

  -- A finished turn keeps a meaningful status instead of immediately
  -- collapsing back to the less informative "ready".
  if status == "idle" then
    if buf_state.exit_status == "submitted" or buf_state.exit_status == "completed" then
      spec = { text = "done", icon = "✓", hl = "AgentfileWinbarDone" }
    elseif buf_state.exit_status == "cancelled" then
      spec = { text = "cancelled", icon = "⊘", hl = "AgentfileWinbarMuted" }
    elseif buf_state.exit_status == "format_error"
      or buf_state.exit_status == "limits_exceeded"
      or buf_state.exit_status == "time_exceeded" then
      spec = { text = "stopped", icon = "!", hl = "AgentfileWinbarError" }
    end
  end

  local parts = {
    { text = "agentfile", hl = "AgentfileWinbarFile" },
    { text = spec.icon .. " " .. spec.text, hl = spec.hl },
  }

  if (buf_state.agent_steps or 0) > 0 and info.max_steps then
    parts[#parts + 1] = {
      text = string.format("step %d/%d", buf_state.agent_steps, info.max_steps),
      hl = "AgentfileWinbarMuted",
    }
  end

  local used = tonumber(buf_state.context_used)
  local limit = tonumber(buf_state.context_limit) or info.limit
  if used and limit and limit > 0 then
    local pct = math.floor((used / limit) * 100 + 0.5)
    local hl = pct >= 90 and "AgentfileContextError"
      or pct >= 70 and "AgentfileContextWarn"
      or "AgentfileContext"
    parts[#parts + 1] = {
      text = string.format("%s/%s (%d%%)", format_tokens(used), format_tokens(limit), pct),
      hl = hl,
    }
  end

  if info.model and info.model ~= "" then
    parts[#parts + 1] = {
      text = truncate_text(info.model, 28),
      hl = "AgentfileWinbarMuted",
    }
  end

  return parts
end

--- Plain-text status, suitable for lualine/statusline integrations.
---@param bufnr? number
---@return string
function M.statusline(bufnr)
  local texts = {}
  for _, part in ipairs(M.status_parts(bufnr)) do
    texts[#texts + 1] = part.text
  end
  return table.concat(texts, " · ")
end

--- Winbar expression. Must never throw: it is evaluated on every redraw.
---@return string
function M.winbar()
  local ok, result = pcall(function()
    local parts = M.status_parts()
    local out = {}
    for _, part in ipairs(parts) do
      local text = tostring(part.text or ""):gsub("[\r\n]+", " "):gsub("%%", "%%%%")
      out[#out + 1] = string.format("%%#%s# %s %%*", part.hl, text)
    end
    return " " .. table.concat(out, "  ") .. " "
  end)
  return ok and result or ""
end

--- Attach the winbar to a window unless it already has a custom one.
---@param win? number
function M.apply_winbar(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  local ok, current = pcall(function()
    return vim.wo[win].winbar
  end)
  if not ok then
    return
  end

  if not config.winbar then
    -- Only clear our own expression; never clobber a user winbar.
    if current == WINBAR_EXPR then
      pcall(function()
        vim.wo[win].winbar = ""
      end)
    end
    return
  end

  if current == "" or current == WINBAR_EXPR then
    pcall(function()
      vim.wo[win].winbar = WINBAR_EXPR
    end)
  end
end

--- Re-apply the winbar after setup() changes (e.g. toggling winbar off).
function M.refresh_winbars()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local bufnr = vim.api.nvim_win_get_buf(win)
      if vim.b[bufnr].agentfile_marker_syntax then
        M.apply_winbar(win)
      end
    end
  end
end

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

--- Build a one-line fold summary. Extracted so it can be tested without
--- entering an actual fold.
---@param start_line number
---@param end_line number
---@return string
function M.fold_summary(start_line, end_line)
  local line = vim.fn.getline(start_line)
  local kind, extra = markers.kind_of(line)
  local count = math.max(1, end_line - start_line + 1)

  local label = kind or "fold"
  local icon = ""
  if kind == "result" then
    local _, status = markers.parse_result_attrs(extra)
    label = status and ("result " .. status) or "result"
    icon = STATUS_ICONS[status] or ""
  elseif kind == "think" then
    icon = "…"
  elseif kind == "error" then
    icon = "!"
  elseif kind == "ask" then
    icon = "?"
  elseif kind == "done" then
    icon = "✓"
  end

  local head = string.format(
    "+-- %s%s · %d lines",
    icon ~= "" and (icon .. " ") or "",
    label,
    count
  )

  -- First non-empty content line gives the fold a useful preview.
  local preview = ""
  for i = start_line + 1, end_line do
    local l = vim.fn.getline(i)
    if l and l:find("%S") then
      preview = l
      break
    end
  end
  preview = preview:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

  if preview ~= "" then
    local width = 0
    pcall(function()
      width = vim.api.nvim_win_get_width(0)
    end)
    if width <= 0 then
      width = 100
    end
    local avail = width - vim.fn.strdisplaywidth(head) - 3
    if avail > 8 then
      head = head .. ": " .. truncate_display(preview, avail)
    end
  end

  return head
end

function M.foldtext()
  return M.fold_summary(vim.v.foldstart, vim.v.foldend)
end

--- Clear the context meter highlight for a buffer.
---@param bufnr number
function M.clear_context(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, context_ns, 0, -1)
  end
end

--- Color the `(context used/limit ...)` suffix by budget pressure.
---@param bufnr number
---@param line number 1-based marker line
---@param start_col number 0-based byte column
---@param end_col number 0-based exclusive byte column
---@param used number|nil
---@param limit number|nil
function M.highlight_context(bufnr, line, start_col, end_col, used, limit)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local line_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local max_col = #line_text
  start_col = math.max(0, math.min(start_col, max_col))
  end_col = math.max(0, math.min(end_col, max_col))
  if end_col <= start_col then
    return
  end

  M.clear_context(bufnr)

  used = tonumber(used)
  limit = tonumber(limit)
  local ratio = (used and limit and limit > 0) and (used / limit) or 0
  local group = ratio >= 0.9 and "AgentfileContextError"
    or ratio >= 0.7 and "AgentfileContextWarn"
    or "AgentfileContext"

  pcall(vim.api.nvim_buf_set_extmark, bufnr, context_ns, line - 1, start_col, {
    end_col = end_col,
    hl_group = group,
    priority = 200,
  })
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

  local params = {}
  for k, v in pairs(spec.parameters or {}) do
    params[#params + 1] = string.format("- `%s`: %s", k, tostring(v))
  end
  table.sort(params)
  vim.list_extend(docs, params)

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
    wrap = true,
    max_width = 72,
    title = "@" .. tool_name,
    title_pos = "center",
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

  -- Buffer numbers are reused after deletion; drop cached data for a fresh
  -- buffer before reading its frontmatter.
  info_cache[bufnr] = nil
  fold_cache = nil

  -- Window options are per-window, so apply them to every window showing
  -- this buffer (the buffer may be hidden; BufWinEnter will retry later).
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win].foldmethod = "expr"
    vim.wo[win].foldexpr = "v:lua.require('agentfile.ui').foldexpr(v:lnum)"
    vim.wo[win].foldtext = "v:lua.require('agentfile.ui').foldtext()"
    vim.wo[win].foldenable = true
    M.apply_winbar(win)
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

--- Stream long-running command output into a small floating window.
--- The window appears only after 250ms so quick commands do not flicker.
---@param title? string
---@return table # { append(text), close() }
function M.command_progress(title)
  title = tostring(title or "Agentfile command"):gsub("[\r\n]+", " "):sub(1, 60)

  local progress = {
    lines = {},
    buf = nil,
    win = nil,
    timer = nil,
    closed = false,
    render_pending = false,
  }

  local function render()
    if progress.closed or not progress.win or not vim.api.nvim_win_is_valid(progress.win) then
      return
    end
    pcall(vim.api.nvim_buf_set_lines, progress.buf, 0, -1, false, progress.lines)
    pcall(vim.api.nvim_win_set_cursor, progress.win, { math.max(1, #progress.lines), 0 })
  end

  local function open()
    if progress.closed or (progress.win and vim.api.nvim_win_is_valid(progress.win)) then
      return
    end

    local width = math.min(90, math.max(24, math.floor(vim.o.columns * 0.55)))
    width = math.max(10, math.min(width, vim.o.columns - 2))
    local height = math.min(12, math.max(4, math.floor(vim.o.lines * 0.25)))
    height = math.max(3, math.min(height, vim.o.lines - 2))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = true
    vim.bo[buf].filetype = "log"

    local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
      relative = "editor",
      anchor = "SE",
      row = vim.o.lines - 2,
      col = vim.o.columns - 2,
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = " " .. title .. " ",
      title_pos = "center",
    })
    if not ok then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      return
    end

    progress.buf = buf
    progress.win = win
    pcall(function()
      vim.wo[win].wrap = false
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = "no"
      vim.wo[win].foldenable = false
      vim.wo[win].winhighlight = "NormalFloat:NormalFloat"
    end)
    render()
  end

  function progress:append(text)
    if self.closed then
      return
    end
    text = tostring(text or ""):gsub("\r\n", "\n")
    for line in (text .. "\n"):gmatch("(.-)\n") do
      self.lines[#self.lines + 1] = line
    end
    while #self.lines > 200 do
      table.remove(self.lines, 1)
    end

    if not self.timer and not self.win then
      self.timer = vim.defer_fn(function()
        self.timer = nil
        open()
      end, 250)
      return
    end
    if not self.win then
      return
    end

    if not self.render_pending then
      self.render_pending = true
      vim.schedule(function()
        self.render_pending = false
        render()
      end)
    end
  end

  function progress:close()
    if self.closed then
      return
    end
    self.closed = true

    if self.timer then
      pcall(function()
        self.timer:stop()
        self.timer:close()
      end)
      self.timer = nil
    end
    if self.win and vim.api.nvim_win_is_valid(self.win) then
      pcall(vim.api.nvim_win_close, self.win, true)
    end
    if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
      pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
    end
    self.win = nil
    self.buf = nil
  end

  return progress
end

--- Show unified diff in a temporary scratch split.
---@param diff_text string
---@param title? string
function M.show_diff_split(diff_text, title)
  title = title or "Tool Diff"
  local width = math.max(40, math.floor(vim.o.columns * 0.45))
  width = math.min(width, math.max(40, vim.o.columns - 10))
  vim.cmd("botright " .. tostring(width) .. "vsplit")

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

  -- A compact diff view: no line numbers/signs, no wrapping.
  pcall(function()
    vim.wo[0].number = false
    vim.wo[0].relativenumber = false
    vim.wo[0].signcolumn = "no"
    vim.wo[0].wrap = false
    vim.wo[0].foldenable = false
    vim.wo[0].winbar = " " .. title:gsub("%%", "%%%%") .. "  %#AgentfileWinbarMuted#q: close%*"
  end)

  -- Map q to close
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = bufnr, silent = true })
end

return M
