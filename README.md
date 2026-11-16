# agentfile.nvim 🪐

> **Single-buffer AI agent workspace for Neovim (>= 0.10)**
> Chat with an AI agent directly in **one file**, with transparent `@tool(...)` tool calling, a YAML frontmatter header for configuration, and `[think]` blocks that fold automatically and are stripped from future context.

---

## ✨ Highlights

- **Single Buffer as Source of Truth**: Header config, chat history (`[system]`, `[me]`, `[agent]`), reasoning (`[think]`), tool calls (`@tool(...)`), and results (`[result]`) all live in one file.
- **Save-to-Send**: Just type under `[me] ...` and hit `:w` to send the prompt or trigger the next reasoning turn.
- **Turn Detection & Reentrancy Guarding**: No accidental duplicate sends when you edit the header or reformat the file.
- **Symmetric Tool Calling**: You and the AI share the same `@tool_name(json_args)` syntax.
- **Codebase Search**: `@grep` and `@glob` find code by content/name; `@list_files` can walk a bounded tree.
- **Heredoc for Multi-line Content**: Pass multi-line code via `<<'EOF' ... EOF` without escaping into a JSON string.
- **`[think]` Reasoning**: Thinking blocks render on the buffer and fold automatically, **but are stripped from the API payload** to keep context lean.
- **Human-in-the-loop**: Approve dangerous tools (`auto_run_tools: false`), reject with feedback to steer the agent immediately.
- **Failure Recovery**: Automatic retry on 429/5xx, stop on consecutive malformed responses, context-budget truncation.
- **Project Memory**: Store distilled lessons in `.agentfile/memory.md` and inject them into the system prompt.
- **Explicit `@done`**: The model declares completion instead of relying on the ambiguous "no tool call" signal.
- **Pluggable Agent Loop**: Swap the planner and executor strategies per chat (see below).

---

## 📦 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "minhnhat97kg/agentfile.nvim",
  event = { "BufReadPre *.agentfile", "BufNewFile *.agentfile", "VeryLazy" },
  cmd = {
    "Agentfile",
    "AgentfileToggle",
    "AgentfileNew",
    "AgentfileSessions",
    "AgentfileDiag",
    "AgentfileGitDiff",
  },
  config = function()
    require("agentfile").setup()
  end
}
```

---

## 🚀 Quick Start

1. Run:
   ```vim
   :Agentfile
   ```
   (Opens `chat.agentfile` with a starter template.)

   The chat buffer uses `filetype=markdown` so markdown renderers work normally; agentfile.nvim attaches its own marker syntax, folding, and keymaps on top.

   The latest `[me]` line shows an estimated context size:
   ```markdown
   [me](context 1234/32768 · step 2/4 · 12s)
   ```
   `context_window` comes from the frontmatter (default `32768`). The left number is a token estimate of the next payload, calibrated with the provider's real count when `include_usage: true` is set. The `(context ...)` suffix is UI-only and never sent to the model.

2. Configure the header at the top of the buffer (optional):
   ```yaml
   ---
   host: http://localhost:9931/v1 # or openrouter, ollama, deepseek...
   model: ggml-org/gemma-4-E2B-it-GGUF:Q8_0 # Gemma 4 (GGUF, Q8_0)
   token: env:OPENAI_API_KEY
   context_window: 32768 # used for [me](context used/limit)
   max_tokens: 2048 # output cap (especially for reasoning models like DeepSeek R1)
   # temperature: 0.6 # 0.5 - 0.7 recommended for small reasoning models
   # top_p: 0.95
   # presence_penalty: 0.2 # reduce reasoning repetition loops
   # thinking:
   #   budget_tokens: 1024 # reasoning token cap (OpenRouter / Anthropic)
   #   concise: true # force concise reasoning (< 150 words)
   #   enabled: false # disable thinking entirely
   #   keep_on_error: false # replay [think] once when a tool just failed
   auto_run_tools: false # false: ask before running system commands
   # retries: 2 # retry on 429/5xx/connection loss
   # retry_delay_ms: 1000
   # include_usage: true # show real token usage (some GGUF servers don't support it)
   # tool_mode: text # text (default) or native (use the API's tool_calls)
   # planner: plan_first # react (default) or plan_first (plan before acting)
   # executor: parallel_reads # sequential (default) or parallel_reads (run read-only tools concurrently)
   # memory:
   #   enabled: true
   #   path: .agentfile/memory.md
   #   max_chars: 1200
   #   require_approval: true
   skills: [read_file, write_file, edit_file, run_command, list_files, grep, glob, symbols, skeleton, done]
   ---
   ```

3. Type your question under the `[me]` tag:
   ```markdown
   [me]
   Check the file `lua/agentfile/init.lua` and run the tests for me:
   @read_file({"path": "lua/agentfile/init.lua"})
   ```

4. Type `:w` (save) ➔ the AI thinks in `[think]` and answers in `[agent]`.

---

## 🛠️ Commands & Keymaps

| Command / Keymap | Description |
|---|---|
| `:Agentfile [file]` | Open or create a `.agentfile` chat buffer |
| `:AgentfileToggle` (`<leader>at`) | Toggle the chat panel in a right-side split |
| `:AgentfileNew [topic]` | Create a new chat session by topic under `.agentfile/` |
| `:AgentfileSessions` | List and open an existing session in the project |
| `:AgentfileBranch [topic]` (`<leader>ab`) | Fork history up to the cursor into a new session |
| `:AgentfileDiag` (`<leader>ad`) | Ingest LSP diagnostics into chat |
| `:AgentfileGitDiff` (`<leader>ag`) | Ingest `git diff` into chat |
| `:AgentfileUndo` (`<leader>au`) | Revert the file modification of the tool under the cursor (via snapshot) |
| `:AgentfileDiff` (`<leader>aD`) | Open a split showing the diff of the tool's modification |
| `:AgentfileSend` (`<leader>as`) | Force-send the current prompt |
| `:AgentfileCancel` (`<leader>ax`) | Cancel the running request / stream |
| `:AgentfileSelection [snippet\|tool]` (`<leader>ac`) | Send the visual selection to chat |
| `:AgentfileContext [files...]` (`<leader>af`) | Add the current file (or files/globs) as context |
| `<leader>aF` | Prompt for a space-separated list of context files |
| `:AgentfileApprove` (`<leader>ay`) | Run the pending tool (equivalent to editing `[ask]` to `y`) |
| `:AgentfileReject [reason]` (`<leader>an`) | Reject the tool with optional feedback for the agent |
| `:AgentfileExport [path]` (`<leader>ae`) | Export the transcript as a JSON trajectory |
| `:AgentfileMemory` (`<leader>am`) | Open (and create if needed) the project memory file |

### UI & status

The chat window gets a lightweight winbar with the live agent state, step budget,
context usage and model name:

```text
 agentfile    ◐ generating   step 2/4   12.4k/32.8k (38%)   gemma-4-E2B
```

- The context percentage turns **yellow at 70%** and **red at 90%**.
- `[think]` and `[result]` folds show a compact summary with status icons
  (`✓` ok, `✗` error, `◌` pending, `⊘` rejected) and a first-line preview.
- Result markers are color-coded by status (`ok`, `error`, `pending`, `rejected`).
- The diff split has a title bar and is tuned for reading unified diffs.

Disable the winbar if you use a winbar plugin, or expose the plain-text status
to your statusline:

```lua
require("agentfile").setup({
  ui = {
    winbar = false,
  },
})

-- e.g. in lualine:
-- sections.lualine_x = { function() return require("agentfile.ui").statusline() end }
```

### Tool approval & agent steering

When a dangerous tool needs approval (`auto_run_tools: false`):
- **Allow** → run the tool, record `[result ... status=ok]`/`status=error`, continue the batch.
- **Deny** or dismiss the prompt → skip, record `[result ... status=rejected]`, stop the batch.
- Reject with guidance: `n: reason` (e.g. `(y/N): n: Don't touch auth.go, edit router.go instead`). The agent receives this feedback in `[result]` and pivots immediately.
- Undo (`<leader>au`): place the cursor on a `[result]` block, then press `<leader>au` to restore the file.

### Agent loop configuration

Each chat's frontmatter supports:

```yaml
agent:
  enabled: true
  max_steps: 4            # max model calls per [me] request
  max_format_errors: 3    # stop after N consecutive malformed responses (0 = unlimited)
  # wall_time_limit: 300  # seconds per request (0 = unlimited)
  # command_timeout: 120  # seconds per @run_command
```

- `enabled` defaults to `true`. Set `false` for plain chat: the plugin renders the reply but does not auto-run model-issued tools.
- `max_steps` is the maximum number of model calls per `[me]` request. Default 4.
- `max_format_errors` is the number of consecutive malformed responses (empty or cut off by `max_tokens`) tolerated before stopping.
- `max_turns` limits the sent history independently. Legacy `max_iterations: N` still maps to `N + 1` calls.
- File-modifying tools (`write_file`, `edit_file`, `run_command`) are limited to **1 call/turn**; only read-only tools may be batched.
- Explicit completion: the model calls `@done({"summary": "..."})` alone as its final step.

### Pluggable loop strategies

The agent loop is decomposed into phases, each with swappable strategies selectable under `agent:`:

| Phase | Strategy | Description |
|---|---|---|
| `planner` | `react` *(default)* | Progress note, thinking controls, and recovery nudges |
| `planner` | `plan_first` | Asks for a short step-by-step plan before acting (Plan-and-Solve) |
| `executor` | `sequential` *(default)* | Runs tools one at a time in order |
| `executor` | `parallel_reads` | Runs read-only tools concurrently, then any file/command tool (ReWOO) |

```yaml
agent:
  planner: plan_first
  executor: parallel_reads
```

Register custom strategies from Lua:

```lua
require("agentfile").register_strategy("planner", "my_planner", function(ctx)
  return "Your custom system-prompt augmentation."
end)
```

### Multi-line content (heredoc)

Instead of stuffing multi-line code into a JSON string, use a heredoc — the body between the markers is passed verbatim:

```markdown
@write_file({"path": "src/main.go"}) <<'EOF'
package main
func main() { println("hi") }
EOF
```

The body becomes `content` (`write_file`), `replacement` (`edit_file`), or `command` (`run_command`). An unquoted delimiter (`<<EOF`) is also accepted. Markers inside the body (`[system]`, `[me]`, ...) are kept literal and do not create chat blocks.

### Tool results

Tool output is wrapped in a ``` ```agentfile-result ``` code fence. Markers inside it are literal data, not chat blocks. When sending to the model, the plugin removes the envelope and keeps the content as the tool-result message.

### Search & command execution

- `@grep({"pattern": "tool_calls", "path": "lua", "glob": "*.lua"})` searches file contents recursively (ripgrep when installed, Lua fallback otherwise).
- `@glob({"pattern": "**/*.lua"})` finds files/directories by name.
- `@list_files({"path": ".", "recursive": true, "max_depth": 2})` walks a small tree.
- `@symbols({"path": "lua", "glob": "*.lua"})` lists top-level functions/classes to map a directory.
- `@skeleton({"path": "lua/agentfile/ui.lua", "focus": "winbar"})` returns a pruned view (imports + signatures + one full body) to save context before editing.
- `@run_command` accepts optional `cwd`, `env`, and `timeout_ms`. Long-running commands stream output into a floating window, and `:AgentfileCancel` kills the process.

Set a default command timeout per chat:

```yaml
agent:
  command_timeout: 120 # seconds
```

### Context budget & failure recovery

- **Budget truncation**: tool output is cut to ~30% of the context window (keeping **head + tail**, with an elided-size note and a hint on how to read less).
- **Explicit envelope**: `@run_command` always returns `<returncode>N</returncode>`, keeping stdout/stderr separate.
- **Automatic retry**: 429/5xx/connection loss retried with exponential backoff; auth/404/bad-URL fail immediately.
- **Malformed response recovery**: `finish_reason=length` or an empty response never runs a (possibly half-written) tool; the model is asked to answer more briefly and retry, capped by `max_format_errors`.
- **Accurate meter**: `[me](context used/limit · step N/M · Ns)` uses real token usage when `include_usage: true` is set.

---

## 🧠 Project Memory

Store **distilled lessons** (not raw `[think]`) in a project memory file and inject them into the system prompt. Replaying a small model's own wrong reasoning makes it defend the mistake instead of fixing it — so only verified lessons are stored.

```yaml
memory:
  enabled: true
  path: .agentfile/memory.md
  max_chars: 1200
  require_approval: true
  remember_rejections: true
  remember_repeated_failures: true
```

Two signals produce a lesson (both require approval by default):
1. **You reject a tool with a reason** (`n: reason` / `:AgentfileReject reason`) — already validated by the human steering the agent.
2. **A tool fails twice with the same normalized cause** in one session.

Lessons are deduplicated, length-limited, and capped by `max_chars` (oldest lines drop first). Edit them with `:AgentfileMemory` or by hand.

---

## 📤 Export Trajectory & Native Tool Calling

- `:AgentfileExport [path]` writes the exact message list (with model, agent config, token usage, step count, `exit_status`) as JSON for debugging, replay, evaluation, and fine-tuning.
- `tool_mode: native` uses the provider's native `tool_calls` interface instead of parsing `@tool(...)` text. Native calls are rendered back into the transcript so the buffer remains the single source of truth.

---

## 🎨 Customizing markers

Default markers: `[system]`, `[me]`, `[think]`, `[agent]`, `[result ...]`, `[ask] ... (y/N): `, `[reset]`, `[error]`, `[done]`.

```lua
require("agentfile").setup({
  markers = {
    system = "SYSTEM:",
    me     = "USER:",
    think  = "THOUGHTS:",
    agent  = "ASSISTANT:",
    result = "<<result%s>>", -- %s = id/status attributes
    ask    = "<<ask>> %s",    -- %s = question; must end with (y/N):
    reset  = "RESET",
    error  = "ERROR:",
  },
})
```

When the model cannot be reached or the API returns an error, the plugin writes an `[error]` block to the buffer followed by an empty `[me]` block so you can retry.

---

## 🧩 Registering custom tools

```lua
require("agentfile").register_tool("git_diff", {
  description = "Get the current git diff",
  parameters = {},
  is_dangerous = false,
  run = function(args, cb)
    local out = vim.fn.system("git diff")
    cb(true, out)
  end
})
```

## 📄 License

MIT
