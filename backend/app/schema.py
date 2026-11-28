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


def initialize_database(engine):
    """Apply the same additive migration on fresh and existing databases.

    Migration errors abort startup rather than silently serving with weaker
    constraints. The SQL script is transactional and does not rewrite old data.
    """
    from pathlib import Path

    from app.core.database import sessions
    from app.entities import Base

    Base.metadata.create_all(engine)
    schema = engine.get_execution_options().get("schema_translate_map", {}).get(None)
    migration = Path(__file__).resolve().parents[2] / "db" / "migration.sql"
    with engine.begin() as conn:
        if schema:
            quote = conn.dialect.identifier_preparer.quote
            conn.exec_driver_sql(f"SET LOCAL search_path TO {quote(schema)}")
        # Serialize concurrent migration attempts within this schema/database.
        conn.exec_driver_sql(
            "SELECT pg_advisory_xact_lock(hashtext(current_schema()), 5120)"
        )
        conn.exec_driver_sql(
            migration.with_name("subscriptions.sql").read_text(encoding="utf-8"),
            execution_options={"no_parameters": True},
        )
    with engine.begin() as conn:
        if schema:
            conn.exec_driver_sql(
                f"SET LOCAL search_path TO {conn.dialect.identifier_preparer.quote(schema)}"
            )
        conn.exec_driver_sql(
            "SELECT pg_advisory_xact_lock(hashtext(current_schema()), 5120)"
        )
        conn.exec_driver_sql(
            migration.with_name("agents.sql").read_text(encoding="utf-8"),
            execution_options={"no_parameters": True},
        )
    upgrade_conversations(engine, sessions(engine))
    with engine.begin() as conn:
        if schema:
            conn.exec_driver_sql(
                f"SET LOCAL search_path TO {conn.dialect.identifier_preparer.quote(schema)}"
            )
        conn.exec_driver_sql(
            "SELECT pg_advisory_xact_lock(hashtext(current_schema()), 5120)"
        )
        conn.exec_driver_sql(
            migration.read_text(encoding="utf-8"),
            execution_options={"no_parameters": True},
        )


if __name__ == "__main__":
    from app.core.config import Settings
    from app.core.database import create_database

    engine = create_database(Settings())
    try:
        initialize_database(engine)
        print("Database initialized and constraints upgraded.")
    finally:
        engine.dispose()
