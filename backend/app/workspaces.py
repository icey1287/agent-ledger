"""任务入口、权限编辑和结果查询；执行调度集中在 execution 模块。"""

import json
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Annotated

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from pydantic import BaseModel
from sqlalchemy import select

from app.auth import current_user, db_session
from app.catalog import latest_price
from app.entities import (
    Conversation,
    Grant,
    Material,
    Model,
    ModelCall,
    Price,
    Run,
    Task,
    ToolCall,
    now,
)
from app.materials import extract

router = APIRouter(prefix="/api/tasks", tags=["tasks"])
TOOLS = ("read_material", "search_materials")
ACTIVE = {"pending", "running"}


def own_task(db, task_id, user_id, lock=False):
    stmt = select(Task).where(Task.id == task_id, Task.user_id == user_id)
    task = db.scalar(stmt.with_for_update() if lock else stmt)
    if task is None:
        raise HTTPException(404, "任务不存在")
    return task


def calls_for(db, task_id):
    return db.scalars(
        select(ModelCall)
        .join(Run, Run.id == ModelCall.run_id)
        .where(Run.task_id == task_id)
        .order_by(ModelCall.created_at)
    ).all()


def task_summary(db, task):
    price = db.get(Price, task.price_id)
    model = db.get(Model, price.model_id)
    calls = calls_for(db, task.id)
    total = sum((c.cost for c in calls if c.cost is not None), Decimal(0))
    return {
        "id": task.id,
        "title": task.title,
        "status": task.status,
        "reason": task.reason,
        "budget": str(task.budget),
        "cost": str(total),
        "currency": price.currency,
        "unknown_calls": sum(c.usage_status == "unknown" for c in calls),
        "input_tokens": sum(c.input_tokens or 0 for c in calls),
        "output_tokens": sum(c.output_tokens or 0 for c in calls),
        "model_name": model.display_name,
        "model_id": model.name,
        "price": {
            "version": price.version,
            "input_rate": str(price.input_rate),
            "output_rate": str(price.output_rate),
            "cached_rate": str(price.cached_rate)
            if price.cached_rate is not None
            else None,
            "source_url": price.source_url,
            "billing_note": price.billing_note,
        },
        "created_at": task.created_at,
        "finished_at": task.finished_at,
    }


@router.get("")
def list_tasks(user=Depends(current_user), db=Depends(db_session)):
    return [
        task_summary(db, t)
        for t in db.scalars(
            select(Task).where(Task.user_id == user.id).order_by(Task.created_at.desc())
        )
    ]


@router.post("", status_code=201)
def create_task(
    request: Request,
    model_id: Annotated[str, Form()],
    budget: Annotated[str, Form()],
    title: Annotated[str, Form()] = "资料摘要",
    instruction: Annotated[
        str, Form()
    ] = "请整理资料，撰写准确的摘要，并审核关键事实。",
    text: Annotated[str, Form()] = "",
    tools: Annotated[str, Form()] = '["read_material", "search_materials"]',
    expires_at: Annotated[str, Form()] = "",
    files: list[UploadFile] = File(default=[]),
    user=Depends(current_user),
    db=Depends(db_session),
    conversation_id: Annotated[str | None, Form()] = None,
):
    if not request.app.state.provider.configured:
        raise HTTPException(409, "尚未配置模型 API Key，请先完成提供商配置")
    try:
        amount = Decimal(budget)
        if (
            not amount.is_finite()
            or amount <= 0
            or amount >= Decimal("1e12")
            or amount != amount.quantize(Decimal("1e-12"))
        ):
            raise ValueError
        selected = json.loads(tools)
        if not isinstance(selected, list) or any(t not in TOOLS for t in selected):
            raise ValueError
        expiry = (
            datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
            if expires_at
            else None
        )
        if expiry is not None and (expiry.tzinfo is None or expiry <= now()):
            raise ValueError
    except (InvalidOperation, ValueError, TypeError):
        raise HTTPException(
            422, "预算须为正数，工具须来自白名单，授权到期时间须为未来时间"
        ) from None
    title, instruction = title.strip(), instruction.strip()
    if not title or len(title) > 200 or not instruction:
        raise HTTPException(422, "请填写任务名称（不超过 200 字）和任务要求")
    materials = (
        [{"name": "粘贴资料", "kind": "text", "content": text}] if text.strip() else []
    )
    for file in files:
        materials.append(extract(file.filename or "upload", file.file.read()))
    conversation = None
    if conversation_id:
        conversation = own_conversation(db, conversation_id, user.id, lock=True)
        active = db.scalar(
            select(Task.id).where(
                Task.conversation_id == conversation.id, Task.status.in_(ACTIVE)
            )
        )
        unsettled = db.scalar(
            select(ModelCall.id)
            .join(Run)
            .join(Task)
            .where(
                Task.conversation_id == conversation.id, ModelCall.status == "in_flight"
            )
        )
        if active or unsettled:
            raise HTTPException(409, "上一条回复仍在执行或结算，请稍后再发送")
    model = db.get(Model, model_id)
    if model is None or not model.enabled:
        raise HTTPException(422, "所选模型不存在或已停用")
    price = latest_price(db, model_id)
    task = Task(
        user_id=user.id,
        conversation_id=conversation_id,
        price_id=price.id,
        title=title,
        instruction=instruction,
        budget=amount,
    )
    db.add(task)
    db.flush()
    db.add_all(Material(task_id=task.id, **m) for m in materials)
    db.add_all(Grant(task_id=task.id, tool=t, expires_at=expiry) for t in set(selected))
    if conversation:
        conversation.updated_at = now()
        if conversation.title == "新对话":
            conversation.title = instruction[:60]
    db.commit()
    result = task_summary(db, task)
    request.app.state.runner.start(task.id)
    return result


@router.get("/{task_id}")
def task_detail(task_id: str, user=Depends(current_user), db=Depends(db_session)):
    task = own_task(db, task_id, user.id)
    result = task_summary(db, task)
    result.update(instruction=task.instruction, result=task.result)
    result["materials"] = [
        {"id": m.id, "name": m.name, "kind": m.kind, "characters": len(m.content)}
        for m in db.scalars(select(Material).where(Material.task_id == task_id))
    ]
    result["grants"] = [
        {
            "tool": g.tool,
            "expires_at": g.expires_at,
            "revoked_at": g.revoked_at,
            "active": g.revoked_at is None
            and (g.expires_at is None or g.expires_at > now()),
        }
        for g in db.scalars(select(Grant).where(Grant.task_id == task_id))
    ]
    runs = db.scalars(
        select(Run).where(Run.task_id == task_id).order_by(Run.created_at)
    ).all()
    roles = {r.id: r.role for r in runs}
    result["runs"] = [
        {
            "id": r.id,
            "role": r.role,
            "status": r.status,
            "instruction": r.instruction,
            "output": r.output,
            "created_at": r.created_at,
        }
        for r in runs
    ]
    result["calls"] = [
        {
            "id": c.id,
            "role": roles[c.run_id],
            "status": c.status,
            "usage_status": c.usage_status,
            "input_tokens": c.input_tokens,
            "output_tokens": c.output_tokens,
            "cached_tokens": c.cached_tokens,
            "cost": str(c.cost) if c.cost is not None else None,
            "error": c.error,
            "created_at": c.created_at,
            "provider_request_id": c.provider_request_id,
            "evidence": c.evidence,
        }
        for c in calls_for(db, task_id)
    ]
    result["tool_calls"] = [
        {
            "id": c.id,
            "tool": c.tool,
            "role": roles[c.run_id],
            "status": c.status,
            "arguments": c.arguments,
            "output": c.output,
            "created_at": c.created_at,
        }
        for c in db.scalars(
            select(ToolCall)
            .join(Run, Run.id == ToolCall.run_id)
            .where(Run.task_id == task_id)
            .order_by(ToolCall.created_at)
        )
    ]
    return result


@router.post("/{task_id}/cancel")
def cancel(task_id: str, user=Depends(current_user), db=Depends(db_session)):
    task = own_task(db, task_id, user.id, lock=True)
    if task.status in ACTIVE:
        task.status, task.reason, task.finished_at = (
            "cancelled",
            "用户停止任务；已发出的模型调用仍会记录用量",
            now(),
        )
    db.commit()
    return task_summary(db, task)


class GrantInput(BaseModel):
    enabled: bool
    expires_at: datetime | None = None


@router.put("/{task_id}/grants/{tool}")
def change_grant(
    task_id: str,
    tool: str,
    data: GrantInput,
    user=Depends(current_user),
    db=Depends(db_session),
):
    own_task(db, task_id, user.id, lock=True)
    if tool not in TOOLS:
        raise HTTPException(422, "工具不在白名单中")
    if data.expires_at and (data.expires_at.tzinfo is None or data.expires_at <= now()):
        raise HTTPException(422, "授权到期时间须为未来时间")
    grant = db.scalar(
        select(Grant)
        .where(Grant.task_id == task_id, Grant.tool == tool)
        .with_for_update()
    )
    if grant is None:
        grant = Grant(task_id=task_id, tool=tool)
        db.add(grant)
    grant.expires_at, grant.revoked_at = (
        data.expires_at,
        None if data.enabled else now(),
    )
    db.commit()
    return {"tool": tool, "enabled": data.enabled}


chat_router = APIRouter(prefix="/api/conversations", tags=["conversations"])


def own_conversation(db, conversation_id, user_id, lock=False):
    stmt = select(Conversation).where(
        Conversation.id == conversation_id, Conversation.user_id == user_id
    )
    conversation = db.scalar(stmt.with_for_update() if lock else stmt)
    if conversation is None:
        raise HTTPException(404, "对话不存在")
    return conversation


def conversation_summary(conversation):
    return {
        "id": conversation.id,
        "title": conversation.title,
        "updated_at": conversation.updated_at,
    }


@chat_router.get("")
def list_conversations(user=Depends(current_user), db=Depends(db_session)):
    return [
        conversation_summary(c)
        for c in db.scalars(
            select(Conversation)
            .where(Conversation.user_id == user.id)
            .order_by(Conversation.updated_at.desc())
        )
    ]


@chat_router.post("", status_code=201)
def new_conversation(user=Depends(current_user), db=Depends(db_session)):
    conversation = Conversation(user_id=user.id)
    db.add(conversation)
    db.commit()
    return conversation_summary(conversation)


@chat_router.get("/{conversation_id}")
def conversation_detail(
    conversation_id: str, user=Depends(current_user), db=Depends(db_session)
):
    conversation = own_conversation(db, conversation_id, user.id)
    turns = db.scalars(
        select(Task)
        .where(Task.conversation_id == conversation_id)
        .order_by(Task.created_at, Task.id)
    ).all()
    return {
        **conversation_summary(conversation),
        "turns": [task_detail(t.id, user, db) for t in turns],
    }


@chat_router.post("/{conversation_id}/messages", status_code=201)
def send_message(
    conversation_id: str,
    request: Request,
    message: Annotated[str, Form()],
    model_id: Annotated[str, Form()],
    budget: Annotated[str, Form()],
    tools: Annotated[str, Form()] = '["read_material", "search_materials"]',
    expires_at: Annotated[str, Form()] = "",
    files: list[UploadFile] = File(default=[]),
    user=Depends(current_user),
    db=Depends(db_session),
):
    own_conversation(db, conversation_id, user.id)
    return create_task(
        request=request,
        model_id=model_id,
        budget=budget,
        title=message.strip()[:60],
        instruction=message,
        text="",
        tools=tools,
        expires_at=expires_at,
        files=files,
        user=user,
        db=db,
        conversation_id=conversation_id,
    )
