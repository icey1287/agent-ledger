# Agent Desk

MDS5120 数据库项目：AI 多角色对话、资料工具授权、历史价格与用量账目。

- 启动、数据库迁移和测试：[DEVELOPMENT.md](DEVELOPMENT.md)
- 系统架构：[ARCHITECTURE.md](ARCHITECTURE.md)
- ER 图、关系模型、事务及设计讨论：[docs/database-design.md](docs/database-design.md)
- 行为约定：[spec](spec/)
- 建表、样例、业务查询和审计：[db](db/)
- PostgreSQL 集成与回归测试：[backend/tests](backend/tests/)

数据库启动自动补齐约束与索引；迁移不清空旧数据。首次配置按运行说明进行。真实模型需要你自己的服务商 API Key，只写本机 `.env`。

当前范围是执行与用量账目，不含订阅套餐及支付结算；是否保留原选题中的 Subscription 需组内与课程要求确认。测试不依赖真实模型，也不产生 API 费用。
