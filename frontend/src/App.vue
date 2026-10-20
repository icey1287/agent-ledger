<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import AuthView from "./components/AuthView.vue";
import ChatView from "./components/ChatView.vue";
import AdminPanel from "./components/AdminPanel.vue";
import { api, messageOf, setSession } from "./api/client";
import type { User, Conversation, Catalog } from "./api/client";
const user = ref<User | null>(null),
  loading = ref(true),
  error = ref("");
const conversations = ref<Conversation[]>([]),
  catalog = ref<Catalog>({ models: [], provider_configured: false });
const page = ref<"chat" | "admin">("chat"),
  selected = ref(""),
  fresh = ref(0),
  mobileMenu = ref(false);
async function reload() {
  try {
    [conversations.value, catalog.value] = await Promise.all([
      api<Conversation[]>("/conversations"),
      api<Catalog>("/models"),
    ]);
    error.value = "";
  } catch (e) {
    error.value = messageOf(e);
  }
}
function select(id: string) {
  selected.value = id;
  page.value = "chat";
  mobileMenu.value = false;
  if (user.value) localStorage.setItem(`agent-chat-${user.value.id}`, id);
}
function newChat() {
  select("");
  fresh.value++;
}
async function loggedIn(value: User) {
  user.value = value;
  setSession(value);
  await reload();
  const saved = localStorage.getItem(`agent-chat-${value.id}`);
  select(conversations.value.some((c) => c.id === saved) ? saved! : "");
}
function expired() {
  user.value = null;
  setSession(null);
  conversations.value = [];
  selected.value = "";
}
async function logout() {
  try {
    await api("/auth/logout", { method: "POST" });
    expired();
  } catch (e) {
    error.value = messageOf(e);
  }
}
async function created(id: string) {
  select(id);
  await reload();
}
onMounted(async () => {
  window.addEventListener("session-expired", expired);
  try {
    await loggedIn(await api<User>("/auth/me"));
  } catch {
    /* 登录页面 */
  } finally {
    loading.value = false;
  }
});
onUnmounted(() => window.removeEventListener("session-expired", expired));
</script>
<template>
  <div v-if="loading" class="boot">正在打开对话…</div>
  <AuthView v-else-if="!user" @login="loggedIn" />
  <div v-else class="workspace chat-workspace">
    <button
      class="mobile-toggle secondary"
      @click="mobileMenu = !mobileMenu"
      :aria-expanded="mobileMenu"
      aria-label="切换对话列表"
    >
      ☰
    </button>
    <aside class="sidebar chat-sidebar" :class="{ 'menu-open': mobileMenu }">
      <div class="brand">
        <span class="brand-mark">A</span
        ><span>Agent Desk<small>MDS5120 · 对话工作台</small></span>
      </div>
      <button class="new-chat" @click="newChat">＋ 新对话</button>
      <p class="sidebar-caption">最近对话</p>
      <nav class="conversation-list" aria-label="历史对话">
        <button
          v-for="chat in conversations"
          :key="chat.id"
          :class="{ selected: page === 'chat' && selected === chat.id }"
          @click="select(chat.id)"
          :title="chat.title"
        >
          {{ chat.title }}
        </button>
        <small v-if="!conversations.length" class="muted"
          >对话会自动保存在这里</small
        >
      </nav>
      <button
        v-if="user.role === 'admin'"
        class="admin-link"
        @click="
          page = 'admin';
          mobileMenu = false;
        "
      >
        ⚙ 模型与费用管理
      </button>
      <div class="sidebar-bottom">
        <div class="avatar">{{ user.username.slice(0, 1).toUpperCase() }}</div>
        <div>
          <strong>{{ user.username }}</strong
          ><small>{{ user.role === "admin" ? "管理员" : "个人空间" }}</small>
        </div>
        <button class="logout" @click="logout" aria-label="退出登录">↪</button>
      </div>
    </aside>
    <main class="main-content" :class="{ 'chat-main': page === 'chat' }">
      <p v-if="error" class="alert error" role="alert">{{ error }}</p>
      <ChatView
        v-if="page === 'chat'"
        :key="selected || `new-${fresh}`"
        :id="selected"
        :catalog="catalog"
        @created="created"
        @changed="reload"
      />
      <AdminPanel v-else-if="user.role === 'admin'" @changed="reload" />
    </main>
  </div>
</template>
