<script setup lang="ts">
import { ref } from "vue";
import MarkdownText from "./MarkdownText.vue";
import { api, date, labels, messageOf, money } from "../api/client";
import type { Detail, Grant } from "../api/client";
const props = defineProps<{ turn: Detail }>();
const emit = defineEmits<{ changed: [] }>();
const error = ref(""),
  busy = ref(false);
async function revoke(grant: Grant) {
  busy.value = true;
  try {
    await api(`/tasks/${props.turn.id}/grants/${grant.tool}`, {
      method: "PUT",
      body: JSON.stringify({ enabled: false }),
    });
    error.value = "";
    emit("changed");
  } catch (e) {
    error.value = messageOf(e);
  } finally {
    busy.value = false;
  }
}
</script>
<template>
  <details class="turn-details">
    <summary>
      执行过程与用量
      <span
        >{{ turn.calls.length }} 次调用 ·
        {{ (turn.input_tokens + turn.output_tokens).toLocaleString() }} 已知
        token</span
      >
    </summary>
    <p class="muted small">
      {{ date(turn.created_at) }} · 本轮预算 {{ money(turn.budget) }} USD ·
      价格版本 {{ turn.price.version }}<br />{{
        turn.price.billing_note
      }}
      最后一次调用可能超额。
    </p>
    <p v-if="error" class="alert error">{{ error }}</p>
    <div v-for="grant in turn.grants" :key="grant.tool" class="grant-row">
      <span
        >{{ labels[grant.tool] }} · {{ grant.active ? "已授权" : "未生效"
        }}<small v-if="grant.expires_at">
          · 到期 {{ date(grant.expires_at) }}</small
        ></span
      ><button
        v-if="grant.active && ['pending', 'running'].includes(turn.status)"
        class="text-button danger"
        @click="revoke(grant)"
        :disabled="busy"
      >
        撤销
      </button>
    </div>
    <details v-for="run in turn.runs" :key="run.id" class="run">
      <summary>
        <span class="run-dot" :class="run.role"></span>{{ labels[run.role]
        }}<span class="badge" :class="run.status">{{
          labels[run.status] ?? run.status
        }}</span>
      </summary>
      <MarkdownText v-if="run.output" :text="run.output" />
    </details>
    <div v-for="tool in turn.tool_calls" :key="tool.id" class="tool-event">
      ↳ {{ labels[tool.tool] ?? tool.tool }} ·
      {{ labels[tool.status] ?? tool.status }}
    </div>
    <div v-if="turn.calls.length" class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>角色</th>
            <th>输入 / 输出 / 缓存</th>
            <th>USD</th>
            <th>状态</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="call in turn.calls" :key="call.id">
            <td>{{ labels[call.role] }}</td>
            <td>
              {{ call.input_tokens ?? "未知" }} /
              {{ call.output_tokens ?? "未知" }} /
              {{ call.cached_tokens ?? "未知" }}
            </td>
            <td>{{ money(call.cost) }}</td>
            <td>
              {{ labels[call.status] ?? call.status }}
              <p v-if="call.error">{{ call.error }}</p>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </details>
</template>
