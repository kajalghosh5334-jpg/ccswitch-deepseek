#!/bin/bash
# ============================================================
# fix-claude-deepseek.sh
# 修复 Claude Code 连接 DeepSeek 时的 system message 报错
# 报错: messages[1].role: unknown variant 'system', expected 'user' or 'assistant'
# ============================================================
set -e

# ---------- 配置 ----------
PROXY_DIR="$HOME/ccswitch-deepseek"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# ---------- 1. 创建 lib/anthropic.js ----------
cat > "$PROXY_DIR/lib/anthropic.js" << 'ANTHROPIC_EOF'
// Anthropic Messages API -> DeepSeek Chat Completions 翻译

import log from "./log.js";

function extractText(content) {
  if (typeof content === "string") return content;
  if (!content) return "";
  if (Array.isArray(content)) {
    return content
      .filter(c => c.type === "text")
      .map(c => c.text ?? "")
      .join("");
  }
  return "";
}

export function anthropicToChat(reqBody) {
  let systemContent = "";
  if (reqBody.system) {
    systemContent = typeof reqBody.system === "string"
      ? reqBody.system
      : extractText(reqBody.system);
  }

  const messages = [];
  if (systemContent) {
    messages.push({ role: "user", content: "<system>\n" + systemContent + "\n</system>" });
  }

  for (const msg of reqBody.messages || []) {
    const role = msg.role;
    const content = extractText(msg.content);
    if (role && content) {
      messages.push({ role, content });
    }
  }

  const stream = reqBody.stream !== false;
  const chatBody = {
    model: "deepseek-v4-pro",
    messages,
    stream,
    thinking: { type: "disabled" },
  };

  if (reqBody.max_tokens != null) chatBody.max_tokens = reqBody.max_tokens;
  if (reqBody.temperature != null) chatBody.temperature = reqBody.temperature;
  if (reqBody.top_p != null) chatBody.top_p = reqBody.top_p;
  if (reqBody.stop_sequences) chatBody.stop = reqBody.stop_sequences;

  log.req("anthropic msgs:" + messages.length + " stream:" + stream);
  return { chatBody, stream };
}

export class AnthropicSseTranslator {
  constructor(res) {
    this.res = res;
    this.messageId = "msg_" + Math.random().toString(36).slice(2, 10);
    this.model = "deepseek-v4-pro";
    this.started = false;
    this.contentIndex = 0;
    this.contentStarted = false;
    this.usage = null;
  }

  _emit(event, data) {
    this.res.write("event: " + event + "\ndata: " + JSON.stringify(data) + "\n\n");
  }

  _start(inputTokens) {
    if (this.started) return;
    this.started = true;
    this._emit("message_start", {
      type: "message_start",
      message: {
        id: this.messageId,
        type: "message",
        role: "assistant",
        content: [],
        model: this.model,
        stop_reason: null,
        stop_sequence: null,
        usage: { input_tokens: inputTokens ?? 0, output_tokens: 0 },
      },
    });
  }

  feed(chunk) {
    const delta = chunk.choices?.[0]?.delta;
    if (!delta) {
      if (chunk.usage) this.usage = chunk.usage;
      return;
    }
    if (chunk.usage) this.usage = chunk.usage;

    if (delta.content) {
      this._start();
      if (!this.contentStarted) {
        this.contentStarted = true;
        this._emit("content_block_start", {
          type: "content_block_start",
          index: this.contentIndex,
          content_block: { type: "text", text: "" },
        });
      }
      this._emit("content_block_delta", {
        type: "content_block_delta",
        index: this.contentIndex,
        delta: { type: "text_delta", text: delta.content },
      });
    }
  }

  done() {
    this._start();
    if (this.contentStarted) {
      this._emit("content_block_stop", {
        type: "content_block_stop",
        index: this.contentIndex,
      });
    }
    const usage = this.usage || {};
    this._emit("message_delta", {
      type: "message_delta",
      delta: { stop_reason: "end_turn", stop_sequence: null },
      usage: { output_tokens: usage.completion_tokens ?? 0 },
    });
    this._emit("message_stop", { type: "message_stop" });
    if (usage.total_tokens) log.toks(usage.prompt_tokens, usage.completion_tokens, usage.total_tokens);
    log.ok("anthropic SSE done: " + this.messageId);
    this.res.end();
  }

  error(msg) {
    this._emit("error", { type: "error", error: { type: "api_error", message: msg } });
    log.err("anthropic SSE error: " + msg);
    this.res.end();
  }
}

export function anthropicNonStreamResponse(completion) {
  const msg = completion.choices?.[0]?.message;
  const usage = completion.usage;
  const messageId = "msg_" + Math.random().toString(36).slice(2, 10);

  return {
    id: messageId,
    type: "message",
    role: "assistant",
    content: [{ type: "text", text: msg?.content ?? "" }],
    model: completion.model,
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: {
      input_tokens: usage?.prompt_tokens ?? 0,
      output_tokens: usage?.completion_tokens ?? 0,
    },
  };
}
ANTHROPIC_EOF

echo "✓ lib/anthropic.js 已创建"

# ---------- 2. 修改 index.js ----------
# 2a. 添加 import
IMPORT_LINE='import { anthropicToChat, AnthropicSseTranslator, anthropicNonStreamResponse } from "./lib/anthropic.js";'
if ! grep -q "anthropic.js" "$PROXY_DIR/index.js"; then
  sed -i '' "s|^import { rememberReasoning|${IMPORT_LINE}\nimport { rememberReasoning|" "$PROXY_DIR/index.js"
  echo "✓ index.js import 已添加"
else
  echo "• index.js import 已存在，跳过"
fi

# 2b. 检查是否已有 /v1/messages 端点
if ! grep -q "/v1/messages" "$PROXY_DIR/index.js"; then
  # 在最后的 res.writeHead(404) 之前插入 Anthropic handler
  HANDLER=$(cat << 'HANDLER_EOF'

  // Anthropic Messages API endpoint
  if (req.method === "POST" && (url.pathname === "/v1/messages" || url.pathname === "/messages")) {
    try {
      const raw = await readBody(req); const body = JSON.parse(raw);
      const { chatBody, stream } = anthropicToChat(body);

      const dsReq = https.request({ hostname: "api.deepseek.com", path: "/v1/chat/completions", method: "POST", timeout: 300000, headers: { "Authorization": "Bearer " + DEEPSEEK_API_KEY, "Content-Type": "application/json", Accept: stream ? "text/event-stream" : "application/json" } }, (dsRes) => {
        if (dsRes.statusCode !== 200) { let errBody = ""; dsRes.on("data", c => errBody += c); dsRes.on("end", () => { log.err("DeepSeek " + dsRes.statusCode + ": " + errBody.slice(0,300)); res.writeHead(dsRes.statusCode >= 500 ? 502 : dsRes.statusCode, { "Content-Type": "application/json" }); res.end(JSON.stringify({ type: "error", error: { type: "api_error", message: "DeepSeek " + dsRes.statusCode + ": " + errBody.slice(0,200) } })); }); return; }
        if (!stream) { let data = ""; dsRes.on("data", c => data += c); dsRes.on("end", () => { try { const completion = JSON.parse(data); const response = anthropicNonStreamResponse(completion); if (completion.usage) log.toks(completion.usage.prompt_tokens, completion.usage.completion_tokens, completion.usage.total_tokens); res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify(response)); } catch (e) { log.err("parse: " + e.message); res.writeHead(502); res.end(JSON.stringify({ error: { message: e.message } })); } }); return; }
        res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" }); const translator = new AnthropicSseTranslator(res); let buf = "";
        dsRes.on("data", (chunk) => { buf += chunk.toString(); const ls = buf.split("\n"); buf = ls.pop() ?? ""; for (const line of ls) { if (!line.startsWith("data: ")) continue; const json = line.slice(6).trim(); if (json === "[DONE]") continue; try { translator.feed(JSON.parse(json)); } catch (_) {} } });
        dsRes.on("end", () => { if (buf.trim()) { for (const line of buf.split("\n")) { if (!line.startsWith("data: ")) continue; if (line.slice(6).trim() === "[DONE]") continue; try { translator.feed(JSON.parse(line.slice(6).trim())); } catch (_) {} } } translator.done(); });
        dsRes.on("error", (e) => { log.err("upstream: " + e.message); translator.error(e.message); });
      });
      dsReq.on("error", (e) => { log.err("connect: " + e.message); if (!res.headersSent) { res.writeHead(502); res.end(JSON.stringify({ error: { message: e.message } })); } });
      dsReq.on("timeout", () => { dsReq.destroy(); if (!res.headersSent) { res.writeHead(504); res.end(JSON.stringify({ error: { message: "timeout" } })); } });
      dsReq.write(JSON.stringify(chatBody)); dsReq.end();
    } catch (e) { log.err("parse: " + e.message); if (!res.headersSent) { res.writeHead(400); res.end(JSON.stringify({ error: { message: e.message } })); } }
    return;
  }

HANDLER_EOF
)

  # 在 "res.writeHead(404)" 之前插入
  sed -i '' '/res\.writeHead(404); res\.end/i\
'"$HANDLER_EOF"'' "$PROXY_DIR/index.js" 2>/dev/null || {
    # sed 多行插入在某些系统上有问题，用 node 来做
    node -e "
      const fs = require('fs');
      const path = '$PROXY_DIR/index.js';
      let content = fs.readFileSync(path, 'utf8');
      const marker = '  res.writeHead(404); res.end(JSON.stringify({ error: { message: \"not found: \" + url.pathname } }));';
      const handler = \`$HANDLER_EOF\`;
      content = content.replace(marker, handler + '\n' + marker);
      fs.writeFileSync(path, content);
    "
  }
  echo "✓ /v1/messages 端点已添加"
else
  echo "• /v1/messages 端点已存在，跳过"
fi

# ---------- 3. 修改 Claude Code 设置 ----------
if grep -q "api.deepseek.com/anthropic" "$CLAUDE_SETTINGS" 2>/dev/null; then
  sed -i '' 's|https://api.deepseek.com/anthropic|http://127.0.0.1:11435|g' "$CLAUDE_SETTINGS"
  echo "✓ ANTHROPIC_BASE_URL 已改为 http://127.0.0.1:11435"
else
  echo "• ANTHROPIC_BASE_URL 无需修改或已配置"
fi

# ---------- 4. 重启代理 ----------
echo ""
echo "--- 重启代理 ---"
kill $(lsof -t -i :11435) 2>/dev/null || true
sleep 1
cd "$PROXY_DIR" && node index.js &
sleep 2

# ---------- 5. 验证 ----------
echo ""
echo "--- 验证 /v1/messages ---"
curl -s http://127.0.0.1:11435/v1/messages \
  -H "Content-Type: application/json" \
  -d '{"model":"test","system":"say OK","messages":[{"role":"user","content":"hi"}],"max_tokens":50,"stream":false}' | python3 -m json.tool 2>/dev/null || echo "请手动测试: curl http://127.0.0.1:11435/v1/messages ..."

echo ""
echo "============================================"
echo "  修复完成！"
echo "  代理运行在 http://127.0.0.1:11435"
echo "  Codex:  /v1/responses"
echo "  Claude: /v1/messages"
echo "  现在重启 Claude Code 即可"
echo "============================================"
