-- lua/agentfile/tools/patch.lua
-- Apply a unified diff to a file. Supports multiple hunks and a small amount
-- of fuzz (line offset tolerance) so the model's patch does not have to match
-- the file byte-for-byte. Safer than target/replacement for multi-site edits.
local M = {}

local DEFAULT_FUZZ = 3

--- Parse a `@@ -old_start[,old_count] +new_start[,new_count] @@` header.
---@param line string
---@return number|nil old_start, number|nil new_start
local function parse_hunk_header(line)
  local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not os then
    return nil
  end
  return tonumber(os), tonumber(ns)
end

--- Split a diff body into a list of hunks, each a list of ops:
--- { type = "ctx" | "del" | "add", text = string }.
---@param text string
---@return table[] hunks, string|nil err
local function parse_patch(text)
  text = tostring(text):gsub("\r\n", "\n"):gsub("\r", "\n")
  local hunks = {}
  local current = nil

  local raw_lines = vim.split(text, "\n", { plain = true })
  if #raw_lines > 0 and raw_lines[#raw_lines] == "" and text:sub(-1) == "\n" then
    table.remove(raw_lines)
  end

  for _, raw in ipairs(raw_lines) do
    if raw:find("^@@ ") then
      local old_start = parse_hunk_header(raw)
      if not old_start then
        return nil, "Malformed hunk header: " .. raw
      end
      current = { old_start = old_start, ops = {} }
      hunks[#hunks + 1] = current
    elseif current then
      if raw == "" then
        current.ops[#current.ops + 1] = { type = "ctx", text = "" }
      elseif raw:sub(1, 1) == " " then
        current.ops[#current.ops + 1] = { type = "ctx", text = raw:sub(2) }
      elseif raw:sub(1, 1) == "-" then
        current.ops[#current.ops + 1] = { type = "del", text = raw:sub(2) }
      elseif raw:sub(1, 1) == "+" then
        current.ops[#current.ops + 1] = { type = "add", text = raw:sub(2) }
      elseif raw:sub(1, 1) == "\\" then
        -- "\ No newline at end of file" — ignore.
      end
      -- Any other line (diff --git, index, ---, +++) is ignored.
    end
  end

  if #hunks == 0 then
    return nil, "No @@ hunks found in the patch"
  end
  return hunks
end

--- Find `needle` (a list of lines) in `haystack` (1-based line table) starting
--- near 1-based index `near`, allowing up to `fuzz` lines of shift in either
--- direction.
---@return number|nil # 1-based index of the match
local function find_match(haystack, needle, near, fuzz)
  near = math.max(1, math.min(near, #haystack + 1))
  local lo = math.max(1, near - fuzz)
  local hi = math.min(#haystack - #needle + 1, near + fuzz)

  for start = lo, hi do
    local match = true
    for j = 1, #needle do
      if haystack[start + j - 1] ~= needle[j] then
        match = false
        break
      end
    end
    if match then
      return start
    end
  end
  return nil
end

---@param args table # { path, patch|diff, fuzz? }
---@param cb function(success: boolean, result: string)
---@param context? table
function M.apply(args, cb, context)
  local path = args.path
  if type(path) ~= "string" or path == "" then
    return cb(false, "Error: 'path' argument is required for apply_patch")
  end

  local diff = args.patch or args.diff
  if type(diff) ~= "string" or diff == "" then
    return cb(false, "Error: 'patch' argument is required for apply_patch")
  end

  local fuzz = tonumber(args.fuzz) or DEFAULT_FUZZ
  if fuzz < 0 then fuzz = 0 end

  local hunks, perr = parse_patch(diff)
  if not hunks then
    return cb(false, perr)
  end

  local file, ferr = io.open(path, "r")
  if not file then
    return cb(false, "Error: could not read " .. path .. ": " .. tostring(ferr))
  end
  local data = file:read("*a")
  file:close()
  if not data then
    return cb(false, "Error: could not read " .. path)
  end
  local had_trailing_newline = data:sub(-1) == "\n"
  local old = vim.split(data, "\n", { plain = true })
  -- vim.split("a\nb\n") -> {"a","b"}; drop the phantom trailing empty line.
  if #old > 0 and old[#old] == "" and had_trailing_newline then
    table.remove(old)
  end

  local snapshot = require("agentfile.snapshot")
  if context and context.id then
    snapshot.record_before(context.id, path)
  end

  local result = {}
  local old_idx = 1
  local added, removed = 0, 0

  for hi, hunk in ipairs(hunks) do
    local old_side = {}
    for _, op in ipairs(hunk.ops) do
      if op.type ~= "add" then
        old_side[#old_side + 1] = op.text
      end
    end

    local match_start
    if #old_side == 0 then
      match_start = math.max(1, math.min(hunk.old_start, #old + 1))
    else
      match_start = find_match(old, old_side, hunk.old_start, fuzz)
    end

    if not match_start then
      return cb(false, string.format(
        "Error: hunk %d (around line %d) does not match %s. Read the file range first and re-diff.",
        hi, hunk.old_start, path))
    end

    -- Copy the untouched region between the previous cursor and this hunk.
    for i = old_idx, match_start - 1 do
      result[#result + 1] = old[i]
    end

    -- Apply the hunk.
    local cursor = match_start
    for _, op in ipairs(hunk.ops) do
      if op.type == "add" then
        result[#result + 1] = op.text
        added = added + 1
      elseif op.type == "ctx" then
        result[#result + 1] = old[cursor] or op.text
        cursor = cursor + 1
      elseif op.type == "del" then
        removed = removed + 1
        cursor = cursor + 1
      end
    end

    old_idx = cursor
  end

  -- Copy the remaining tail.
  for i = old_idx, #old do
    result[#result + 1] = old[i]
  end

  local output = table.concat(result, "\n")
  if had_trailing_newline and #result > 0 then
    output = output .. "\n"
  end

  local out_file, werr = io.open(path, "w")
  if not out_file then
    return cb(false, "Error: could not write to " .. path .. ": " .. tostring(werr))
  end
  out_file:write(output)
  out_file:close()

  if context and context.id then
    snapshot.record_after(context.id, path)
  end

  cb(true, string.format("Applied patch to %s: %d hunk(s), +%d -%d line(s).", path, #hunks, added, removed))
end

return M
