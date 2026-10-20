<script setup lang="ts">
import { ref } from "vue";
import { api, messageOf } from "../api/client";
import type { User } from "../api/client";
const emit = defineEmits<{ login: [user: User] }>();
const mode = ref<"login" | "register">("login");
const username = ref(""),
  password = ref(""),
  error = ref(""),
  busy = ref(false);
async function submit() {
  busy.value = true;
  error.value = "";
  try {
    emit(
      "login",
      await api<User>(`/auth/${mode.value}`, {
        method: "POST",
        body: JSON.stringify({
          username: username.value,
          password: password.value,
        }),
      }),
    );
  } catch (e) {
    error.value = messageOf(e);
  } finally {
    busy.value = false;
  }
}
</script>
<template>
  <main class="auth-layout">
    <section class="auth-story">
      <div class="brand">
        <span class="brand-mark">A</span> Agent Desk
        <span class="brand-sub">MDS5120</span>
      </div>
      <p class="eyebrow">连续对话 · 多角色协作</p>
      <h1>从一个问题，<br />开始一段对话。</h1>
      <p class="story-description">
        让协调、摘要与审核 Agent
        协作处理资料，在对话中提问、追问。每一次调用、授权和费用，都有记录可查。
      </p>
      <div class="story-steps">
        <span>01 发送消息</span><span>02 Agent 协作</span
        ><span>03 继续对话</span>
      </div>
    </section>
    <section class="auth-card">
      <p class="eyebrow">欢迎使用</p>
      <h2>{{ mode === "login" ? "登录你的工作台" : "创建账号" }}</h2>
      <p class="muted">
        {{
          mode === "login"
            ? "继续处理你的资料与任务。"
            : "注册后即可创建和管理自己的任务。"
        }}
      </p>
      <form @submit.prevent="submit">
        <label
          >用户名<input
            v-model="username"
            autocomplete="username"
            placeholder="例如 alice"
            required
            minlength="3"
            maxlength="64"
            pattern="[a-zA-Z0-9_.-]+" /></label
        ><label
          >密码<input
            v-model="password"
            type="password"
            :autocomplete="
              mode === 'login' ? 'current-password' : 'new-password'
            "
            placeholder="至少 8 位"
            required
            minlength="8"
        /></label>
        <p v-if="error" class="alert error" role="alert">{{ error }}</p>
        <button class="primary full" :disabled="busy">
          {{ busy ? "处理中…" : mode === "login" ? "登录" : "注册并进入" }}
        </button>
      </form>
      <button
        class="text-button"
        @click="
          mode = mode === 'login' ? 'register' : 'login';
          error = '';
        "
      >
        {{ mode === "login" ? "还没有账号？创建账号" : "已有账号？返回登录" }}
      </button>
      <details class="admin-help">
        <summary>首次配置管理员</summary>
        <p>在 backend 目录运行以下命令，再使用创建的账号登录：</p>
        <code>uv run python -m app.manage create-admin</code>
      </details>
    </section>
  </main>
</template>
