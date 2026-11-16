-- lua/agentfile/client.lua
local M = {}

--- Create a new stream parser object to handle SSE lines and think/agent split
function M.new_stream_parser()
  local self = {
    buffer = "",
    in_think_tag = false,
    failed = false,
    http_code = nil,
    finish_reason = nil,
    usage = nil,
    tool_calls = {},
  }

  function self:feed(chunk, callbacks)
    self.buffer = self.buffer .. chunk

    while true do
      local line_end = self.buffer:find("\n")
      if not line_end then break end

      local line = self.buffer:sub(1, line_end - 1)
      self.buffer = self.buffer:sub(line_end + 1)

      -- Trim carriage return if present
      line = line:gsub("\r$", "")

      if line:match("^data:%s*%[DONE%]") then
        if callbacks.on_done then callbacks.on_done() end
      elseif line:match("^data:%s*") then
        local json_str = line:gsub("^data:%s*", "")
        local ok, data = pcall(vim.json.decode, json_str)
        if ok and type(data) == "table" then
          if data.error and data.error ~= vim.NIL then
            local err_msg = type(data.error) == "table" and (type(data.error.message) == "string" and data.error.message or vim.inspect(data.error)) or tostring(data.error)
            self.failed = true
            if callbacks.on_error then
              callbacks.on_error(err_msg)
            end
            return
          end

          if data.usage and data.usage ~= vim.NIL and type(data.usage) == "table" then
            self.usage = data.usage
            if callbacks.on_usage then
              callbacks.on_usage(data.usage)
            end
          end

          if type(data.choices) == "table" and #data.choices > 0 then
            local choice = data.choices[1]
            if choice.finish_reason and choice.finish_reason ~= vim.NIL then
              self.finish_reason = choice.finish_reason
            end
            local delta = choice.delta
            if type(delta) == "table" then
              -- Native tool calls arrive as incremental deltas keyed by index.
              if type(delta.tool_calls) == "table" then
                for _, tc in ipairs(delta.tool_calls) do
                  if type(tc) == "table" then
                    local idx = (tonumber(tc.index) or 0) + 1
                    local slot = self.tool_calls[idx]
                    if not slot then
                      slot = { id = "", type = "function", ["function"] = { name = "", arguments = "" } }
                      self.tool_calls[idx] = slot
                    end
                    if type(tc.id) == "string" and tc.id ~= "" then
                      slot.id = tc.id
                    end
                    if type(tc["function"]) == "table" then
                      if type(tc["function"].name) == "string" then
                        slot["function"].name = slot["function"].name .. tc["function"].name
                      end
                      if type(tc["function"].arguments) == "string" then
                        slot["function"].arguments = slot["function"].arguments .. tc["function"].arguments
                      end
                    end
                  end
                end
              end

              -- 1. Check reasoning_content (DeepSeek / OpenRouter / vLLM)
              local reasoning = type(delta.reasoning_content) == "string" and delta.reasoning_content
                or (type(delta.reasoning) == "string" and delta.reasoning or nil)
              if reasoning and reasoning ~= "" then
                if callbacks.on_think_chunk then
                  callbacks.on_think_chunk(reasoning)
                end
              end

              -- 2. Check standard content with optional <think> tags
              if type(delta.content) == "string" and delta.content ~= "" then
                local text = delta.content

                while #text > 0 do
                  if not self.in_think_tag then
                    local open_s, open_e = text:find("<think>")
                    if open_s then
                      local before = text:sub(1, open_s - 1)
                      if #before > 0 and callbacks.on_agent_chunk then
                        callbacks.on_agent_chunk(before)
                      end
                      self.in_think_tag = true
                      text = text:sub(open_e + 1)
                    else
                      if callbacks.on_agent_chunk then
                        callbacks.on_agent_chunk(text)
                      end
                      break
                    end
                  else
                    local close_s, close_e = text:find("</think>")
                    if close_s then
                      local think_content = text:sub(1, close_s - 1)
                      if #think_content > 0 and callbacks.on_think_chunk then
                        callbacks.on_think_chunk(think_content)
                      end
                      self.in_think_tag = false
                      text = text:sub(close_e + 1)
                    else
                      if callbacks.on_think_chunk then
                        callbacks.on_think_chunk(text)
                      end
                      break
                    end
                  end
                end
              end
            end
          end
        end
      else
        -- curl's -w HTTP status code (last line of the stream)
        local http_code = line:match("^(%d%d%d)$")
        if http_code then
          self.http_code = tonumber(http_code)
        else
          -- Handle non-SSE raw JSON error from endpoints (e.g. 404 model not found)
          local ok, data = pcall(vim.json.decode, line)
          if ok and type(data) == "table" and data.error and data.error ~= vim.NIL then
            local err_msg = type(data.error) == "table" and (type(data.error.message) == "string" and data.error.message or vim.inspect(data.error)) or tostring(data.error)
            self.failed = true
            if callbacks.on_error then
              callbacks.on_error(err_msg)
            end
            return
          end
        end
      end
    end
  end

  return self
end

--- Build HTTP headers for a request.
---@param config table
---@return string[]
function M.build_headers(config)
  local headers = { "Content-Type: application/json" }

  if config.token and config.token ~= "" then
    table.insert(headers, "Authorization: Bearer " .. config.token)
  end

  -- Stable per-conversation ID required by some gateways (OpenCode Go).
  if config.session and config.session ~= "" then
    table.insert(headers, "x-opencode-session: " .. tostring(config.session))
  end

  -- Identify the client instead of a generic HTTP library.
  table.insert(headers, "User-Agent: " .. tostring(config.user_agent or "agentfile.nvim/0.1"))
  return headers
end

--- Build API request payload for chat completion.
---@param config table
---@param messages table[]
---@return table
function M.build_payload(config, messages)
  local payload = {
    model = config.model or "gpt-4o",
    messages = messages,
    stream = true,
  }
  -- Ask for token usage on the final stream chunk so the context meter can
  -- show real numbers instead of a character/4 estimate. Opt-in: some local
  -- servers (llama.cpp/GGUF) reject unknown `stream_options` fields, so we
  -- default to off and fall back to the character/4 estimate.
  if config.include_usage == true then
    payload.stream_options = { include_usage = true }
  end
  if type(config.tools) == "table" and #config.tools > 0 then
    payload.tools = config.tools
    payload.tool_choice = config.tool_choice or "auto"
  end
  if config.temperature ~= nil then payload.temperature = config.temperature end
  if config.top_p ~= nil then payload.top_p = config.top_p end
  if config.presence_penalty ~= nil then payload.presence_penalty = config.presence_penalty end
  if config.frequency_penalty ~= nil then payload.frequency_penalty = config.frequency_penalty end
  if config.max_tokens ~= nil then payload.max_tokens = config.max_tokens end
  if config.stop ~= nil then payload.stop = config.stop end

  -- Thinking / reasoning controls
  local effort = config.reasoning_effort or (type(config.thinking) == "table" and config.thinking.effort)
  if effort then
    payload.reasoning_effort = effort
    payload.reasoning = payload.reasoning or {}
    payload.reasoning.effort = effort
  end

  local budget = config.thinking_budget
    or (type(config.thinking) == "table" and (config.thinking.budget_tokens or config.thinking.max_tokens))
  if budget then
    payload.thinking = { type = "enabled", budget_tokens = budget }
    payload.reasoning = payload.reasoning or {}
    payload.reasoning.max_tokens = budget
  end

  if config.thinking == false or (type(config.thinking) == "table" and config.thinking.enabled == false) then
    payload.thinking = { type = "disabled" }
    payload.include_reasoning = false
  end

  return payload
end

--- Curl failures that will not get better by retrying (bad URL, SSL cert...).
local NON_RETRYABLE_CURL = { [1] = true, [2] = true, [3] = true, [58] = true, [59] = true, [60] = true, [77] = true }

--- Decide whether a failed request attempt should be retried.
---@param http_code? number
---@param curl_code? number
---@return boolean retryable, string|nil reason
function M.classify_retry(http_code, curl_code)
  if http_code then
    if http_code == 429 or http_code == 529 then
      return true, "provider is rate limited or overloaded (HTTP " .. http_code .. ")"
    end
    if http_code == 500 or http_code == 502 or http_code == 503 or http_code == 504 then
      return true, "transient server error (HTTP " .. http_code .. ")"
    end
    return false, nil
  end
  if curl_code and curl_code ~= 0 then
    if NON_RETRYABLE_CURL[curl_code] then
      return false, nil
    end
    return true, "connection error (curl exit " .. tostring(curl_code) .. ")"
  end
  return false, nil
end

--- Stream chat request using curl.
--- Transient failures (429/5xx/connection) are retried with exponential
--- backoff; auth/404/bad-URL failures fail immediately.
---@param config table # host, model, token, temperature, max_tokens, thinking, retries...
---@param messages table[]
---@param callbacks table # on_think_chunk, on_agent_chunk, on_usage, on_retry, on_complete, on_error
---@return table # cancellable job handle
function M.stream_chat(config, messages, callbacks)
  callbacks = callbacks or {}
  local host = config.host or "https://api.openai.com/v1"
  -- Normalize endpoint URL
  if not host:match("/chat/completions$") then
    host = host:gsub("/+$", "") .. "/chat/completions"
  end

  local body_json = vim.json.encode(M.build_payload(config, messages))
  local max_attempts = 1 + (tonumber(config.retries) or 2)
  local base_delay = tonumber(config.retry_delay_ms) or 1000

  local job = { cancelled = false, current = nil, timer = nil }

  local function stop_timer()
    if job.timer then
      pcall(function()
        job.timer:stop()
        job.timer:close()
      end)
      job.timer = nil
    end
  end

  local function finish_error(message)
    if job.cancelled then return end
    if callbacks.on_error then
      callbacks.on_error(message)
    end
  end

  local function run(attempt)
    if job.cancelled then return end

    local parser_state = M.new_stream_parser()
    local stderr_chunks = {}

    local cmd = {
      "curl",
      "-N", -- no buffer
      "-s", -- silent
      "-S", -- but still show errors
      "--connect-timeout", "10",
      "-X", "POST",
      host,
      "-w", "\n%{http_code}",
    }

    for _, header in ipairs(M.build_headers(config)) do
      table.insert(cmd, "-H")
      table.insert(cmd, header)
    end

    table.insert(cmd, "-d")
    table.insert(cmd, body_json)

    local function retry_or_fail(reason)
      if job.cancelled then return end
      if attempt < max_attempts then
        local delay = math.min(base_delay * (2 ^ (attempt - 1)), 8000)
        if callbacks.on_retry then
          callbacks.on_retry(attempt, delay, reason)
        end
        stop_timer()
        job.timer = vim.defer_fn(function()
          run(attempt + 1)
        end, delay)
      else
        finish_error(reason .. string.format(" (after %d attempts)", attempt))
      end
    end

    local system_fn = vim.system or function(c, o, exit_cb)
      error("Neovim >= 0.10 required for vim.system")
    end

    job.current = system_fn(cmd, {
      stdout = function(err, data)
        if data then
          vim.schedule(function()
            if job.cancelled then return end
            parser_state:feed(data, callbacks)
          end)
        end
      end,
      stderr = function(err, data)
        if data then
          table.insert(stderr_chunks, data)
        end
      end,
    }, function(res)
      vim.schedule(function()
        if job.cancelled then return end

        -- The server already told us what went wrong; on_error was called.
        if parser_state.failed then
          return
        end

        if res.code ~= 0 then
          local details = table.concat(stderr_chunks)
          local msg = "Connection to " .. host .. " failed (curl exit " .. tostring(res.code) .. ")"
          if details ~= "" then
            msg = msg .. ":\n" .. details
          end
          local retryable, reason = M.classify_retry(nil, res.code)
          if retryable then
            retry_or_fail(reason .. ": " .. msg)
          else
            finish_error(msg)
          end
        elseif parser_state.http_code and parser_state.http_code >= 400 then
          local msg = "HTTP " .. tostring(parser_state.http_code) .. " from " .. host
          local retryable = M.classify_retry(parser_state.http_code, nil)
          if retryable then
            retry_or_fail(msg)
          else
            finish_error(msg)
          end
        else
          if callbacks.on_complete then
            callbacks.on_complete({
              finish_reason = parser_state.finish_reason,
              usage = parser_state.usage,
              http_code = parser_state.http_code,
              tool_calls = parser_state.tool_calls,
            })
          end
        end
      end)
    end)
  end

  run(1)

  return {
    kill = function(_, _)
      job.cancelled = true
      stop_timer()
      if job.current then
        pcall(job.current.kill, job.current, 9)
      end
    end,
  }
end

return M
