# agentfile.nvim 🪐

> **Single-buffer AI agent workspace cho Neovim (>= 0.10)**
> Chat trực tiếp với AI Agent trên **duy nhất một file**, tool calling minh bạch `@tool(...)`, cấu hình ở header frontmatter, và block `[think]` tự động gấp gọn & loại bỏ khỏi context tiếp theo.

---

## ✨ Điểm nổi bật

- **Single Buffer as Source of Truth**: Toàn bộ cấu hình header, lịch sử chat (`[system]`, `[me]`, `[agent]`), suy nghĩ (`[think]`), tool calls (`@tool(...)`), và kết quả (`[result]`) đều nằm trên 1 file duy nhất.
- **Save-to-Send**: Chỉ cần gõ `[me] nội dung...` rồi `:w` để gửi prompt hoặc trigger lượt suy nghĩ tiếp theo.
- **Bảo vệ Turn Detection & Reentrancy**: Không lo gửi trùng lặp khi sửa header hay format file.
- **Symmetric Tool Calling**: Cả bạn lẫn AI đều dùng chung cú pháp `@tool_name(json_args)`.
- **Heredoc cho nội dung đa dòng**: Code nhiều dòng truyền qua `<<'EOF' ... EOF`, không cần escape vào chuỗi JSON.
- **Reasoning `[think]`**: Block suy nghĩ hiển thị trên buffer và fold tự động, **nhưng tự động bị strip khi gửi lên API** để giữ context tinh gọn.
- **Human-in-the-loop**: Duyệt từng tool nguy hiểm (`auto_run_tools: false`), từ chối kèm feedback để Agent đổi hướng ngay.
- **Phục hồi lỗi**: Retry tự động khi 429/5xx, dừng khi model trả lời hỏng liên tiếp, truncation theo budget context.
- **Project Memory**: Lưu các bài học đã chưng cất vào `.agentfile/memory.md` và bơm vào system prompt.
- **Kết thúc tường minh `@done`**: Model chủ động báo hoàn thành thay vì đoán "không gọi tool = xong".

---

## 📦 Cài đặt

Dùng [lazy.nvim](https://github.com/folke/lazy.nvim):

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

## 🚀 Hướng dẫn nhanh

1. Chạy lệnh:
   ```vim
   :Agentfile
   ```
   (Mở file `chat.agentfile` kèm template mẫu có sẵn).

   Buffer chat dùng `filetype=markdown` để plugin render markdown hoạt động bình thường; agentfile.nvim vẫn tự gắn syntax marker, folding và keymaps riêng.

   Dòng `[me]` mới nhất tự hiển thị context size ước lượng:
   ```markdown
   [me](context 1234/32768 · step 2/4 · 12s)
   ```
   `context_window` lấy từ frontmatter (mặc định `32768`). Số bên trái là ước lượng token của payload sắp gửi, được hiệu chỉnh bằng token thật từ API khi bật `include_usage: true`. Phần `(context ...)` chỉ để hiển thị, không gửi cho model.

2. Cấu hình header ở đầu buffer (nếu cần):
   ```yaml
   ---
   host: http://localhost:9931/v1 # hoặc openrouter, ollama, deepseek...
   model: ggml-org/gemma-4-E2B-it-GGUF:Q8_0 # Gemma 4 (GGUF, Q8_0)
   token: env:OPENAI_API_KEY
   context_window: 32768 # dùng để hiển thị [me](context used/limit)
   max_tokens: 2048 # giới hạn output (nhất là với model reasoning như DeepSeek R1)
   # temperature: 0.6 # khuyến nghị 0.5 - 0.7 cho reasoning model nhỏ
   # top_p: 0.95
   # presence_penalty: 0.2 # hạn chế lặp lại suy nghĩ
   # thinking:
   #   budget_tokens: 1024 # giới hạn token suy nghĩ (OpenRouter / Anthropic)
   #   concise: true # ép model suy nghĩ ngắn gọn (< 150 từ)
   #   enabled: false # tắt suy nghĩ hoàn toàn
   #   keep_on_error: false # gửi lại [think] một lần khi tool vừa fail
   auto_run_tools: false # false: hỏi xác nhận trước khi chạy lệnh hệ thống
   # retries: 2 # thử lại khi 429/5xx/mất kết nối
   # retry_delay_ms: 1000
   # include_usage: true # bật để hiển thị token thật (một số server GGUF không hỗ trợ)
   # tool_mode: text # text (mặc định) hoặc native (dùng tool_calls của API)
   # memory:
   #   enabled: true
   #   path: .agentfile/memory.md
   #   max_chars: 1200
   #   require_approval: true
   skills: [read_file, write_file, edit_file, run_command, list_files, done]
   ---
   ```

3. Gõ câu hỏi dưới tag `[me]`:
   ```markdown
   [me]
   Hãy kiểm tra file `lua/agentfile/init.lua` và chạy test giúp tôi:
   @read_file({"path": "lua/agentfile/init.lua"})
   ```

4. Gõ `:w` (lưu file) ➔ AI bắt đầu suy nghĩ trong `[think]` và trả lời trong `[agent]`.

---

## 🛠️ Phím tắt & Lệnh

| Phím tắt / Lệnh | Mô tả |
|---|---|
| `:Agentfile [file]` | Mở hoặc tạo một buffer chat `.agentfile` |
| `:AgentfileToggle` (`<leader>at`) | Bật/tắt panel chat dạng split bên phải |
| `:AgentfileNew [topic]` | Tạo một session chat mới theo topic trong `.agentfile/` |
| `:AgentfileSessions` | Liệt kê và chọn mở các session chat trong dự án |
| `:AgentfileBranch [topic]` (`<leader>ab`) | Fork lịch sử chat từ đầu đến con trỏ sang một session mới |
| `:AgentfileDiag` (`<leader>ad`) | Lấy danh sách lỗi LSP Diagnostics đưa vào chat |
| `:AgentfileGitDiff` (`<leader>ag`) | Lấy `git diff` đưa vào chat |
| `:AgentfileUndo` (`<leader>au`) | Hoàn tác thay đổi file của tool dưới con trỏ (dựa trên snapshot) |
| `:AgentfileDiff` (`<leader>aD`) | Mở split xem trước diff thay đổi file của tool |
| `:AgentfileSend` (`<leader>as`) | Ép gửi prompt hiện tại |
| `:AgentfileCancel` (`<leader>ax`) | Hủy request / stream đang chạy |
| `:AgentfileSelection [snippet\|tool]` (`<leader>ac`) | Gửi vùng chọn ở visual mode vào chat |
| `:AgentfileContext [files...]` (`<leader>af`) | Thêm file hiện tại (hoặc nhiều file/glob) làm context |
| `<leader>aF` | Nhập danh sách file context (cách nhau bởi dấu cách) |
| `:AgentfileApprove` (`<leader>ay`) | Chạy tool đang chờ (tương đương sửa `[ask]` thành `y`) |
| `:AgentfileReject [lý_do]` (`<leader>an`) | Từ chối tool kèm chỉ dẫn feedback cho Agent |
| `:AgentfileExport [path]` (`<leader>ae`) | Xuất transcript ra JSON trajectory |
| `:AgentfileMemory` (`<leader>am`) | Mở (và tạo nếu chưa có) file bộ nhớ dự án |

### Duyệt tool & Điều hướng Agent

Khi tool nguy hiểm cần phê duyệt (`auto_run_tools: false`):
- **Allow** → chạy tool, ghi `[result ... status=ok]`/`status=error`, tiếp tục batch.
- **Deny** hoặc đóng prompt → không chạy, ghi `[result ... status=rejected]`, dừng batch.
- Từ chối kèm chỉ dẫn: `n: lý do` (ví dụ `(y/N): n: Đừng sửa auth.go, hãy sửa router.go`). Agent nhận feedback này trong `[result]` để đổi hướng ngay.
- Hoàn tác (`<leader>au`): đặt con trỏ vào `[result]` rồi nhấn `<leader>au` để phục hồi file.

### Cấu hình agent loop

Frontmatter của từng chat hỗ trợ:

```yaml
agent:
  enabled: true
  max_steps: 4            # số lần gọi model cho mỗi yêu cầu [me]
  max_format_errors: 3    # dừng khi model trả lời hỏng liên tiếp (0 = không giới hạn)
  # wall_time_limit: 300  # giây cho mỗi yêu cầu (0 = không giới hạn)
```

- `enabled` mặc định `true`. Đặt `false` để chat thường: plugin hiển thị câu trả lời nhưng không tự chạy tool do model gọi.
- `max_steps` là số lần gọi model tối đa cho mỗi yêu cầu `[me]`. Mặc định 4.
- `max_format_errors` là số lần model trả lời hỏng liên tiếp (rỗng hoặc bị `max_tokens` cắt) trước khi dừng.
- `max_turns` chỉ giới hạn lịch sử gửi đi. `max_iterations: N` cũ vẫn được hỗ trợ như `N + 1` lần gọi.
- Tool ghi file (`write_file`, `edit_file`, `run_command`) tối đa **1 call/lượt**; chỉ tool read-only mới được batch.
- Kết thúc tường minh: model gọi `@done({"summary": "..."})` một mình ở bước cuối.

### Truyền nội dung đa dòng (heredoc)

Thay vì nhồi code nhiều dòng vào chuỗi JSON, dùng heredoc — nội dung giữa hai marker được truyền nguyên bản:

```markdown
@write_file({"path": "src/main.go"}) <<'EOF'
package main
func main() { println("hi") }
EOF
```

Body thành `content` (`write_file`), `replacement` (`edit_file`) hoặc `command` (`run_command`). Delimiter không quote (`<<EOF`) cũng được chấp nhận. Marker bên trong body (`[system]`, `[me]`...) được giữ nguyên, không tạo block chat.

### Nội dung tool result

Tool output được bọc trong code fence `` ```agentfile-result ``. Marker bên trong là dữ liệu, không tạo block chat. Khi gửi cho model, plugin bỏ lớp bọc và giữ nội dung trong message kết quả tool.

### Giới hạn context & phục hồi lỗi

- **Truncation theo budget**: output tool cắt còn ~30% context window (giữ **đầu + đuôi**, kèm số ký tự bị lược + gợi ý đọc ít hơn).
- **Envelope rõ ràng**: `@run_command` luôn trả `<returncode>N</returncode>` tách bạch stdout/stderr.
- **Retry tự động**: 429/5xx/mất kết nối được thử lại với backoff lũy thừa; 401/404/bad-URL báo lỗi ngay.
- **Phục hồi response hỏng**: `finish_reason=length` hoặc response rỗng → không chạy tool (có thể đang viết dở), nhắc model trả lời ngắn hơn rồi thử lại, có trần `max_format_errors`.
- **Meter chính xác**: `[me](context used/limit · step N/M · Ns)` dùng token thật khi bật `include_usage: true`.

---

## 🧠 Project Memory

Lưu các **bài học đã chưng cất** (không phải suy nghĩ thô `[think]`) vào file bộ nhớ dự án và bơm vào system prompt các lượt sau. Model nhỏ đọc lại lời giải thích sai của chính nó thì bám vào sai lầm thay vì sửa — nên ta chỉ lưu bài học đã được xác nhận.

```yaml
memory:
  enabled: true
  path: .agentfile/memory.md
  max_chars: 1200
  require_approval: true
  remember_rejections: true
  remember_repeated_failures: true
```

Hai nguồn bài học (mặc định đều cần duyệt):
1. **Bạn từ chối tool kèm lý do** (`n: lý do` / `:AgentfileReject lý do`) — tín hiệu đã được con người xác nhận.
2. **Một tool fail 2 lần với cùng nguyên nhân** trong cùng session.

Bài học được dedup, giới hạn độ dài, cắt theo `max_chars` (dòng cũ rơi trước). Sửa bằng `:AgentfileMemory` hoặc trực tiếp.

---

## 📤 Export Trajectory & Native Tool Calling

- `:AgentfileExport [path]` xuất danh sách message (kèm model, agent config, token usage, số bước, `exit_status`) ra JSON để debug, replay, đánh giá và fine-tune.
- `tool_mode: native` dùng giao diện `tool_calls` gốc của API thay vì parse text `@tool(...)`. Call native được ghi ngược vào transcript nên buffer vẫn là nguồn sự thật duy nhất.

---

## 🎨 Tùy biến marker

Marker mặc định: `[system]`, `[me]`, `[think]`, `[agent]`, `[result ...]`, `[ask] ... (y/N): `, `[reset]`, `[error]`, `[done]`.

```lua
require("agentfile").setup({
  markers = {
    system = "SYSTEM:",
    me     = "USER:",
    think  = "THOUGHTS:",
    agent  = "ASSISTANT:",
    result = "<<result%s>>", -- %s = id/status attributes
    ask    = "<<ask>> %s",    -- %s = câu hỏi, phải kết thúc bằng (y/N):
    reset  = "RESET",
    error  = "ERROR:",
  },
})
```

Khi không kết nối được model hoặc API trả lỗi, plugin ghi lỗi vào buffer dưới dạng block `[error]` và thêm `[me]` trống để thử lại.

---

## 🧩 Đăng ký Custom Tool

```lua
require("agentfile").register_tool("git_diff", {
  description = "Lấy git diff hiện tại",
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
