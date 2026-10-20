<script setup lang="ts">
import { onMounted, reactive, ref } from "vue";
import { api, messageOf, money, date } from "../api/client";
import type { Catalog, Model, Unresolved } from "../api/client";
const emit = defineEmits<{ changed: [] }>();
const catalog = ref<Catalog>({ models: [], provider_configured: false }),
  unresolved = ref<Unresolved[]>([]),
  error = ref(""),
  notice = ref(""),
  busy = ref(false),
  editing = ref<string | null>(null),
  formOpen = ref(false),
  reconciling = ref<string | null>(null);
const initial = () => ({
  name: "",
  display_name: "",
  input_rate: "0.50",
  output_rate: "2.00",
  cached_rate: "0.10",
  currency: "USD",
  enabled: true,
  source_url: "",
  billing_note: "演示费率，并非供应商实际扣费。",
});
const form = reactive(initial()),
  correction = reactive({
    input_tokens: 0,
    output_tokens: 0,
    cached_tokens: 0,
    evidence: "",
  });
async function load() {
  try {
    [catalog.value, unresolved.value] = await Promise.all([
      api<Catalog>("/admin/models"),
      api<Unresolved[]>("/admin/unresolved"),
    ]);
  } catch (e) {
    error.value = messageOf(e);
  }
}
function edit(model?: Model) {
  editing.value = model?.id ?? null;
  Object.assign(
    form,
    model
      ? {
          name: model.name,
          display_name: model.display_name,
          enabled: model.enabled,
          input_rate: model.price.input_rate,
          output_rate: model.price.output_rate,
          cached_rate: model.price.cached_rate ?? "",
          currency: model.price.currency ?? "USD",
          source_url: model.price.source_url,
          billing_note: model.price.billing_note,
        }
      : initial(),
  );
  formOpen.value = true;
  notice.value = "";
}
async function save() {
  busy.value = true;
  error.value = "";
  try {
    await api(
      editing.value ? `/admin/models/${editing.value}` : "/admin/models",
      {
        method: editing.value ? "PUT" : "POST",
        body: JSON.stringify({
          ...form,
          cached_rate: form.cached_rate === "" ? null : form.cached_rate,
        }),
      },
    );
    formOpen.value = false;
    notice.value = "模型配置已保存，历史任务价格保持不变。";
    await load();
    emit("changed");
  } catch (e) {
    error.value = messageOf(e);
  } finally {
    busy.value = false;
  }
}
async function reconcile() {
  busy.value = true;
  error.value = "";
  try {
    await api(`/admin/calls/${reconciling.value}/reconcile`, {
      method: "POST",
      body: JSON.stringify(correction),
    });
    reconciling.value = null;
    notice.value = "用量已补录，本次任务不会自动恢复。";
    await load();
  } catch (e) {
    error.value = messageOf(e);
  } finally {
    busy.value = false;
  }
}
onMounted(load);
</script>
<template>
  <section>
    <div class="page-heading">
      <div>
        <p class="eyebrow">管理</p>
        <h1>模型与费用管理</h1>
        <p class="muted">维护可用模型，核实异常用量。</p>
      </div>
      <button class="primary" @click="edit()">＋ 添加模型</button>
    </div>
    <p v-if="error" class="alert error" role="alert">{{ error }}</p>
    <p v-if="notice" class="alert success">{{ notice }}</p>
    <div class="panel connection-info">
      <div>
        <h2>模型提供商</h2>
        <p class="muted">{{ catalog.base_url || "尚未设置 Base URL" }}</p>
      </div>
      <span
        class="badge"
        :class="catalog.provider_configured ? 'completed' : 'awaiting_usage'"
        >{{
          catalog.provider_configured ? "API Key 已配置" : "缺少 API Key"
        }}</span
      >
    </div>
    <p v-if="!catalog.provider_configured" class="alert warning">
      请在项目根目录 .env 填入 MODEL_API_KEY
      并重启后端。密钥不会在页面或任务记录中显示。
    </p>
    <section v-if="formOpen" class="panel">
      <h2>{{ editing ? "编辑模型" : "添加模型" }}</h2>
      <form @submit.prevent="save">
        <div class="form-grid">
          <label
            >模型标识<input
              v-model="form.name"
              :disabled="!!editing"
              required
              placeholder="例如 minimax/minimax-m3.1-flash:free" /></label
          ><label>显示名称<input v-model="form.display_name" required /></label
          ><label
            >输入单价 / 百万 token<input
              v-model="form.input_rate"
              type="number"
              min="0"
              step="any"
              required /></label
          ><label
            >输出单价 / 百万 token<input
              v-model="form.output_rate"
              type="number"
              min="0"
              step="any"
              required /></label
          ><label
            >缓存输入单价 / 百万 token<input
              v-model="form.cached_rate"
              type="number"
              min="0"
              step="any"
              placeholder="未知可留空" /></label
          ><label
            >币种<input
              v-model="form.currency"
              required
              pattern="[A-Z]{3}"
              maxlength="3"
          /></label>
        </div>
        <label>价格说明<input v-model="form.billing_note" /></label
        ><label
          >价格来源（可留空）<input
            v-model="form.source_url"
            type="url" /></label
        ><label class="check"
          ><input
            v-model="form.enabled"
            type="checkbox"
          />允许用户选择此模型</label
        >
        <div class="button-row">
          <button class="primary" :disabled="busy">保存配置</button
          ><button type="button" class="secondary" @click="formOpen = false">
            取消
          </button>
        </div>
      </form>
    </section>
    <section class="panel">
      <h2>模型目录</h2>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>模型</th>
              <th>输入 / 输出单价</th>
              <th>版本</th>
              <th>状态</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="model in catalog.models" :key="model.id">
              <td>
                <strong>{{ model.display_name }}</strong>
                <p class="small muted">{{ model.name }}</p>
                <p class="small muted">{{ model.price.billing_note }}</p>
              </td>
              <td>
                {{ money(model.price.input_rate) }} /
                {{ money(model.price.output_rate) }} {{ model.price.currency }}
                <p class="small muted">每百万 token</p>
              </td>
              <td>v{{ model.price.version }}</td>
              <td>{{ model.enabled ? "启用" : "停用" }}</td>
              <td>
                <button class="text-button" @click="edit(model)">编辑</button>
              </td>
            </tr>
            <tr v-if="!catalog.models.length">
              <td colspan="5" class="muted">暂无模型</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    <section class="panel">
      <div class="section-heading">
        <h2>
          待核实用量 <span class="count">{{ unresolved.length }}</span>
        </h2>
        <button class="text-button" @click="load">刷新</button>
      </div>
      <p v-if="!unresolved.length" class="muted">当前没有需要补录的调用。</p>
      <article v-for="call in unresolved" :key="call.id" class="unresolved">
        <div class="section-heading">
          <div>
            <strong>{{ call.title }}</strong>
            <p class="muted small">
              {{ call.username }} · {{ date(call.created_at) }}
            </p>
          </div>
          <button
            class="secondary"
            @click="
              reconciling = call.id;
              Object.assign(correction, {
                input_tokens: 0,
                output_tokens: 0,
                cached_tokens: 0,
                evidence: '',
              });
            "
          >
            补录用量
          </button>
        </div>
        <p class="small error-text">{{ call.error }}</p>
        <p class="small muted">
          供应商请求 ID：{{ call.provider_request_id ?? "未返回" }}
        </p>
        <details v-if="call.raw_usage">
          <summary>已返回的原始用量</summary>
          <pre>{{ JSON.stringify(call.raw_usage, null, 2) }}</pre>
        </details>
        <form v-if="reconciling === call.id" @submit.prevent="reconcile">
          <div class="form-grid">
            <label
              >输入 token<input
                v-model.number="correction.input_tokens"
                type="number"
                min="0"
                step="1"
                required /></label
            ><label
              >输出 token<input
                v-model.number="correction.output_tokens"
                type="number"
                min="0"
                step="1"
                required /></label
            ><label
              >缓存输入 token<input
                v-model.number="correction.cached_tokens"
                type="number"
                min="0"
                step="1"
                required
            /></label>
          </div>
          <label
            >核实依据<textarea
              v-model="correction.evidence"
              required
              rows="2"
              placeholder="例如供应商请求记录中的用量，必须有依据，不能把未知用量直接当作零。"
            />
          </label>
          <div class="button-row">
            <button class="primary" :disabled="busy">确认补录</button
            ><button
              type="button"
              class="secondary"
              @click="reconciling = null"
            >
              取消
            </button>
          </div>
        </form>
      </article>
    </section>
  </section>
</template>
