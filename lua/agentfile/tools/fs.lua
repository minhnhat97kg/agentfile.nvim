-- lua/agentfile/tools/fs.lua
local truncate = require("agentfile.tools.truncate")

local M = {}

function M.read_file(args, cb, context)
  local path = args.path
  if not path or path == "" then
    return cb(false, "Error: 'path' argument is required for read_file")
  end

  local uv = vim.uv or vim.loop
  if context and context.chat_path and context.chat_path ~= "" then
    local function canonical(value)
      return uv.fs_realpath(value) or vim.fn.fnamemodify(value, ":p")
    end
    if canonical(path) == canonical(context.chat_path) then
      return cb(false, "The active chat transcript is already in your conversation context. Do not read it again. "
        .. "Continue with README, module/build files and project source files instead.")
    end
  end
  local stat = uv.fs_stat(path)
  if stat and stat.type == "directory" then
    return cb(false, "Error: " .. path .. " is a directory, not a file. Use @list_files("
      .. vim.json.encode({ path = path }) .. ") and then read its child file paths.")
  end

  local file, err = io.open(path, "r")
  if not file then
    return cb(false, "Error: could not open file " .. path .. " (working directory: "
      .. vim.fn.getcwd() .. "): " .. tostring(err))
  end

  local lines = {}
  local start_l = tonumber(args.start_line) or 1
  local end_l = tonumber(args.end_line) or math.huge
  if start_l < 1 then start_l = 1 end
  if end_l < start_l then end_l = start_l end

  local total_lines = 0
  for line in file:lines() do
    total_lines = total_lines + 1
    if total_lines >= start_l and total_lines <= end_l then
      table.insert(lines, line)
    end
  end
  file:close()

  local budget = truncate.budget(context and context.config)

  if total_lines < start_l then
    return cb(true, string.format(
      "start_line %d is beyond the end of %s (%d lines). Read from line 1 or use @list_files.",
      start_l, path, total_lines
    ))
  end

  local content = table.concat(lines, "\n")
  local notes = {}
  local shown_to = math.min(total_lines, end_l)
  if shown_to < total_lines then
    notes[#notes + 1] = string.format("Showing lines %d-%d of %d.", start_l, shown_to, total_lines)
  end
  if #content > budget then
    notes[#notes + 1] = "The file is longer than the context budget; read a smaller start_line/end_line range."
  end

  content = truncate.text(content, {
    max_chars = budget,
    hint = table.concat(notes, " "),
  })

  if #notes > 0 and #content <= budget then
    content = content .. "\n\n[" .. table.concat(notes, " ") .. "]"
  end

  cb(true, content)
end

function M.write_file(args, cb, context)
  local path = args.path
  local content = args.content or ""
  if not path or path == "" then
    return cb(false, "Error: 'path' argument is required for write_file")
  end

  local snapshot = require("agentfile.snapshot")
  if context and context.id then
    snapshot.record_before(context.id, path)
  end

  local file = io.open(path, "w")
  if not file then
    return cb(false, "Error: could not write to file " .. path)
  end

  file:write(content)
  file:close()

  if context and context.id then
    snapshot.record_after(context.id, path)
  end

  cb(true, "Successfully wrote " .. tostring(#content) .. " bytes to " .. path)
end

function M.edit_file(args, cb, context)
  local path = args.path
  local target = args.target
  local replacement = args.replacement
  if not path or not target or not replacement then
    return cb(false, "Error: 'path', 'target', and 'replacement' are required for edit_file")
  end

  local snapshot = require("agentfile.snapshot")
  if context and context.id then
    snapshot.record_before(context.id, path)
  end

  local file = io.open(path, "r")
  if not file then
    return cb(false, "Error: could not open file " .. path)
  end
  local content = file:read("*all")
  file:close()

  if not content:find(target, 1, true) then
    return cb(false, "Error: target string not found in " .. path
      .. ". Read the file first and copy the exact text, including whitespace.")
  end

  -- Count occurrences so an ambiguous target cannot silently edit the wrong place.
  local count = 0
  local pos = 1
  while true do
    local s = content:find(target, pos, true)
    if not s then break end
    count = count + 1
    pos = s + #target
  end

  local new_content
  if args.replace_all == true then
    if count == 0 then
      return cb(false, "Error: target string not found in " .. path)
    end
    local pattern = target:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    new_content = content:gsub(pattern, function() return replacement end)
  elseif count > 1 then
    local occurrence = tonumber(args.occurrence)
    if not occurrence then
      return cb(false, string.format(
        "Error: target appears %d times in %s. Include more surrounding context to make it unique, "
          .. "pass \"occurrence\": <1..%d>, or use write_file.",
        count, path, count
      ))
    end
    if occurrence < 1 or occurrence > count or occurrence ~= math.floor(occurrence) then
      return cb(false, string.format("Error: occurrence must be an integer between 1 and %d", count))
    end
    local s, e
    local seen = 0
    local p = 1
    while true do
      s, e = content:find(target, p, true)
      if not s then break end
      seen = seen + 1
      if seen == occurrence then break end
      p = e + 1
    end
    new_content = content:sub(1, s - 1) .. replacement .. content:sub(e + 1)
  else
    local s, e = content:find(target, 1, true)
    new_content = content:sub(1, s - 1) .. replacement .. content:sub(e + 1)
  end

  local out_file = io.open(path, "w")
  if not out_file then
    return cb(false, "Error: could not write to file " .. path)
  end
  out_file:write(new_content)
  out_file:close()

  if context and context.id then
    snapshot.record_after(context.id, path)
  end

  cb(true, "Successfully edited " .. path)
end

function M.list_files(args, cb, context)
  local dir = args.path or "."
  if type(dir) ~= "string" or dir == "" then
    return cb(false, "Error: 'path' must be a non-empty directory path")
  end
  dir = vim.fs.normalize(vim.fn.expand(dir))
  if vim.fn.isdirectory(dir) == 0 then
    return cb(false, "Error: could not list directory " .. dir .. ": not a directory")
  end
  local uv = vim.uv or vim.loop
  local recursive = args.recursive == true
  local max_entries = tonumber(args.max_entries) or 500
  if max_entries < 1 then max_entries = 1 end
  local entries = {}

  local ignored = {
    [".git"] = true,
    [".hg"] = true,
    [".svn"] = true,
    [".agentfile"] = true,
    [".venv"] = true,
    ["venv"] = true,
    ["node_modules"] = true,
  }

  if recursive then
    local depth = tonumber(args.max_depth) or 3
    if depth < 1 then depth = 1 end
    local ok, iter, state = pcall(vim.fs.dir, dir, { depth = depth })
    if not ok then
      return cb(false, "Error: could not list directory " .. dir .. ": " .. tostring(iter))
    end
    for name, kind in iter, state do
      local skip = false
      for part in name:gmatch("[^/\\]+") do
        if ignored[part] or part:sub(1, 1) == "." then
          skip = true
          break
        end
      end
      if not skip then
        entries[#entries + 1] = { path = vim.fs.joinpath(dir, name), kind = kind or "unknown" }
      end
    end
  else
    local scan, err = uv.fs_scandir(dir)
    if not scan then
      return cb(false, "Error: could not list directory " .. dir .. ": " .. tostring(err))
    end
    while true do
      local name, kind = uv.fs_scandir_next(scan)
      if not name then break end
      local path = vim.fs.joinpath(dir, name)
      entries[#entries + 1] = { path = path, kind = kind or "unknown" }
    end
  end

  table.sort(entries, function(a, b) return a.path < b.path end)
  local truncated = false
  if #entries > max_entries then
    entries = vim.list_slice(entries, 1, max_entries)
    truncated = true
  end

  local lines = {
    "Directory" .. (recursive and " (recursive)" or "") .. ": " .. dir,
    "Working directory: " .. vim.fn.getcwd(),
    "Use the paths below as-is in tools. Listing a directory does not change the working directory.",
  }
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = "[" .. entry.kind .. "] " .. entry.path
  end
  if #entries == 0 then lines[#lines + 1] = "(empty directory)" end
  if truncated then
    lines[#lines + 1] = string.format("(truncated at %d entries; list a subdirectory instead)", max_entries)
  end
  local text = table.concat(lines, "\n")
  text = truncate.text(text, {
    max_chars = truncate.budget(context and context.config),
    hint = "List a subdirectory instead to see fewer entries.",
  })
  cb(true, text)
end

return M
