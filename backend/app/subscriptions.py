"""Demo subscriptions authorize new tasks; no real payment or automatic renewal."""

from datetime import UTC, timedelta
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert

from app.auth import current_user, db_session
from app.entities import Plan, Subscription, User, now

router = APIRouter(prefix="/api", tags=["subscriptions"])


def seed_plans(factory):
    with factory.begin() as db:
        for code, name, days, price in [
            ("trial-7", "7 天体验", 7, "0"),
            ("standard-30", "30 天标准", 30, "9.90"),
        ]:
            db.execute(
                insert(Plan)
                .values(
                    code=code,
                    name=name,
                    duration_days=days,
                    display_price=Decimal(price),
                )
                .on_conflict_do_nothing(index_elements=["code"])
            )


def lock_user(db, user_id):
    db.scalar(select(User).where(User.id == user_id).with_for_update())


def effective_status(subscription, at):
    if subscription.status == "active" and subscription.ends_at <= at:
        return "expired"
    return subscription.status


def public(subscription):
    at = now()
    return {
        "id": subscription.id,
        "plan_id": subscription.plan_id,
        "plan_name": subscription.plan_name,
        "display_price": str(subscription.display_price),
        "currency": subscription.currency,
        "starts_at": subscription.starts_at.astimezone(UTC),
        "ends_at": subscription.ends_at.astimezone(UTC),
        "cancelled_at": subscription.cancelled_at.astimezone(UTC)
        if subscription.cancelled_at
        else None,
        "status": effective_status(subscription, at),
        "eligible": subscription.status == "active"
        and subscription.starts_at <= at < subscription.ends_at,
    }


def require_subscription(db, user_id):
    lock_user(db, user_id)
    at = now()  # Capture after lock acquisition, never reuse an earlier time.
    subscription = db.scalar(
        select(Subscription).where(
            Subscription.user_id == user_id,
            Subscription.status == "active",
            Subscription.starts_at <= at,
            Subscription.ends_at > at,
        )
    )
    if subscription is None:
        raise HTTPException(403, "请先开通有效订阅，再发送新消息；历史对话仍可查看。")
    return subscription


@router.get("/plans")
def plans(user=Depends(current_user), db=Depends(db_session)):
    return [
        {
            "id": p.id,
            "name": p.name,
            "duration_days": p.duration_days,
            "display_price": str(p.display_price),
            "currency": p.currency,
        }
        for p in db.scalars(
            select(Plan).where(Plan.enabled.is_(True)).order_by(Plan.duration_days)
        )
    ]


@router.get("/subscriptions")
def subscriptions(user=Depends(current_user), db=Depends(db_session)):
    return [
        public(s)
        for s in db.scalars(
            select(Subscription)
            .where(Subscription.user_id == user.id)
            .order_by(Subscription.created_at.desc())
        )
    ]


class Enrollment(BaseModel):
    plan_id: str = Field(min_length=1, max_length=36)


@router.post("/subscriptions")
def enroll(data: Enrollment, user=Depends(current_user), db=Depends(db_session)):
    lock_user(db, user.id)
    at = now()
    previous = db.scalar(
        select(Subscription).where(
            Subscription.user_id == user.id, Subscription.status == "active"
        )
    )
    if previous and previous.ends_at > at:
        if previous.plan_id == data.plan_id:
            return public(previous)
        raise HTTPException(409, "已有有效订阅；更换套餐请先取消当前订阅。")
    plan = db.scalar(select(Plan).where(Plan.id == data.plan_id).with_for_update())
    if plan is None or not plan.enabled:
        raise HTTPException(422, "套餐不存在或已停用")
    if previous:
        previous.status = "expired"
        db.flush()
    subscription = Subscription(
        user_id=user.id,
        plan_id=plan.id,
        plan_name=plan.name,
        display_price=plan.display_price,
        currency=plan.currency,
        starts_at=at,
        ends_at=at + timedelta(days=plan.duration_days),
    )
    db.add(subscription)
    db.commit()
    return public(subscription)


@router.post("/subscriptions/{subscription_id}/cancel")
def cancel(subscription_id: str, user=Depends(current_user), db=Depends(db_session)):
    lock_user(db, user.id)
    subscription = db.scalar(
        select(Subscription).where(
            Subscription.id == subscription_id, Subscription.user_id == user.id
        )
    )
    if subscription is None:
        raise HTTPException(404, "订阅不存在")
    at = now()
    if subscription.status == "active":
        if subscription.ends_at <= at:
            subscription.status = "expired"
        else:
            subscription.status, subscription.cancelled_at = "cancelled", at
        db.commit()
    return public(subscription)
