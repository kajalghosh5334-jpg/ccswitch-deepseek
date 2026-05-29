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
  // 提取 top-level system
  let systemContent = "";
  if (reqBody.system) {
    systemContent = typeof reqBody.system === "string"
      ? reqBody.system
      : extractText(reqBody.system);
  }

  // 转换 messages
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
    thinking: { type: "enabled" },
  };

  if (reqBody.max_tokens != null) chatBody.max_tokens = reqBody.max_tokens;
  if (reqBody.temperature != null) chatBody.temperature = reqBody.temperature;
  if (reqBody.top_p != null) chatBody.top_p = reqBody.top_p;
  if (reqBody.stop_sequences) chatBody.stop = reqBody.stop_sequences;

  log.req("anthropic msgs:" + messages.length + " stream:" + stream);
  return { chatBody, stream };
}

// Chat Completions SSE -> Anthropic Messages SSE
export class AnthropicSseTranslator {
  constructor(res) {
    this.res = res;
    this.messageId = "msg_" + Math.random().toString(36).slice(2, 10);
    this.model = "deepseek-v4-pro";
    this.started = false;
    this.contentIndex = 0;
    this.thinkingStarted = false;
    this.thinkingIndex = -1;
    this.textStarted = false;
    this.textIndex = -1;
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

    // reasoning_content -> thinking block
    if (delta.reasoning_content) {
      this._start();
      if (!this.thinkingStarted) {
        this.thinkingStarted = true;
        this.thinkingIndex = this.contentIndex++;
        this._emit("content_block_start", {
          type: "content_block_start",
          index: this.thinkingIndex,
          content_block: { type: "thinking", thinking: "" },
        });
      }
      this._emit("content_block_delta", {
        type: "content_block_delta",
        index: this.thinkingIndex,
        delta: { type: "thinking_delta", thinking: delta.reasoning_content },
      });
    }

    // content -> text block
    if (delta.content) {
      this._start();
      if (!this.textStarted) {
        this.textStarted = true;
        this.textIndex = this.contentIndex++;
        this._emit("content_block_start", {
          type: "content_block_start",
          index: this.textIndex,
          content_block: { type: "text", text: "" },
        });
      }
      this._emit("content_block_delta", {
        type: "content_block_delta",
        index: this.textIndex,
        delta: { type: "text_delta", text: delta.content },
      });
    }
  }

  done() {
    this._start();
    if (this.thinkingStarted) {
      this._emit("content_block_stop", {
        type: "content_block_stop",
        index: this.thinkingIndex,
      });
    }
    if (this.textStarted) {
      this._emit("content_block_stop", {
        type: "content_block_stop",
        index: this.textIndex,
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

// 非流式响应转换
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
