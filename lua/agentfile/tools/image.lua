-- lua/agentfile/tools/image.lua
local M = {}

local MAX_IMAGE_BYTES = 10 * 1024 * 1024 -- 10MB limit

local MIME_TYPES = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  webp = "image/webp",
  gif = "image/gif",
  svg = "image/svg+xml",
}

--- Get mime type from file path extension.
---@param path string
---@return string|nil
function M.get_mime_type(path)
  local ext = vim.fn.fnamemodify(path, ":e"):lower()
  return MIME_TYPES[ext]
end

--- Inspect and attach an image file into the conversation context.
---@param args table # { path: string, caption?: string }
---@param cb function(success: boolean, result: string)
---@param context? table
function M.send_image(args, cb, context)
  local path = args.path
  if not path or path == "" then
    return cb(false, "Error: 'path' argument is required for send_image")
  end

  local full = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(full) == 0 then
    return cb(false, "Error: image file not found or not readable at " .. path)
  end

  local mime = M.get_mime_type(path)
  if not mime then
    return cb(false, "Error: unsupported image format. Supported formats: PNG, JPG, JPEG, WEBP, GIF, SVG.")
  end

  local size = vim.fn.getfsize(full)
  if size > MAX_IMAGE_BYTES then
    return cb(false, string.format("Error: image size (%d KB) exceeds 10MB limit.", math.floor(size / 1024)))
  end

  local rel_path = vim.fn.fnamemodify(full, ":.")
  local caption_str = args.caption and (" - " .. args.caption) or ""
  local result = string.format('[image path="%s" mime="%s"] Image attached: %s (%d KB)%s',
    rel_path, mime, rel_path, math.max(1, math.floor(size / 1024)), caption_str)

  cb(true, result)
end

return M
