<script setup lang="ts">
import { ref } from "vue";
import { api, messageOf } from "../api/client";
import type { Agent, Catalog } from "../api/client";
const props = defineProps<{ agents: Agent[]; catalog: Catalog }>();
const emit = defineEmits<{ changed: [] }>();
const editing = ref(""), name = ref(""), instruction = ref(""), model = ref(""), enabled = ref(true);
const busy = ref(false), error = ref("");
function edit(agent?: Agent) {
  editing.value = agent?.id ?? ""; name.value = agent?.name ?? "";
  instruction.value = agent?.instruction ?? "";
  model.value = agent?.model_id ?? props.catalog.models.find(m => m.enabled)?.id ?? "";
  enabled.value = agent?.enabled ?? true;
}
async function save() {
  busy.value = true; error.value = "";
  try {
    await api(`/agents${editing.value ? '/' + editing.value : ''}`, { method: editing.value ? 'PUT' : 'POST', body: JSON.stringify({ name: name.value, instruction: instruction.value, model_id: model.value, enabled: enabled.value }) });
    edit(); emit('changed');
  } catch(e) { error.value = messageOf(e); }
  finally { busy.value = false; }
}
edit();
</script>
<template>
  <section class="agents-page">
    <p class="eyebrow">YOUR TEAM</p><h1>我的 Agents</h1>
    <p class="muted">为每个成员设置职责与模型。在对话设置中选择本轮团队，串行接力或并行处理后，由协调 Agent 汇总。</p>
    <div class="agent-layout">
      <div class="agent-list">
        <article v-for="agent in agents" :key="agent.id" class="agent-card">
          <div><strong>{{ agent.name }}</strong><span class="badge">{{ agent.enabled ? '已启用' : '已停用' }}</span></div>
          <small>{{ catalog.models.find(m => m.id === agent.model_id)?.display_name ?? '模型已停用' }}</small>
          <p>{{ agent.instruction }}</p><button class="secondary" @click="edit(agent)">编辑 {{ agent.name }}</button>
        </article>
        <p v-if="!agents.length" class="muted">还没有自定义 Agent。先创建一个，例如“数据分析师”或“事实核查员”。</p>
      </div>
      <form class="agent-card agent-form" @submit.prevent="save">
        <h2>{{ editing ? '编辑 Agent' : '创建 Agent' }}</h2>
        <p v-if="error" class="alert error" role="alert">{{ error }}</p>
        <label>名称<input v-model="name" maxlength="100" required placeholder="例如：数据分析师" /></label>
        <label>职责与工作要求<textarea v-model="instruction" rows="5" required placeholder="这个 Agent 负责什么？输出应包含哪些内容？" /></label>
        <label>使用模型<select v-model="model" required><option value="" disabled>选择模型</option><option v-for="item in catalog.models" :key="item.id" :value="item.id" :disabled="!item.enabled">{{ item.display_name }}</option></select></label>
        <label class="check"><input v-model="enabled" type="checkbox" />启用，允许新任务选择</label>
        <p class="muted small">修改只影响后续任务，历史执行保留原职责、模型和价格。</p>
        <div><button class="primary" :disabled="busy">{{ busy ? '保存中…' : '保存 Agent' }}</button> <button v-if="editing" type="button" class="secondary" @click="edit()">改为新建</button></div>
      </form>
    </div>
  </section>
</template>
<style scoped>
.agents-page { max-width: 1100px; margin: auto; padding: 32px; }
.agent-layout { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; margin-top: 24px; align-items: start; }
.agent-list { display: grid; gap: 16px; }
.agent-card { border: 1px solid #dce4e0; border-radius: 14px; padding: 22px; background: #fff; overflow-wrap: anywhere; }
.agent-card p { white-space: pre-wrap; }
.agent-card small { display: block; margin-top: 8px; }
.agent-form { display: grid; gap: 16px; }
.agent-form label { display: grid; gap: 6px; }
.agent-form .check { display: flex; }
@media(max-width: 800px) { .agent-layout { grid-template-columns: 1fr; } .agents-page { padding: 20px; } }
</style>
