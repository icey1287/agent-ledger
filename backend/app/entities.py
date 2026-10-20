"""MVP 的实际关系模型；外部调用与价格版本分别留存。"""

from datetime import datetime, timezone
from decimal import Decimal
from uuid import uuid4

from sqlalchemy import (
    JSON,
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


def now():
    return datetime.now(timezone.utc)


def uid():
    return str(uuid4())


class Base(DeclarativeBase):
    pass


class Identity:
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class User(Identity, Base):
    __tablename__ = "users"
    username: Mapped[str] = mapped_column(String(64), unique=True)
    password_hash: Mapped[str] = mapped_column(Text)
    role: Mapped[str] = mapped_column(String(16), default="user")
    __table_args__ = (CheckConstraint("role IN ('user', 'admin')"),)


class Session(Identity, Base):
    __tablename__ = "sessions"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    csrf_token: Mapped[str] = mapped_column(String(64))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Model(Identity, Base):
    __tablename__ = "models"
    name: Mapped[str] = mapped_column(String(200), unique=True)
    display_name: Mapped[str] = mapped_column(String(200))
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)


class Price(Identity, Base):
    __tablename__ = "model_prices"
    model_id: Mapped[str] = mapped_column(ForeignKey("models.id"), index=True)
    version: Mapped[int] = mapped_column(Integer)
    currency: Mapped[str] = mapped_column(String(3), default="USD")
    input_rate: Mapped[Decimal] = mapped_column(Numeric(24, 12))
    output_rate: Mapped[Decimal] = mapped_column(Numeric(24, 12))
    cached_rate: Mapped[Decimal | None] = mapped_column(Numeric(24, 12), nullable=True)
    source_url: Mapped[str] = mapped_column(Text, default="")
    billing_note: Mapped[str] = mapped_column(Text, default="")
    __table_args__ = (
        UniqueConstraint("model_id", "version"),
        CheckConstraint(
            "input_rate >= 0 AND output_rate >= 0 AND (cached_rate IS NULL OR cached_rate >= 0)"
        ),
    )


class Conversation(Identity, Base):
    __tablename__ = "conversations"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    title: Mapped[str] = mapped_column(String(200), default="新对话")
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class Task(Identity, Base):
    __tablename__ = "tasks"
    conversation_id: Mapped[str | None] = mapped_column(
        ForeignKey("conversations.id"), index=True, nullable=True
    )
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    price_id: Mapped[str] = mapped_column(ForeignKey("model_prices.id"))
    title: Mapped[str] = mapped_column(String(200))
    instruction: Mapped[str] = mapped_column(Text)
    budget: Mapped[Decimal] = mapped_column(Numeric(24, 12))
    status: Mapped[str] = mapped_column(String(32), default="pending", index=True)
    result: Mapped[str] = mapped_column(Text, default="")
    reason: Mapped[str] = mapped_column(Text, default="")
    finished_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    __table_args__ = (CheckConstraint("budget > 0"),)


class Material(Identity, Base):
    __tablename__ = "materials"
    task_id: Mapped[str] = mapped_column(ForeignKey("tasks.id"), index=True)
    name: Mapped[str] = mapped_column(Text)
    kind: Mapped[str] = mapped_column(String(16))
    content: Mapped[str] = mapped_column(Text)


class Grant(Identity, Base):
    __tablename__ = "task_tool_grants"
    task_id: Mapped[str] = mapped_column(ForeignKey("tasks.id"), index=True)
    tool: Mapped[str] = mapped_column(String(32))
    expires_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    revoked_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    __table_args__ = (
        UniqueConstraint("task_id", "tool"),
        CheckConstraint("tool IN ('read_material', 'search_materials')"),
    )


class Run(Identity, Base):
    __tablename__ = "agent_runs"
    task_id: Mapped[str] = mapped_column(ForeignKey("tasks.id"), index=True)
    parent_id: Mapped[str | None] = mapped_column(
        ForeignKey("agent_runs.id"), nullable=True
    )
    role: Mapped[str] = mapped_column(String(32))
    status: Mapped[str] = mapped_column(String(32), default="running")
    instruction: Mapped[str] = mapped_column(Text, default="")
    output: Mapped[str] = mapped_column(Text, default="")
    finished_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class ModelCall(Identity, Base):
    __tablename__ = "model_calls"
    run_id: Mapped[str] = mapped_column(ForeignKey("agent_runs.id"), index=True)
    provider_request_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(String(32), default="in_flight")
    usage_status: Mapped[str] = mapped_column(String(16), default="unknown")
    input_tokens: Mapped[int | None] = mapped_column(Integer, nullable=True)
    output_tokens: Mapped[int | None] = mapped_column(Integer, nullable=True)
    cached_tokens: Mapped[int | None] = mapped_column(Integer, nullable=True)
    cost: Mapped[Decimal | None] = mapped_column(Numeric(24, 12), nullable=True)
    raw_usage: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    response_text: Mapped[str] = mapped_column(Text, default="")
    error: Mapped[str] = mapped_column(Text, default="")
    reconciled_by: Mapped[str | None] = mapped_column(
        ForeignKey("users.id"), nullable=True
    )
    evidence: Mapped[str] = mapped_column(Text, default="")
    reconciled_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    finished_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    __table_args__ = (
        CheckConstraint("cost IS NULL OR cost >= 0"),
        CheckConstraint("input_tokens IS NULL OR input_tokens >= 0"),
        CheckConstraint("output_tokens IS NULL OR output_tokens >= 0"),
        CheckConstraint(
            "cached_tokens IS NULL OR (cached_tokens >= 0 AND cached_tokens <= input_tokens)"
        ),
    )


class ToolCall(Identity, Base):
    __tablename__ = "tool_calls"
    run_id: Mapped[str] = mapped_column(ForeignKey("agent_runs.id"), index=True)
    grant_id: Mapped[str | None] = mapped_column(
        ForeignKey("task_tool_grants.id"), nullable=True
    )
    tool: Mapped[str] = mapped_column(String(100))
    arguments: Mapped[dict] = mapped_column(JSON)
    status: Mapped[str] = mapped_column(String(32))
    output: Mapped[str] = mapped_column(Text, default="")
