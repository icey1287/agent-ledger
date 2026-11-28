<script setup lang="ts">
import { onMounted, ref } from "vue";
import { api, date, messageOf, money } from "../api/client";
import type { Subscription, Plan } from "../api/client";
const emit = defineEmits<{ changed: []; chat: [] }>();
const plans = ref<Plan[]>([]), history = ref<Subscription[]>([]);
const loading = ref(true), busy = ref(false), error = ref(""), notice = ref("");
const statusNames: Record<string,string> = {active:"有效", cancelled:"已取消", expired:"已到期"};
async function load() {
  [plans.value, history.value] = await Promise.all([api<Plan[]>("/plans"), api<Subscription[]>("/subscriptions")]);
}
async function enroll(plan: Plan) {
  if (busy.value) return;
  busy.value = true; error.value = ""; notice.value = "";
  try {
    await api("/subscriptions", {method:"POST", body:JSON.stringify({plan_id:plan.id})});
    await load(); emit("changed"); notice.value = "订阅已开通，可以开始对话。本次未收取套餐费用。";
  } catch(e) { error.value = messageOf(e); } finally { busy.value = false; }
}
async function cancel(item: Subscription) {
  busy.value = true; error.value = ""; notice.value = "";
  try {
    await api(`/subscriptions/${item.id}/cancel`, {method:"POST"});
    await load(); emit("changed"); notice.value = "订阅已取消，历史对话和已接纳任务保留。";
  } catch(e) { error.value = messageOf(e); } finally { busy.value = false; }
}
onMounted(async()=> {try {await load();} catch(e){error.value=messageOf(e);} finally{loading.value=false;}});
</script>
<template>
  <section class="subscriptions-page">
    <header><h1>套餐与订阅</h1><p>选择使用期限，开始你的 Agent 工作台。</p></header>
    <p class="subscription-note">课程演示：开通不收取真实套餐费用，不自动续费。模型 API 仍消耗服务商账户余额，按用量单独记录，不包含在套餐中。</p>
    <p v-if="error" class="alert error" role="alert">{{error}}</p>
    <p v-if="notice" role="status">{{notice}}</p>
    <p v-if="loading">正在加载订阅…</p>
    <div v-else class="plan-grid">
      <article v-for="plan in plans" :key="plan.id" class="plan-card">
        <h2>{{plan.name}}</h2><p class="plan-price">{{money(plan.display_price)}} {{plan.currency}} <small>展示价</small></p>
        <p>{{plan.duration_days}} 天使用资格 · 不限制任务次数</p>
        <p>支持资料处理、多角色协作和用量追溯。</p>
        <button :disabled="busy || history.some(s=>s.eligible)" @click="enroll(plan)">开通演示订阅</button>
      </article>
    </div>
    <button v-if="history.some(s=>s.eligible)" class="secondary" @click="emit('chat')">返回对话</button>
    <h2>我的订阅记录</h2>
    <p v-if="!loading && !history.length">尚未开通订阅。选择上方套餐即可开始。</p>
    <article v-for="item in history" :key="item.id" class="subscription-record">
      <strong>{{item.plan_name}} · {{statusNames[item.status] || item.status}}</strong>
      <p>{{date(item.starts_at)}} — {{date(item.ends_at)}}</p>
      <p>开通时展示价：{{money(item.display_price)}} {{item.currency}} · 实际套餐收款：无</p>
      <template v-if="item.eligible">
        <p>取消立即停止新任务资格，已接纳的任务继续执行。需要续订时，到期后重新开通即可。</p>
        <button class="secondary" :disabled="busy" @click="cancel(item)">立即取消订阅</button>
      </template>
    </article>
  </section>
</template>
<style scoped>
.subscriptions-page{max-width:960px;margin:0 auto;padding:32px 24px;overflow-y:auto;width:100%;box-sizing:border-box}
.subscription-note{background:#eef4ef;padding:16px;border-radius:12px;line-height:1.7}
.plan-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:20px;margin:24px 0}
.plan-card,.subscription-record{border:1px solid #dce4df;border-radius:16px;padding:22px;margin-bottom:16px;background:white}
.plan-price{font-size:25px;font-weight:600}.plan-price small{font-size:12px;font-weight:400}
p{line-height:1.7}button{min-height:40px}
</style>
