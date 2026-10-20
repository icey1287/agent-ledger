<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import MarkdownText from "./MarkdownText.vue";
import TurnDetails from "./TurnDetails.vue";
import { api, labels, messageOf, money } from "../api/client";
import type {
  Catalog,
  Conversation,
  ConversationDetail,
  Detail,
} from "../api/client";
const props = defineProps<{ id: string; catalog: Catalog }>();
const emit = defineEmits<{ created: [id: string]; changed: [] }>();
const chat = ref<ConversationDetail | null>(null),
  draft = ref(""),
  files = ref<File[]>([]);
const model = ref(""),
  budget = ref("1"),
  enabledTools = ref(["read_material", "search_materials"]),
  expiry = ref("");
const error = ref(""),
  sending = ref(false),
  settings = ref(false),
  initial = ref(!!props.id);
const scroller = ref<HTMLElement>(),
  upload = ref<HTMLInputElement>(),
  composer = ref<HTMLTextAreaElement>();
const pendingId = ref("");
let timer: ReturnType<typeof setTimeout> | undefined,
  alive = true;
const active = computed(() =>
  chat.value?.turns.find(
    (t) =>
      ["pending", "running"].includes(t.status) ||
      t.calls.some((c) => c.status === "in_flight"),
  ),
);
const selectedModel = computed(() =>
  props.catalog.models.find((m) => m.id === model.value),
);
watch(
  () => props.catalog.models,
  (models) => {
    if (!model.value) model.value = models.find((m) => m.enabled)?.id ?? "";
  },
  { immediate: true },
);
function progress(turn: Detail) {
  const call = turn.calls.find((c) => c.status === "in_flight");
  if (turn.status === "cancelled" && call)
    return "已停止，正在结算已发出的调用…";
  const run = [...turn.runs].reverse().find((r) => r.status === "running");
  return run ? `${labels[run.role]}正在处理…` : "正在准备回复…";
}
async function scrollDown(force = false) {
  const el = scroller.value;
  const follow =
    force || !el || el.scrollHeight - el.scrollTop - el.clientHeight < 120;
  await nextTick();
  if (follow && scroller.value)
    scroller.value.scrollTop = scroller.value.scrollHeight;
}
async function refresh(first = false) {
  if (!props.id || !alive) return;
  try {
    const value = await api<ConversationDetail>(`/conversations/${props.id}`);
    if (!alive) return;
    const el = scroller.value;
    const follow =
      first || !el || el.scrollHeight - el.scrollTop - el.clientHeight < 120;
    chat.value = value;
    initial.value = false;
    if (first && value.turns.length) {
      const last = value.turns[value.turns.length - 1]!;
      model.value =
        props.catalog.models.find((m) => m.name === last.model_id && m.enabled)
          ?.id ?? model.value;
      budget.value = last.budget.includes(".")
        ? last.budget.replace(/0+$/, "").replace(/\.$/, "")
        : last.budget;
    }
    error.value = "";
    if (follow) await scrollDown(true);
  } catch (e) {
    if (alive) error.value = messageOf(e);
  } finally {
    if (alive) {
      initial.value = false;
      timer = setTimeout(() => void refresh(), 2000);
    }
  }
}
async function send() {
  if (!draft.value.trim() || sending.value || active.value || initial.value)
    return;
  sending.value = true;
  error.value = "";
  try {
    let id = props.id || pendingId.value;
    if (!id) {
      id = (await api<Conversation>("/conversations", { method: "POST" })).id;
      pendingId.value = id;
    }
    const body = new FormData();
    body.set("message", draft.value.trim());
    body.set("model_id", model.value);
    body.set("budget", budget.value);
    body.set("tools", JSON.stringify(enabledTools.value));
    if (expiry.value)
      body.set("expires_at", new Date(expiry.value).toISOString());
    files.value.forEach((file) => body.append("files", file));
    await api(`/conversations/${id}/messages`, { method: "POST", body });
    draft.value = "";
    files.value = [];
    if (upload.value) upload.value.value = "";
    if (!props.id) emit("created", id);
    else {
      clearTimeout(timer);
      await refresh();
      await scrollDown(true);
      emit("changed");
    }
    await nextTick();
    composer.value?.focus();
  } catch (e) {
    error.value = messageOf(e);
  } finally {
    sending.value = false;
  }
}
async function stop() {
  if (!active.value) return;
  try {
    await api(`/tasks/${active.value.id}/cancel`, { method: "POST" });
    clearTimeout(timer);
    await refresh();
  } catch (e) {
    error.value = messageOf(e);
  }
}
function attach(event: Event) {
  files.value.push(
    ...Array.from((event.target as HTMLInputElement).files ?? []),
  );
  if (upload.value) upload.value.value = "";
}
function keydown(event: KeyboardEvent) {
  if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    void send();
  }
}
async function changed() {
  clearTimeout(timer);
  await refresh();
}
onMounted(() => {
  if (props.id) void refresh(true);
  else composer.value?.focus();
});
onUnmounted(() => {
  alive = false;
  clearTimeout(timer);
});
</script>
<template>
  <section class="chat-shell">
    <header class="chat-header">
      <div>
        <strong>{{ chat?.title ?? "新对话" }}</strong
        ><small>AI 助手 · 可读取资料、整理摘要和核查内容</small>
      </div>
      <button
        class="text-button"
        @click="settings = !settings"
        :aria-expanded="settings"
      >
        对话设置 ⚙
      </button>
    </header>
    <div ref="scroller" class="chat-scroll">
      <div v-if="initial" class="chat-empty"><p>正在加载对话…</p></div>
      <div v-else-if="!chat?.turns.length" class="chat-empty">
        <span class="welcome-mark">✦</span>
        <p class="eyebrow">AGENT DESK</p>
        <h1>今天想聊点什么？</h1>
        <p>
          直接提问，或附上一份资料。<br />我们可以一起梳理内容，再继续深入。
        </p>
        <div class="suggestions">
          <button
            @click="
              draft = '用一个简单例子解释数据库事务的 ACID。';
              composer?.focus();
            "
          >
            理解一个概念 ↗</button
          ><button
            @click="
              draft = '请总结附件的重点，并检查哪些结论需要进一步核实。';
              upload?.click();
            "
          >
            聊聊一份资料 ↗
          </button>
        </div>
      </div>
      <div v-else class="chat-messages">
        <article v-for="turn in chat.turns" :key="turn.id" class="chat-turn">
          <div class="user-message">
            <div class="user-bubble">{{ turn.instruction }}</div>
            <div v-if="turn.materials.length" class="file-list">
              <span v-for="file in turn.materials" :key="file.id"
                >▤ {{ file.name }}</span
              >
            </div>
          </div>
          <div class="assistant-message">
            <span class="assistant-mark">✦</span>
            <div class="assistant-content">
              <div class="assistant-name">
                Agent Desk <span>{{ turn.model_name }}</span>
              </div>
              <MarkdownText v-if="turn.result" :text="turn.result" />
              <p
                v-else-if="
                  ['pending', 'running'].includes(turn.status) ||
                  turn.calls.some((c) => c.status === 'in_flight')
                "
                class="reply-progress"
                role="status"
              >
                <span class="live-dot"></span>{{ progress(turn) }}
              </p>
              <p
                v-if="turn.reason"
                class="alert"
                :class="
                  turn.status === 'awaiting_usage' ? 'warning' : 'neutral'
                "
              >
                {{ labels[turn.status] }} · {{ turn.reason }}
              </p>
              <div class="reply-meta">
                <span>{{ labels[turn.status] }}</span
                ><span
                  >{{ money(turn.cost) }} USD{{
                    turn.unknown_calls ? "（已知部分）" : ""
                  }}</span
                ><span v-if="turn.unknown_calls">用量待确认</span>
              </div>
              <TurnDetails :turn="turn" @changed="changed" />
            </div>
          </div>
        </article>
      </div>
    </div>
    <div class="composer-dock">
      <p v-if="error" class="alert error" role="alert">{{ error }}</p>
      <p v-if="!catalog.provider_configured" class="alert warning">
        请先在本机 .env 配置模型 API Key。
      </p>
      <form @submit.prevent="send" class="message-composer">
        <div v-if="settings" class="chat-settings">
          <div class="form-grid">
            <label
              >每轮预算（USD）<input
                v-model="budget"
                type="number"
                min="0.000000000001"
                step="any"
                required /></label
            ><label
              >本轮工具授权到期（可选）<input
                v-model="expiry"
                type="datetime-local"
            /></label>
          </div>
          <div class="tools-options">
            <label class="check"
              ><input
                v-model="enabledTools"
                type="checkbox"
                value="read_material"
              />读取本对话附件</label
            ><label class="check"
              ><input
                v-model="enabledTools"
                type="checkbox"
                value="search_materials"
              />检索本对话附件</label
            >
          </div>
          <p class="muted small">
            预算达到后停止后续调用，最后一次调用可能超额。设置仅对下一条消息生效。
          </p>
          <p class="muted small">
            {{ selectedModel?.price.billing_note }} 输入 / 输出：{{
              selectedModel?.price.input_rate
            }}
            / {{ selectedModel?.price.output_rate }} USD / 百万 token。
          </p>
        </div>
        <div v-if="files.length" class="file-list composer-files">
          <span v-for="(file, i) in files" :key="i"
            >▤ {{ file.name }}
            <button
              type="button"
              @click="files.splice(i, 1)"
              :aria-label="`移除 ${file.name}`"
            >
              ×
            </button></span
          >
        </div>
        <textarea
          ref="composer"
          v-model="draft"
          :disabled="sending"
          aria-label="消息"
          placeholder="发消息，或附上 TXT / PDF…"
          rows="2"
          @keydown="keydown"
        />
        <div class="composer-toolbar">
          <div class="composer-controls">
            <button
              type="button"
              class="attach-button"
              @click="upload?.click()"
              aria-label="添加附件"
              title="添加 TXT / PDF"
            >
              ＋</button
            ><input
              ref="upload"
              class="hidden-input"
              type="file"
              accept=".txt,.pdf"
              multiple
              @change="attach"
            /><select v-model="model" aria-label="选择模型">
              <option
                v-for="item in catalog.models.filter((m) => m.enabled)"
                :key="item.id"
                :value="item.id"
              >
                {{ item.display_name }}
              </option>
            </select>
          </div>
          <button
            v-if="active"
            type="button"
            class="secondary"
            @click="stop"
            :disabled="active.status === 'cancelled'"
          >
            {{ active.status === "cancelled" ? "结算中…" : "■ 停止" }}</button
          ><button
            v-else
            type="submit"
            class="primary"
            :disabled="
              sending ||
              initial ||
              !draft.trim() ||
              !model ||
              !catalog.provider_configured
            "
          >
            {{ sending ? "发送中…" : "发送 ↑" }}
          </button>
        </div>
      </form>
      <p class="composer-hint">
        Enter 发送 · Shift + Enter 换行 · 费用按演示费率记录
      </p>
    </div>
  </section>
</template>
