"""User-owned Agent profiles and immutable admission-time team snapshots."""

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select

from app.auth import current_user, db_session
from app.catalog import latest_price
from app.entities import Agent, Model, TaskAgent

router = APIRouter(prefix="/api/agents", tags=["agents"])


class AgentInput(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    instruction: str = Field(min_length=1)
    model_id: str
    enabled: bool = True

    @field_validator("name", "instruction")
    @classmethod
    def nonblank(cls, value):
        if not value.strip():
            raise ValueError("名称和职责不能为空")
        return value.strip()


def profile(agent):
    return {
        k: getattr(agent, k)
        for k in ("id", "name", "instruction", "model_id", "enabled")
    }


def validate_model(db, model_id):
    model = db.get(Model, model_id)
    if model is None or not model.enabled:
        raise HTTPException(422, "Agent 所选模型不存在或已停用")
    return latest_price(db, model_id)


@router.get("")
def list_agents(user=Depends(current_user), db=Depends(db_session)):
    return [
        profile(a)
        for a in db.scalars(
            select(Agent)
            .where(Agent.user_id == user.id)
            .order_by(Agent.created_at, Agent.id)
        )
    ]


@router.post("", status_code=201)
def create_agent(data: AgentInput, user=Depends(current_user), db=Depends(db_session)):
    validate_model(db, data.model_id)
    agent = Agent(user_id=user.id, **data.model_dump())
    db.add(agent)
    db.commit()
    return profile(agent)


@router.put("/{agent_id}")
def edit_agent(
    agent_id: str, data: AgentInput, user=Depends(current_user), db=Depends(db_session)
):
    agent = db.scalar(
        select(Agent)
        .where(Agent.id == agent_id, Agent.user_id == user.id)
        .with_for_update()
    )
    if agent is None:
        raise HTTPException(404, "Agent 不存在")
    # Disabling a profile must remain possible after its model is disabled.
    if data.enabled or data.model_id != agent.model_id:
        validate_model(db, data.model_id)
    for key, value in data.model_dump().items():
        setattr(agent, key, value)
    db.commit()
    return profile(agent)


def snapshot_team(db, task, ids, currency):
    if (
        not isinstance(ids, list)
        or any(not isinstance(i, str) for i in ids)
        or len(ids) != len(set(ids))
    ):
        raise HTTPException(422, "Agent 列表格式错误或有重复")
    # Deterministic lock order, independent of execution order chosen by user.
    rows = db.scalars(
        select(Agent)
        .where(Agent.id.in_(ids), Agent.user_id == task.user_id)
        .order_by(Agent.id)
        .with_for_update()
    ).all()
    profiles = {a.id: a for a in rows}
    for position, agent_id in enumerate(ids):
        agent = profiles.get(agent_id)
        if agent is None or not agent.enabled:
            raise HTTPException(422, "所选 Agent 不存在或已停用")
        price = validate_model(db, agent.model_id)
        if price.currency != currency:
            raise HTTPException(422, "团队模型价格须与协调模型使用同一币种")
        db.add(
            TaskAgent(
                task_id=task.id,
                agent_id=agent.id,
                price_id=price.id,
                name=agent.name,
                instruction=agent.instruction,
                position=position,
            )
        )
