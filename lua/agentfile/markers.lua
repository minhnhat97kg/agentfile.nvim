-- lua/agentfile/markers.lua
-- Central definition of block markers.
-- Change the whole file format in one place (or via setup({ markers = {...} })).
local M = {}

--- Default markers.
--- `%s` in a marker is the placeholder for attributes (currently only `result`).
local DEFAULTS = {
  system = "[system]",
  me     = "[me]",
  think  = "[think]",
  agent  = "[agent]",
  result = "[result%s]",
  ask    = "[ask] %s",
  reset  = "[reset]",
  error  = "[error]",
  done   = "[done]",
}

local ORDER = { "system", "me", "think", "agent", "result", "ask", "reset", "error", "done" }

local current = {}

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

current = copy(DEFAULTS)

--- Escape Lua pattern magic characters
local function lua_escape(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- Build a Lua pattern from a marker template.
--- `[result%s]` -> `^%[result(.-)%]%s*$`
local function template_pattern(tpl)
  local escaped = lua_escape(tpl)
  local pattern = escaped:gsub("%%%%s", "(.-)")
  return "^" .. pattern .. "%s*$"
end

--- Apply custom markers. Unknown keys are ignored.
---@param opts? table # e.g. { me = ">>me", result = ">>result%s" }
---@return table # snapshot of the active markers
function M.setup(opts)
  if opts then
    for kind, value in pairs(opts) do
      if DEFAULTS[kind] ~= nil then
        if type(value) ~= "string" or value == "" then
          error("[agentfile] invalid marker for '" .. kind .. "': expected non-empty string")
        end
        current[kind] = value
      end
    end
  end
  return copy(current)
end

--- Restore the default markers.
function M.reset()
  current = copy(DEFAULTS)
end

--- Get a marker template.
---@param kind string
---@return string|nil
function M.get(kind)
  return current[kind]
end

--- Snapshot of all active markers.
---@return table
function M.all()
  return copy(current)
end

--- Render a marker line.
---@param kind string
---@param attrs? table|string # { id = 1, status = "ok" } or raw attribute string
---@return string
function M.format(kind, attrs)
  local tpl = current[kind]
  if not tpl then
    return ""
  end

  local extra = ""
  if type(attrs) == "table" then
    if attrs.id ~= nil then
      extra = extra .. " id=" .. tostring(attrs.id)
    end
    if attrs.status ~= nil then
      extra = extra .. " status=" .. tostring(attrs.status)
    end
  elseif type(attrs) == "string" and attrs ~= "" then
    -- String attributes (e.g. the [ask] question) are inserted verbatim so
    -- templates can control spacing: "[ask] %s".
    extra = attrs
  end

  if not tpl:find("%%s") then
    return tpl
  end
  -- Use a function replacement so '%' inside attrs is not treated as a
  -- capture reference (commands/questions may contain %).
  return (tpl:gsub("%%s", function() return extra end))
end

--- Detect which block kind a line starts, using the active markers.
--- Legacy aliases (`>>me`, `#me`, `[me]`) are always accepted so old buffers
--- keep working after changing the default marker style.
---@param line string|nil
---@return string|nil kind, string|nil attributes
function M.kind_of(line)
  if not line or line == "" then
    return nil
  end

  -- The latest [me] line may carry an inline context-size suffix written by
  -- the plugin, e.g. `[me](context 1234/8192)`. Ignore it when recognizing
  -- the marker; it is never part of the message content.
  -- The old bracket form is still accepted for existing buffers.
  line = line:gsub("%s*%(context%s+[^%)]*%)%s*$", "")
  line = line:gsub("%s*%[context%s+[^%]]*%]%s*$", "")
  if line == "" then
    return nil
  end

  for _, kind in ipairs(ORDER) do
    local extra = line:match(template_pattern(current[kind]))
    if extra ~= nil then
      return kind, extra
    end
  end

  local name, extra = line:match("^>>([a-z_]+)(.-)%s*$")
  if not name then
    name, extra = line:match("^#([a-z_]+)(.-)%s*$")
  end
  if not name then
    name, extra = line:match("^%[([a-z_]+)(.-)%]%s*$")
  end

  if name and DEFAULTS[name] ~= nil then
    return name, extra
  end
  return nil
end

--- Parse `id=...` and `status=...` attributes from a result marker.
---@param extra? string
---@return number|nil id, string|nil status
function M.parse_result_attrs(extra)
  if not extra or extra == "" then
    return nil, nil
  end
  local id = extra:match("id=(%d+)")
  local status = extra:match("status=([%w_]+)")
  return id and tonumber(id) or nil, status
end

--- Build a Vim regex for syntax highlighting a marker.
---@param kind string
---@return string|nil
function M.vim_pattern(kind)
  local tpl = current[kind]
  if not tpl then
    return nil
  end

  -- Highlight the fixed part of the marker; attributes are not part of it.
  local fixed = tpl:gsub("%%s.*$", ""):gsub("%%s", "")
  local escaped = fixed:gsub("\\", "\\\\"):gsub("/", "\\/")

  if fixed:match("[%w_]$") then
    return "^\\V" .. escaped .. "\\m\\>"
  end
  return "^\\V" .. escaped
end

return M
