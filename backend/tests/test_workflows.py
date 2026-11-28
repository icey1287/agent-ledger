import time
from concurrent.futures import ThreadPoolExecutor
from threading import Event

import httpx
import pytest
from app.core.database import sessions
from app.entities import ModelCall, Run, Task
from app.execution import Runner
from app.main import create_app
from app.provider import ModelClient
from conftest import response, settings
from fastapi.testclient import TestClient
from sqlalchemy import select


def login(client, name):
    r = client.post(
        "/api/auth/register", json={"username": name, "password": "test-password-only"}
    )
    assert r.status_code == 201
    client.headers["X-CSRF-Token"] = r.json()["csrf_token"]


def prepare(client):
    login(client, "alice")
    plan = client.get("/api/plans").json()[0]["id"]
    assert client.post("/api/subscriptions", json={"plan_id": plan}).status_code == 200
    model = client.get("/api/models").json()["models"][0]["id"]
    conv = client.post("/api/conversations").json()["id"]
    return conv, {"model_id": model, "budget": "1", "message": "test"}


def wait_task(client, task_id):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        r = client.get("/api/tasks/" + task_id).json()
        if r["status"] not in ("pending", "running"):
            return r
        time.sleep(0.02)
    pytest.fail("Task did not finish")


def test_concurrent_send_is_serialized_and_users_are_isolated(engine):
    entered, release = Event(), Event()
    requests = []

    def handler(request):
        requests.append(request)
        entered.set()
        assert release.wait(8)
        return response()

    provider = ModelClient(settings(), httpx.MockTransport(handler))
    with TestClient(create_app(settings(), engine, provider)) as client:
        conv, data = prepare(client)
        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [
                    pool.submit(
                        client.post, f"/api/conversations/{conv}/messages", data=data
                    )
                    for _ in range(2)
                ]
                replies = [f.result(timeout=8) for f in futures]
            assert sorted(r.status_code for r in replies) == [201, 409]
            task_id = next(r.json()["id"] for r in replies if r.status_code == 201)
            assert entered.wait(3)
        finally:
            release.set()
        result = wait_task(client, task_id)
        assert result["status"] == "completed"
        assert result["cost"] == "0.000620000000"
        assert len(requests) == 1
        # A second user cannot read or mutate the first user's records.
        login(client, "bob")
        assert client.get("/api/tasks/" + task_id).status_code == 404
        assert client.post("/api/tasks/" + task_id + "/cancel").status_code == 404
        assert client.get("/api/conversations/" + conv).status_code == 404
        assert client.get("/api/admin/unresolved").status_code == 403
        assert (
            client.post(
                "/api/conversations", headers={"X-CSRF-Token": "invalid"}
            ).status_code
            == 403
        )


def test_missing_usage_is_unknown_not_zero(engine):
    provider = ModelClient(
        settings(), httpx.MockTransport(lambda request: response({}))
    )
    with TestClient(create_app(settings(), engine, provider)) as client:
        conv, data = prepare(client)
        task_id = client.post(f"/api/conversations/{conv}/messages", data=data).json()[
            "id"
        ]
        result = wait_task(client, task_id)
        assert result["status"] == "awaiting_usage"
        assert result["unknown_calls"] == 1
        with sessions(engine)() as db:
            call = db.scalar(select(ModelCall))
            assert call.cost is None
            assert call.usage_status == "unknown"


def test_restart_preserves_uncertainty_and_does_not_call_provider(engine, seeded):
    with seeded.begin() as db:
        db.get(Task, "t").status = "running"
        db.get(Run, "r").status = "running"
        db.get(ModelCall, "c").status = "in_flight"

    def forbidden(request):
        pytest.fail("Recovery must never call the provider")

    provider = ModelClient(settings(), httpx.MockTransport(forbidden))
    runner = Runner(seeded, provider)
    try:
        runner.recover()
        runner.recover()
        with seeded() as db:
            assert db.get(Task, "t").status == "awaiting_usage"
            assert db.get(Run, "r").status == "interrupted"
            assert db.get(ModelCall, "c").status == "usage_unknown"
            assert db.get(ModelCall, "c").cost is None
    finally:
        runner.close()
        provider.close()
