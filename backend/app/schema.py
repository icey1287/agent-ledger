"""MVP 的一次性兼容迁移：保留原任务和账单，将其接入对话。"""

from sqlalchemy import inspect, select
from app.entities import Conversation, Task


def upgrade_conversations(engine, factory):
    # 测试使用独立 schema；显式 DDL 必须遵循同一映射。
    schema = engine.get_execution_options().get("schema_translate_map", {}).get(None)
    with engine.begin() as conn:
        columns = {c["name"] for c in inspect(conn).get_columns("tasks", schema=schema)}
        if "conversation_id" not in columns:
            quote = conn.dialect.identifier_preparer.quote
            prefix = f"{quote(schema)}." if schema else ""
            conn.exec_driver_sql(
                f"ALTER TABLE {prefix}tasks ADD COLUMN conversation_id VARCHAR(36) REFERENCES {prefix}conversations(id)"
            )
            conn.exec_driver_sql(
                f"CREATE INDEX ix_tasks_conversation_id ON {prefix}tasks (conversation_id)"
            )
    with factory.begin() as db:
        for task in db.scalars(select(Task).where(Task.conversation_id.is_(None))):
            conversation = Conversation(
                user_id=task.user_id,
                title=task.title,
                created_at=task.created_at,
                updated_at=task.created_at,
            )
            db.add(conversation)
            db.flush()
            task.conversation_id = conversation.id
