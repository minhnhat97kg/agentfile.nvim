-- lua/agentfile/memory.lua
-- Project memory for distilled, trustworthy lessons.
--
-- We deliberately do NOT store raw [think] blocks: replaying old reasoning
-- makes small models defend the mistake instead of fixing it, and it burns a
-- large share of an 8k context. What we store is the lesson: tool + cause that
-- was confirmed by a human rejection or by a later successful fix.
local M = {}

M.DEFAULT_PATH = ".agentfile/memory.md"
M.DEFAULT_MAX_CHARS = 1200
M.MAX_LESSON_CHARS = 200
M.HEADER = "# Agentfile memory"
M.NOTE = "<!-- Agentfile: distilled failures. Editable by humans; injected into the system prompt. -->"
M.SECTION = "## lessons"

--- Resolve the `memory:` frontmatter block.
---@param config? table
---@return table
function M.resolve(config)
  local raw = config and config.memory
  if raw == true then
    raw = { enabled = true }
  elseif type(raw) ~= "table" then
    raw = {}
  end

  local path = raw.path
  if type(path) ~= "string" or path == "" then
    path = M.DEFAULT_PATH
  end

  local max_chars = tonumber(raw.max_chars) or M.DEFAULT_MAX_CHARS
  if max_chars < 200 then max_chars = 200 end

  local require_approval = raw.require_approval
  if require_approval == nil then require_approval = true end

  return {
    enabled = raw.enabled == true,
    path = path,
    max_chars = max_chars,
    require_approval = require_approval == true,
    remember_rejections = raw.remember_rejections ~= false,
    remember_repeated_failures = raw.remember_repeated_failures ~= false,
    lesson_max_chars = tonumber(raw.lesson_max_chars) or M.MAX_LESSON_CHARS,
  }
end

--- Absolute path for the memory file.
---@param opts table
---@return string
function M.absolute_path(opts)
  local path = opts and opts.path or M.DEFAULT_PATH
  if path:sub(1, 1) == "/" then
    return path
  end
  local join = vim.fs and vim.fs.joinpath or function(a, b) return a .. "/" .. b end
  return join(vim.fn.getcwd(), path)
end

local function normalize(text)
  text = tostring(text or ""):lower()
  text = text:gsub("%s+", " ")
  text = text:gsub("^[%-%*]%s*", "")
  return text:gsub("^%s*(.-)%s*$", "%1")
end

--- Turn a detailed error into a stable signature, so the same root cause
--- (path typo, missing binary, ...) can be recognized across attempts.
---@param tool string
---@param text string
---@return string
function M.signature(tool, text)
  local first = tostring(text or ""):match("[^\r\n]+") or ""
  first = first:gsub("%b\"\"", "<str>")
  first = first:gsub("%b''", "<str>")
  first = first:gsub("[%w_%-%./\\]+%.%w+", "<path>")
  first = first:gsub("%d+", "<n>")
  first = first:gsub("%s+", " ")
  first = first:gsub("^%s*(.-)%s*$", "%1")
  return tostring(tool or "tool") .. ":" .. first:sub(1, 140)
end

--- Split a memory file into its `## lessons` entries (kept as full lines).
---@param text string
---@return string[] lessons, string[] before, string[] after
function M.parse(text)
  local lessons, before, after = {}, {}, {}
  local in_lessons = false
  local seen_section = false
  for line in tostring(text or ""):gmatch("[^\r\n]*") do
    if not in_lessons then
      if normalize(line) == normalize(M.SECTION) then
        in_lessons = true
        seen_section = true
      else
        before[#before + 1] = line
      end
    else
      if line:match("^##%s+") then
        in_lessons = false
        after[#after + 1] = line
      elseif line ~= "" then
        lessons[#lessons + 1] = line
      end
    end
  end
  -- gmatch on an empty trailing line drops it; section presence is what matters.
  if not seen_section then
    before = vim.split(tostring(text or ""), "\n", { plain = true })
    lessons = {}
  end
  return lessons, before, after
end

--- Read and cap the lessons section.
---@param opts table
---@return string[] lessons
function M.load(opts)
  local path = M.absolute_path(opts)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local lines = vim.fn.readfile(path)
  local lessons = M.parse(table.concat(lines, "\n"))
  return M.cap(lessons, opts.max_chars)
end

--- Keep the newest lessons that fit in `max_chars` (oldest lines are dropped).
---@param lessons string[]
---@param max_chars number
---@return string[]
function M.cap(lessons, max_chars)
  local kept, used = {}, 0
  for i = #lessons, 1, -1 do
    local line = lessons[i]
    local cost = #line + 1
    if used + cost > max_chars and #kept > 0 then
      break
    end
    table.insert(kept, 1, line)
    used = used + cost
  end
  return kept
end

--- System-prompt block for the project memory, or "" when disabled/empty.
---@param config? table # frontmatter config
---@return string
function M.prompt_text(config)
  local opts = M.resolve(config)
  if not opts.enabled then
    return ""
  end
  local lessons = M.load(opts)
  if #lessons == 0 then
    return ""
  end
  return table.concat({
    "PROJECT MEMORY (distilled failures; do not repeat these):",
    table.concat(lessons, "\n"),
    "If a lesson applies, change your approach instead of retrying the same call.",
  }, "\n")
end

--- Format one lesson line.
---@param lesson table # { tool, text, source?, date? }
---@param opts table
---@return string
function M.format_lesson(lesson, opts)
  local text = tostring(lesson.text or ""):gsub("[\r\n]+", " ")
  text = text:gsub("%s+", " ")
  text = text:gsub("^%s*(.-)%s*$", "%1")
  local limit = (opts and opts.lesson_max_chars) or M.MAX_LESSON_CHARS
  if #text > limit then
    text = text:sub(1, limit - 3) .. "..."
  end
  local tool = tostring(lesson.tool or "tool")
  local meta = {}
  if lesson.source and lesson.source ~= "" then
    meta[#meta + 1] = tostring(lesson.source)
  end
  local date = lesson.date or os.date("%Y-%m-%d")
  meta[#meta + 1] = date
  return string.format("- [%s] %s (%s)", tool, text, table.concat(meta, ", "))
end

--- Append a lesson, deduplicating and enforcing the size cap.
---@param opts table
---@param lesson table # { tool, text, source?, date? }
---@return boolean added, string path|string err
function M.add_lesson(opts, lesson)
  local text = tostring(lesson.text or ""):gsub("%s+", " ")
  if text == "" then
    return false, "empty lesson"
  end

  local path = M.absolute_path(opts)
  local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
  local existing = M.parse(table.concat(lines, "\n"))
  local normalized = normalize(text)

  for _, line in ipairs(existing) do
    local normalized_line = normalize(line)
    if normalized_line:find(normalized, 1, true) or normalized:find(normalized_line, 1, true) then
      return false, "duplicate"
    end
  end

  local entry = M.format_lesson(lesson, opts)
  existing[#existing + 1] = entry
  existing = M.cap(existing, opts.max_chars)

  local out = {
    M.HEADER,
    M.NOTE,
    "",
    M.SECTION,
  }
  vim.list_extend(out, existing)

  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  local ok, err = pcall(vim.fn.writefile, out, path)
  if not ok then
    return false, tostring(err)
  end
  return true, path
end

--- Ask the user before persisting a lesson (memory can poison later sessions).
---@param opts table
---@param lesson table
---@param on_done? fun(added: boolean)
function M.propose(opts, lesson, on_done)
  local function finish(added)
    if on_done then pcall(on_done, added) end
  end

  if not opts or not opts.enabled then
    return finish(false)
  end

  if not opts.require_approval then
    local added = M.add_lesson(opts, lesson)
    return finish(added)
  end

  local target = vim.fn.fnamemodify(M.absolute_path(opts), ":.")
  vim.ui.select({ "Save lesson", "Skip" }, {
    prompt = string.format("Agentfile: save lesson to %s? — %s", target, tostring(lesson.text or "")),
  }, function(choice)
    if choice == "Save lesson" then
      local added, err = M.add_lesson(opts, lesson)
      if not added and err ~= "duplicate" then
        vim.notify("[agentfile] Could not save memory lesson: " .. tostring(err), vim.log.levels.WARN)
      elseif not added then
        vim.notify("[agentfile] Lesson already in project memory.", vim.log.levels.INFO)
      else
        vim.notify("[agentfile] Lesson saved to " .. target, vim.log.levels.INFO)
      end
      return finish(added == true)
    end
    finish(false)
  end)
end

--- Create the memory file if missing and open it for editing.
---@param opts table
---@return string path
function M.open(opts)
  local path = M.absolute_path(opts or M.resolve({}))
  if vim.fn.filereadable(path) == 0 then
    M.add_lesson(opts, {
      tool = "note",
      text = "Replace this example with a real, verified lesson.",
      source = "seed",
    })
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return path
end

return M
