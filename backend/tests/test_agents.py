"""Real PostgreSQL and API/executor tests, provider replaced at HTTP boundary."""

import json
from decimal import Decimal
from threading import Barrier, Event

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.admin import Reconcile, reconcile
from app.core.database import sessions
from app.entities import Agent, Model, ModelCall, Price, Run, TaskAgent, User
from app.main import create_app
from app.provider import ModelClient
from app.schema import initialize_database
from conftest import response, settings
from test_database import sql
from test_workflows import login, prepare, wait_task


def add_team(client, engine, data):
    factory = sessions(engine)
    with factory.begin() as db:
        db.add(Model(id="second", name="other-model", display_name="Other"))
        db.flush()
        db.add(
            Price(
                id="second-price",
                model_id="second",
                version=1,
                input_rate=1,
                output_rate=4,
                cached_rate=Decimal(".2"),
            )
        )
    agents = []
    for i, model in enumerate([data["model_id"], "second"]):
        payload = dict(
            name=f"Member {i}", instruction=f"Duty {i}", model_id=model, enabled=True
        )
        reply = client.post("/api/agents", json=payload)
        assert reply.status_code == 201, reply.text
        agents.append(reply.json())
    return agents


def submit(client, conv, data, agents, mode="parallel"):
    r = client.post(
        f"/api/conversations/{conv}/messages",
        data={
            **data,
            "agent_ids": json.dumps([a["id"] for a in agents]),
            "execution_mode": mode,
        },
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


def test_parallel_overlap_models_prices_and_admission_snapshot(engine):
    barrier, release, entered = Barrier(2), Event(), Event()
    requests = []

    def handler(request):
        body = json.loads(request.content)
        requests.append(body)
        if "团队成员" in body["messages"][0]["content"]:
            barrier.wait(timeout=6)
            entered.set()
            assert release.wait(8)
        return response()

    provider = ModelClient(settings(), httpx.MockTransport(handler))
    with TestClient(create_app(settings(), engine, provider)) as client:
        conv, data = prepare(client)
        team = add_team(client, engine, data)
        try:
            task = submit(client, conv, data, team)
            assert entered.wait(8), "Both workers must overlap, not run sequentially"
            changed = {
                **team[1],
                "name": "Changed",
                "instruction": "Changed",
                "model_id": data["model_id"],
            }
            assert (
                client.put("/api/agents/" + team[1]["id"], json=changed).status_code
                == 200
            )
            with sessions(engine).begin() as db:
                db.add(
                    Price(
                        model_id="second",
                        version=2,
                        input_rate=100,
                        output_rate=100,
                        cached_rate=100,
                    )
                )
        finally:
            release.set()
        detail = wait_task(client, task)
        assert detail["status"] == "completed"
        assert len(detail["runs"]) == 3
        assert Decimal(detail["cost"]) == Decimal(".00248")
        assert sorted(c["model_name"] for c in detail["calls"]) == [
            "other-model",
            "test-model",
            "test-model",
        ]
        assert all(c["price_version"] == 1 for c in detail["calls"])
        assert detail["team"][1]["name"] == "Member 1"
        assert detail["team"][1]["instruction"] == "Duty 1"
        summary = json.loads(requests[-1]["messages"][1]["content"])
        assert len(summary["previous_work"]) == 2
        assert all(
            t["function"]["name"] not in ("delegate_review", "delegate_summary")
            for t in requests[-1]["tools"]
        )
        with sessions(engine)() as db:
            parent = db.scalar(
                select(Run).where(Run.task_id == task, Run.role == "coordinator")
            )
            workers = db.scalars(
                select(Run).where(Run.task_id == task, Run.role == "worker")
            ).all()
            assert all(w.parent_id == parent.id for w in workers)


def test_sequential_passes_previous_output(engine):
    contexts = []

    def handler(request):
        contexts.append(json.loads(request.content))
        return response()

    with TestClient(
        create_app(
            settings(), engine, ModelClient(settings(), httpx.MockTransport(handler))
        )
    ) as client:
        conv, data = prepare(client)
        team = add_team(client, engine, data)
        result = wait_task(client, submit(client, conv, data, team, "sequential"))
        assert result["status"] == "completed"
        assert [b["model"] for b in contexts] == [
            "test-model",
            "other-model",
            "test-model",
        ]
        assert json.loads(contexts[0]["messages"][1]["content"])["previous_work"] == []
        previous = json.loads(contexts[1]["messages"][1]["content"])["previous_work"]
        assert previous[0]["agent"] == "Member 0"
        assert previous[0]["output"] == "verified response"


@pytest.mark.parametrize("outcome", ["cancel", "unknown", "reject", "budget"])
def test_parallel_settlement_after_stop(engine, outcome):
    barrier, release, entered = Barrier(2), Event(), Event()

    def handler(request):
        body = json.loads(request.content)
        assert "团队成员" in body["messages"][0]["content"], (
            "No final coordinator call after stop"
        )
        barrier.wait(timeout=6)
        entered.set()
        assert release.wait(8)
        if body["model"] == "other-model":
            if outcome == "unknown":
                return response({})
            if outcome == "reject":
                return httpx.Response(400)
        return response()

    with TestClient(
        create_app(
            settings(), engine, ModelClient(settings(), httpx.MockTransport(handler))
        )
    ) as client:
        conv, data = prepare(client)
        team = add_team(client, engine, data)
        if outcome == "budget":
            data["budget"] = ".00001"
        try:
            task = submit(client, conv, data, team)
            assert entered.wait(8)
            if outcome == "cancel":
                assert client.post(f"/api/tasks/{task}/cancel").status_code == 200
        finally:
            release.set()
        # Wait without shutdown: cancellation may already be visible before settlement.
        with client.app.state.runner.lock:
            futures = list(client.app.state.runner.futures)
        for future in futures:
            future.result(timeout=8)
        result = client.get("/api/tasks/" + task).json()
        assert (
            result["status"]
            == {
                "cancel": "cancelled",
                "unknown": "awaiting_usage",
                "reject": "failed",
                "budget": "stopped_budget",
            }[outcome]
        )
        assert len(result["calls"]) == 2
        assert all(c["status"] != "in_flight" for c in result["calls"])
        assert Decimal(result["cost"]) == Decimal(
            ".00062" if outcome in ("unknown", "reject") else ".00186"
        )
        assert result["unknown_calls"] == (1 if outcome == "unknown" else 0)
        assert not result["result"]
        if outcome == "unknown":
            with sessions(engine).begin() as db:
                admin = User(username="operator", password_hash="unused", role="admin")
                db.add(admin)
                db.flush()
                call = next(
                    c for c in result["calls"] if c["usage_status"] == "unknown"
                )
                fixed = reconcile(
                    call["id"],
                    Reconcile(
                        input_tokens=1000,
                        output_tokens=100,
                        cached_tokens=200,
                        evidence="test transport",
                    ),
                    admin,
                    db,
                )
                assert Decimal(fixed["cost"]) == Decimal(".00124"), (
                    "Use worker price, not coordinator price"
                )


def test_agent_ownership_validation_disable_and_csrf(engine):
    with TestClient(
        create_app(
            settings(),
            engine,
            ModelClient(settings(), httpx.MockTransport(lambda r: response())),
        )
    ) as client:
        conv, data = prepare(client)
        team = add_team(client, engine, data)
        endpoint = f"/api/conversations/{conv}/messages"
        for ids in ([team[0]["id"]] * 2, ["missing"], "not-a-list", [{}]):
            r = client.post(endpoint, data={**data, "agent_ids": json.dumps(ids)})
            assert r.status_code == 422
        assert (
            client.post("/api/agents", json={**team[0], "name": "  "}).status_code
            == 422
        )
        assert (
            client.put(
                "/api/agents/" + team[0]["id"],
                json=team[0],
                headers={"X-CSRF-Token": "bad"},
            ).status_code
            == 403
        )
        assert (
            client.put(
                "/api/agents/" + team[0]["id"], json={**team[0], "enabled": False}
            ).status_code
            == 200
        )
        assert (
            client.post(
                endpoint, data={**data, "agent_ids": json.dumps([team[0]["id"]])}
            ).status_code
            == 422
        )
        with sessions(engine).begin() as db:
            db.get(Price, "second-price").currency = "CNY"
        assert (
            client.post(
                endpoint, data={**data, "agent_ids": json.dumps([team[1]["id"]])}
            ).status_code
            == 422
        )
        login(client, "bob")
        assert client.get("/api/agents").json() == []
        assert (
            client.put("/api/agents/" + team[1]["id"], json=team[1]).status_code == 404
        )
        plan = client.get("/api/plans").json()[0]["id"]
        client.post("/api/subscriptions", json={"plan_id": plan})
        conv = client.post("/api/conversations").json()["id"]
        assert (
            client.post(
                f"/api/conversations/{conv}/messages",
                data={**data, "agent_ids": json.dumps([team[1]["id"]])},
            ).status_code
            == 422
        )


def test_upgrade_old_run_prices_and_preserve_history(engine, seeded):
    sql(
        engine,
        "ALTER TABLE agent_runs DROP COLUMN price_id; ALTER TABLE agent_runs DROP COLUMN task_agent_id; DROP TABLE task_agents; DROP TABLE agents; ALTER TABLE tasks DROP COLUMN execution_mode",
    )
    initialize_database(engine)
    initialize_database(engine)
    with seeded() as db:
        assert db.get(Run, "r").price_id == "p"
        assert db.get(ModelCall, "c").cost is None
        assert list(db.scalars(select(Agent))) == []
        assert list(db.scalars(select(TaskAgent))) == []
