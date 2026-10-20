export interface User {
  id: string;
  username: string;
  role: "user" | "admin";
  csrf_token: string;
}
export interface Price {
  id?: string;
  version: number;
  currency?: string;
  input_rate: string;
  output_rate: string;
  cached_rate: string | null;
  source_url: string;
  billing_note: string;
}
export interface Model {
  id: string;
  name: string;
  display_name: string;
  enabled: boolean;
  price: Price;
}
export interface Catalog {
  models: Model[];
  provider_configured: boolean;
  base_url?: string;
}
export interface Task {
  id: string;
  title: string;
  status: string;
  reason: string;
  budget: string;
  cost: string;
  currency: string;
  unknown_calls: number;
  input_tokens: number;
  output_tokens: number;
  model_name: string;
  model_id: string;
  price: Price;
  created_at: string;
  finished_at: string | null;
}
export interface Grant {
  tool: string;
  active: boolean;
  expires_at: string | null;
  revoked_at: string | null;
}
export interface Run {
  id: string;
  role: string;
  status: string;
  instruction: string;
  output: string;
  created_at: string;
}
export interface Call {
  id: string;
  role: string;
  status: string;
  usage_status: string;
  input_tokens: number | null;
  output_tokens: number | null;
  cached_tokens: number | null;
  cost: string | null;
  error: string;
  created_at: string;
  provider_request_id: string | null;
  evidence: string;
}
export interface ToolCall {
  id: string;
  tool: string;
  role: string;
  status: string;
  arguments: Record<string, unknown>;
  output: string;
  created_at: string;
}
export interface Detail extends Task {
  instruction: string;
  result: string;
  materials: { id: string; name: string; kind: string; characters: number }[];
  grants: Grant[];
  runs: Run[];
  calls: Call[];
  tool_calls: ToolCall[];
}
export interface Unresolved {
  id: string;
  task_id: string;
  title: string;
  username: string;
  error: string;
  provider_request_id: string | null;
  raw_usage: unknown;
  created_at: string;
}
let csrf = "";
export function setSession(user: User | null) {
  csrf = user?.csrf_token ?? "";
}
export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
  }
}
export async function api<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const headers = new Headers(options.headers);
  if (options.body && !(options.body instanceof FormData))
    headers.set("Content-Type", "application/json");
  if (options.method && !["GET", "HEAD"].includes(options.method))
    headers.set("X-CSRF-Token", csrf);
  let response: Response;
  try {
    response = await fetch(`/api${path}`, {
      ...options,
      headers,
      credentials: "same-origin",
    });
  } catch {
    throw new ApiError("无法连接服务，请稍后重试。", 0);
  }
  if (response.status === 204) return undefined as T;
  const body = await response.json().catch(() => null);
  if (!response.ok) {
    const detail = body?.detail;
    const message =
      typeof detail === "string"
        ? detail
        : Array.isArray(detail)
          ? detail.map((v: { msg: string }) => v.msg).join("；")
          : "请求失败，请稍后重试";
    if (response.status === 401)
      window.dispatchEvent(new Event("session-expired"));
    throw new ApiError(message, response.status);
  }
  return body as T;
}
export const messageOf = (error: unknown) =>
  error instanceof Error ? error.message : "操作失败，请重试";
export const money = (value: string | null | undefined) =>
  value == null
    ? "待核实"
    : Number(value).toLocaleString("en-US", {
        minimumFractionDigits: 2,
        maximumFractionDigits: 8,
      });
export const date = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });
export const labels: Record<string, string> = {
  pending: "等待执行",
  running: "执行中",
  completed: "已完成",
  cancelled: "已停止",
  failed: "失败",
  interrupted: "已中断",
  awaiting_usage: "用量待核实",
  stopped_budget: "达到预算",
  stopped_permission: "授权失效",
  coordinator: "协调 Agent",
  summary: "摘要 Agent",
  review: "审核 Agent",
  read_material: "读取资料",
  search_materials: "检索资料",
  delegate_summary: "委派摘要",
  delegate_review: "委派审核",
  succeeded: "成功",
  in_flight: "调用中",
  usage_unknown: "用量待核实",
  reconciled: "已补录",
  denied: "拒绝",
  stopped: "已停止",
};

export interface Conversation {
  id: string;
  title: string;
  updated_at: string;
}
export interface ConversationDetail extends Conversation {
  turns: Detail[];
}
