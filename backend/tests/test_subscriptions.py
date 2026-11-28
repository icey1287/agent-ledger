from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from decimal import Decimal
from threading import Barrier

import httpx
import pytest
from app.core.database import sessions
from app.entities import ModelCall, Plan, Subscription, Task, User, now
from app.main import create_app
from app.provider import ModelClient
from app.schema import initialize_database
from app.subscriptions import Enrollment, enroll, seed_plans
from conftest import response, settings
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from test_workflows import login, wait_task


@pytest.fixture
def client(engine):
    provider = ModelClient(settings(), httpx.MockTransport(lambda request: response()))
    with TestClient(create_app(settings(), engine, provider)) as client:
        login(client, "alice")
        yield client


def plan(client):
    return client.get("/api/plans").json()[0]["id"]


def message_data(client):
    return {
        "model_id": client.get("/api/models").json()["models"][0]["id"],
        "budget": "1",
        "message": "test",
        "instruction": "test",
    }


def test_no_subscription_blocks_both_task_entrypoints(client, engine):
    data = message_data(client)
    conv = client.post("/api/conversations").json()["id"]
    for url in ["/api/tasks", f"/api/conversations/{conv}/messages"]:
        assert client.post(url, data=data).status_code == 403
    with sessions(engine)() as db:
        assert db.scalars(select(Task)).all() == []
        assert db.scalars(select(ModelCall)).all() == []


def test_enroll_repeat_and_task_binding(client, engine):
    p = plan(client)
    a = client.post("/api/subscriptions", json={"plan_id": p}).json()
    b = client.post("/api/subscriptions", json={"plan_id": p}).json()
    assert a["id"] == b["id"] and a["ends_at"] == b["ends_at"]
    other = client.get("/api/plans").json()[1]["id"]
    assert client.post("/api/subscriptions", json={"plan_id": other}).status_code == 409
    task = client.post("/api/tasks", data=message_data(client)).json()
    assert task["subscription_id"] == a["id"]
    assert wait_task(client, task["id"])["status"] == "completed"
    cancelled = client.post("/api/subscriptions/" + a["id"] + "/cancel").json()
    assert cancelled["status"] == "cancelled"
    assert client.post("/api/subscriptions/" + a["id"] + "/cancel").json() == cancelled
    assert client.post("/api/tasks", data=message_data(client)).status_code == 403
    assert client.get("/api/tasks/" + task["id"]).status_code == 200
    with sessions(engine)() as db:
        assert db.get(Task, task["id"]).subscription_id == a["id"]


def test_expiry_and_renewal_keep_history_and_snapshot(client, engine):
    p = plan(client)
    a = client.post("/api/subscriptions", json={"plan_id": p}).json()
    with sessions(engine).begin() as db:
        sub = db.get(Subscription, a["id"])
        sub.starts_at = now() - timedelta(days=8)
        sub.ends_at = now() - timedelta(seconds=1)
        db.get(Plan, p).name = "New name"
        db.get(Plan, p).display_price = Decimal("2")
    current = client.get("/api/subscriptions").json()[0]
    assert current["status"] == "expired" and not current["eligible"]
    assert current["plan_name"] == a["plan_name"]
    assert client.post("/api/tasks", data=message_data(client)).status_code == 403
    b = client.post("/api/subscriptions", json={"plan_id": p}).json()
    assert b["id"] != a["id"] and b["plan_name"] == "New name"
    assert len(client.get("/api/subscriptions").json()) == 2


def test_subscription_isolation_and_csrf(client):
    a = client.post("/api/subscriptions", json={"plan_id": plan(client)}).json()
    login(client, "bob")
    assert client.get("/api/subscriptions").json() == []
    assert client.post("/api/subscriptions/" + a["id"] + "/cancel").status_code == 404
    assert (
        client.post(
            "/api/subscriptions",
            json={"plan_id": a["plan_id"]},
            headers={"X-CSRF-Token": "bad"},
        ).status_code
        == 403
    )


def test_disabled_plan_cannot_be_enrolled(client, engine):
    p = plan(client)
    with sessions(engine).begin() as db:
        db.get(Plan, p).enabled = False
    assert client.post("/api/subscriptions", json={"plan_id": p}).status_code == 422
    assert (
        client.post("/api/subscriptions", json={"plan_id": "missing"}).status_code
        == 422
    )


def test_concurrent_enrollment_is_idempotent(engine, seeded):
    seed_plans(seeded)
    with seeded() as db:
        p = db.scalar(select(Plan)).id
    barrier = Barrier(2)

    def submit():
        with seeded() as db:
            user = db.get(User, "u")
            barrier.wait(timeout=5)
            return enroll(Enrollment(plan_id=p), user, db)

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(submit) for _ in range(2)]
        a, b = [f.result(timeout=10) for f in futures]
    assert a["id"] == b["id"]
    with seeded() as db:
        assert len(db.scalars(select(Subscription)).all()) == 1


def test_task_subscription_owner_is_enforced(engine, seeded):
    seed_plans(seeded)
    with seeded() as db:
        p = db.scalar(select(Plan)).id
        sub = enroll(Enrollment(plan_id=p), db.get(User, "a"), db)
    with pytest.raises(IntegrityError):
        with seeded.begin() as db:
            db.get(Task, "t").subscription_id = sub["id"]


@pytest.mark.parametrize(
    "field,value",
    [
        ("ends_at", "past"),
        ("status", "invalid"),
        ("display_price", -1),
        ("cancelled_at", "now"),
    ],
)
def test_subscription_database_constraints(client, engine, field, value):
    sub = client.post("/api/subscriptions", json={"plan_id": plan(client)}).json()
    with pytest.raises(IntegrityError):
        with sessions(engine).begin() as db:
            s = db.get(Subscription, sub["id"])
            actual = (
                s.starts_at - timedelta(seconds=1)
                if value == "past"
                else now()
                if value == "now"
                else value
            )
            setattr(s, field, actual)


def test_legacy_tasks_keep_nullable_subscription(engine, seeded):
    schema = engine.get_execution_options()["schema_translate_map"][None]
    with engine.begin() as c:
        c.exec_driver_sql(
            f'ALTER TABLE "{schema}".tasks DROP COLUMN subscription_id CASCADE'
        )
        c.exec_driver_sql(f'DROP TABLE "{schema}".subscriptions')
        c.exec_driver_sql(f'DROP TABLE "{schema}".plans')
    initialize_database(engine)
    with seeded() as db:
        assert db.get(Task, "t").subscription_id is None
        assert db.get(ModelCall, "c").cost is None


def test_cancel_does_not_stop_accepted_task(engine):
    from threading import Event

    entered, release = Event(), Event()

    def handler(request):
        entered.set()
        assert release.wait(8)
        return response()

    provider = ModelClient(settings(), httpx.MockTransport(handler))
    with TestClient(create_app(settings(), engine, provider)) as c:
        login(c, "alice")
        sub = c.post("/api/subscriptions", json={"plan_id": plan(c)}).json()
        try:
            task = c.post("/api/tasks", data=message_data(c)).json()
            assert entered.wait(3)
            assert (
                c.post("/api/subscriptions/" + sub["id"] + "/cancel").status_code == 200
            )
            assert c.post("/api/tasks", data=message_data(c)).status_code == 403
        finally:
            release.set()
        result = wait_task(c, task["id"])
        assert result["status"] == "completed"
        assert result["cost"] == "0.000620000000"


def test_database_rejects_two_active_subscriptions(client, engine):
    sub = client.post("/api/subscriptions", json={"plan_id": plan(client)}).json()
    with pytest.raises(IntegrityError):
        with sessions(engine).begin() as db:
            first = db.get(Subscription, sub["id"])
            db.add(
                Subscription(
                    user_id=first.user_id,
                    plan_id=first.plan_id,
                    plan_name=first.plan_name,
                    display_price=first.display_price,
                    currency=first.currency,
                    starts_at=now(),
                    ends_at=now() + timedelta(days=1),
                )
            )
