from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import select

from app.auth import administrator, db_session
from app.billing import UnknownUsage, calculate
from app.entities import ModelCall, Price, Run, Task, User, now
from app.workspaces import calls_for

router = APIRouter(prefix="/api/admin", tags=["admin"])


@router.get("/unresolved")
def unresolved(user=Depends(administrator), db=Depends(db_session)):
    rows = db.execute(
        select(ModelCall, Task, User)
        .join(Run, Run.id == ModelCall.run_id)
        .join(Task, Task.id == Run.task_id)
        .join(User, User.id == Task.user_id)
        .where(ModelCall.status == "usage_unknown")
        .order_by(ModelCall.created_at)
    ).all()
    return [
        {
            "id": c.id,
            "task_id": t.id,
            "title": t.title,
            "username": u.username,
            "error": c.error,
            "provider_request_id": c.provider_request_id,
            "raw_usage": c.raw_usage,
            "created_at": c.created_at,
        }
        for c, t, u in rows
    ]


class Reconcile(BaseModel):
    input_tokens: int = Field(ge=0, strict=True)
    output_tokens: int = Field(ge=0, strict=True)
    cached_tokens: int = Field(default=0, ge=0, strict=True)
    evidence: str = Field(min_length=1)

    @model_validator(mode="after")
    def valid(self):
        if self.cached_tokens > self.input_tokens or not self.evidence.strip():
            raise ValueError("请填写有效的用量和核实依据")
        return self


@router.post("/calls/{call_id}/reconcile")
def reconcile(
    call_id: str, data: Reconcile, user=Depends(administrator), db=Depends(db_session)
):
    # 与执行器保持相同的加锁顺序：任务，再调用。
    call = db.get(ModelCall, call_id)
    if call is None:
        raise HTTPException(404, "调用不存在")
    run = db.get(Run, call.run_id)
    task = db.scalar(select(Task).where(Task.id == run.task_id).with_for_update())
    call = db.scalar(
        select(ModelCall)
        .where(ModelCall.id == call_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if call.usage_status == "known":
        return {"id": call.id, "cost": str(call.cost), "already_reconciled": True}
    if call.status != "usage_unknown":
        raise HTTPException(409, "调用仍在进行，不能补录")
    usage = {
        "prompt_tokens": data.input_tokens,
        "completion_tokens": data.output_tokens,
        "prompt_tokens_details": {"cached_tokens": data.cached_tokens},
    }
    try:
        incoming, outgoing, cached, cost = calculate(
            usage, db.get(Price, task.price_id)
        )
    except UnknownUsage as exc:
        raise HTTPException(422, str(exc)) from None
    call.input_tokens, call.output_tokens, call.cached_tokens, call.cost = (
        incoming,
        outgoing,
        cached,
        cost,
    )
    call.usage_status, call.status = "known", "reconciled"
    call.reconciled_by, call.evidence, call.reconciled_at = (
        user.id,
        data.evidence,
        now(),
    )
    db.flush()
    if task.status == "awaiting_usage" and all(
        c.usage_status == "known" for c in calls_for(db, task.id)
    ):
        task.status, task.reason, task.finished_at = (
            "interrupted",
            "用量已核实，本次任务不自动恢复",
            now(),
        )
    db.commit()
    return {"id": call.id, "cost": str(cost), "already_reconciled": False}
