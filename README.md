# Agent Desk

MDS5120 AI Agent Subscription and Task Billing Database System：套餐订阅、AI 多角色对话、资料工具授权、历史价格与用量账目。

- 启动、数据库迁移和测试：[DEVELOPMENT.md](DEVELOPMENT.md)
- 系统架构：[ARCHITECTURE.md](ARCHITECTURE.md)
- ER 图、关系模型、事务及设计讨论：[docs/database-design.md](docs/database-design.md)
- 行为约定：[spec](spec/)
- 建表、样例、业务查询和审计：[db](db/)
- PostgreSQL 集成与回归测试：[backend/tests](backend/tests/)

数据库启动自动补齐约束与索引；迁移不清空旧数据。首次配置按运行说明进行。真实模型需要你自己的服务商 API Key，只写本机 `.env`。

支持 7 天体验 / 30 天标准演示订阅、有效期检查、取消及历史追溯；开通不实际收款，不自动续费，不含真实支付结算。测试不依赖真实模型，也不产生 API 费用。

## 自定义 Agent 团队

在“我的 Agents”维护名称、职责、模型与启用状态；在对话设置选择成员及串行/并行模式。串行按选择顺序接力，并行独立处理后由协调 Agent 汇总。任务固定配置快照，各模型按各自历史价格记账。并行最多同时执行四个成员，共享软预算，在途调用可能共同超额。模型目录仍属于当前配置的一个供应商。
