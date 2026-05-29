# 修复 Claude Code 连接 DeepSeek 报错

```
API Error: 400 Failed to deserialize the JSON body into the target type:
messages[1].role: unknown variant `system`, expected `user` or `assistant`
```

## 快速修复（推荐）

**前提：** 已安装 [ccswitch-deepseek](https://github.com/liuzhengming/ccswitch-deepseek) 代理。

```bash
curl -fsSL https://gist.githubusercontent.com/kajalghosh5334-jpg/124d7bccf28d0ec6d6919e15d0c26eec/raw/fix-claude-deepseek.sh | bash
```

一行命令，自动完成：创建翻译器 → 注入端点 → 改 Claude 配置 → 重启代理 → 冒烟测试。

**从零开始**（没装过代理）：

```bash
git clone https://github.com/liuzhengming/ccswitch-deepseek ~/ccswitch-deepseek
cd ~/ccswitch-deepseek && npm install
echo 'api_key=sk-你的deepseek-key' > .env
curl -fsSL https://gist.githubusercontent.com/kajalghosh5334-jpg/124d7bccf28d0ec6d6919e15d0c26eec/raw/fix-claude-deepseek.sh | bash
```

最后在 `~/.claude/settings.json` 里确认这行（脚本会自动改）：

```json
"ANTHROPIC_BASE_URL": "http://127.0.0.1:11435"
```

重启 Claude Code，完成。

---

## 原因

DeepSeek 的 `/anthropic` 端点（Anthropic Messages API 兼容层）在处理 `system` 字段时，内部转换逻辑把它放到了 `messages[1]` 而不是 `messages[0]`，导致自己的 Chat Completions 后端拒绝这个请求。`deepseek-v4-pro` 模型不接受 `messages` 数组中出现 `system` 角色。

## 前提

- 已部署 [ccswitch-deepseek](https://github.com/yourname/ccswitch-deepseek) 代理
- 使用 Claude Code，配置了 `ANTHROPIC_BASE_URL`

## 一键修复

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_REPO/ccswitch-deepseek/main/fix-claude-deepseek.sh | bash
```

或者本地运行：

```bash
cd ~/ccswitch-deepseek && ./fix-claude-deepseek.sh
```

## 做了什么

1. 创建 `lib/anthropic.js` — Anthropic Messages API ↔ DeepSeek Chat Completions 双向翻译器
2. 在 `index.js` 里注册 `/v1/messages` 端点
3. 把 `~/.claude/settings.json` 里的 `ANTHROPIC_BASE_URL` 从 `https://api.deepseek.com/anthropic` 改为 `http://127.0.0.1:11435`
4. 重启代理并冒烟测试

## 手动步骤

### 1. 创建 `lib/anthropic.js`

```bash
cat > ~/ccswitch-deepseek/lib/anthropic.js << 'EOF'
import log from "./log.js";

function extractText(content) {
  if (typeof content === "string") return content;
  if (!content) return "";
  if (Array.isArray(content)) return content.filter(c => c.type === "text").map(c => c.text ?? "").join("");
  return "";
}

export function anthropicToChat(reqBody) {
  let systemContent = "";
  if (reqBody.system) systemContent = typeof reqBody.system === "string" ? reqBody.system : extractText(reqBody.system);
  const messages = [];
  if (systemContent) messages.push({ role: "user", content: "<system>\n" + systemContent + "\n</system>" });
  for (const msg of reqBody.messages || []) { const c = extractText(msg.content); if (msg.role && c) messages.push({ role: msg.role, content: c }); }
  const stream = reqBody.stream !== false;
  const chatBody = { model: "deepseek-v4-pro", messages, stream, thinking: { type: "disabled" } };
  if (reqBody.max_tokens != null) chatBody.max_tokens = reqBody.max_tokens;
  if (reqBody.temperature != null) chatBody.temperature = reqBody.temperature;
  if (reqBody.top_p != null) chatBody.top_p = reqBody.top_p;
  if (reqBody.stop_sequences) chatBody.stop = reqBody.stop_sequences;
  log.req("anthropic msgs:" + messages.length + " stream:" + stream);
  return { chatBody, stream };
}

export class AnthropicSseTranslator {
  constructor(res) { this.res = res; this.messageId = "msg_" + Math.random().toString(36).slice(2,10); this.model = "deepseek-v4-pro"; this.started = false; this.contentIndex = 0; this.contentStarted = false; this.usage = null; }
  _emit(event, data) { this.res.write("event: " + event + "\ndata: " + JSON.stringify(data) + "\n\n"); }
  _start(it) { if (this.started) return; this.started = true; this._emit("message_start", { type: "message_start", message: { id: this.messageId, type: "message", role: "assistant", content: [], model: this.model, stop_reason: null, stop_sequence: null, usage: { input_tokens: it ?? 0, output_tokens: 0 } } }); }
  feed(chunk) { const d = chunk.choices?.[0]?.delta; if (!d) { if (chunk.usage) this.usage = chunk.usage; return; } if (chunk.usage) this.usage = chunk.usage; if (d.content) { this._start(); if (!this.contentStarted) { this.contentStarted = true; this._emit("content_block_start", { type: "content_block_start", index: this.contentIndex, content_block: { type: "text", text: "" } }); } this._emit("content_block_delta", { type: "content_block_delta", index: this.contentIndex, delta: { type: "text_delta", text: d.content } }); } }
  done() { this._start(); if (this.contentStarted) this._emit("content_block_stop", { type: "content_block_stop", index: this.contentIndex }); const u = this.usage || {}; this._emit("message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: u.completion_tokens ?? 0 } }); this._emit("message_stop", { type: "message_stop" }); if (u.total_tokens) log.toks(u.prompt_tokens, u.completion_tokens, u.total_tokens); log.ok("anthropic SSE done: " + this.messageId); this.res.end(); }
  error(msg) { this._emit("error", { type: "error", error: { type: "api_error", message: msg } }); log.err("anthropic SSE error: " + msg); this.res.end(); }
}

export function anthropicNonStreamResponse(completion) {
  const msg = completion.choices?.[0]?.message, usage = completion.usage;
  return { id: "msg_" + Math.random().toString(36).slice(2,10), type: "message", role: "assistant", content: [{ type: "text", text: msg?.content ?? "" }], model: completion.model, stop_reason: "end_turn", stop_sequence: null, usage: { input_tokens: usage?.prompt_tokens ?? 0, output_tokens: usage?.completion_tokens ?? 0 } };
}
EOF
```

### 2. 修改 `index.js`

在 `import { rememberReasoning ...` 这行**前面**加一行：

```js
import { anthropicToChat, AnthropicSseTranslator, anthropicNonStreamResponse } from "./lib/anthropic.js";
```

在最后的 `res.writeHead(404)` **之前**插入 `/v1/messages` 处理器（完整代码见仓库里的 `fix-claude-deepseek.sh`）。

### 3. 修改 Claude Code 设置

编辑 `~/.claude/settings.json`：

```diff
- "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
+ "ANTHROPIC_BASE_URL": "http://127.0.0.1:11435",
```

### 4. 重启代理

```bash
kill $(lsof -t -i :11435) 2>/dev/null; sleep 1
cd ~/ccswitch-deepseek && node index.js &
```

### 5. 验证

```bash
curl -s http://127.0.0.1:11435/v1/messages \
  -H "Content-Type: application/json" \
  -d '{"model":"test","system":"say OK","messages":[{"role":"user","content":"hi"}],"max_tokens":50,"stream":false}'
# 应返回: {"id":"msg_...","type":"message","role":"assistant","content":[{"type":"text","text":"OK"}],...}
```

## 架构

```
Claude Code (Messages API)     Codex (Responses API)
         │                           │
         ▼                           ▼
┌─────────────────────────────────────────┐
│       ccswitch-deepseek :11435          │
│  /v1/messages           /v1/responses   │
│  anthropic.js           translate.js    │
│       ↘               ↙                │
│      DeepSeek Chat Completions          │
└─────────────────────────────────────────┘
         │
         ▼
  api.deepseek.com/v1/chat/completions
```

## 为什么把 system 转成 user 消息？

`deepseek-v4-pro` 的 Chat Completions 端点直接拒绝 `role: "system"`（报错 `expected 'user' or 'assistant'`），所以用 `<system>...</system>` XML 标签包裹系统指令，以 user 角色发送。模型依然能正确理解这些指令。

## 许可

ISC
