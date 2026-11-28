"""Real PostgreSQL tests: random schema, fake HTTP provider, no API spending."""

import os
from decimal import Decimal
from uuid import uuid4

import httpx
import pytest
from app.core.config import Settings
from app.core.database import sessions
from app.entities import Conversation, Model, ModelCall, Price, Run, Task, User
from app.schema import initialize_database
from sqlalchemy import create_engine


@pytest.fixture
def engine():
    # Explicit opt-in; never silently use the developer's configured database.
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        pytest.skip("Set TEST_DATABASE_URL to a disposable PostgreSQL database")
    base = create_engine(url)
    schema = "test_agent_" + uuid4().hex
    with base.begin() as c:
        c.exec_driver_sql(f'CREATE SCHEMA "{schema}"')
    engine = base.execution_options(schema_translate_map={None: schema})
    try:
        yield engine
    finally:
        with base.begin() as c:
            c.exec_driver_sql(f'DROP SCHEMA "{schema}" CASCADE')
        base.dispose()


@pytest.fixture
def seeded(engine):
    initialize_database(engine)
    factory = sessions(engine)
    with factory.begin() as db:
        db.add_all(
            [
                User(id="u", username="owner", password_hash="unused"),
                User(id="a", username="admin", password_hash="unused", role="admin"),
                Model(id="m", name="test-model", display_name="Test"),
            ]
        )
        db.flush()
        db.add(
            Price(
                id="p",
                model_id="m",
                version=1,
                input_rate=Decimal(".5"),
                output_rate=Decimal("2"),
                cached_rate=Decimal(".1"),
            )
        )
        db.add(Conversation(id="v", user_id="u"))
        db.flush()
        db.add(
            Task(
                id="t",
                user_id="u",
                conversation_id="v",
                price_id="p",
                title="test",
                instruction="test",
                budget=Decimal("1"),
                status="awaiting_usage",
            )
        )
        db.flush()
        db.add(Run(id="r", task_id="t", role="coordinator", status="interrupted"))
        db.flush()
        db.add(ModelCall(id="c", run_id="r", status="usage_unknown"))
    return factory


def response(usage=None):
    return httpx.Response(
        200,
        json={
            "id": "mock-response",
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"role": "assistant", "content": "verified response"},
                }
            ],
            "usage": usage
            if usage is not None
            else {
                "prompt_tokens": 1000,
                "completion_tokens": 100,
                "prompt_tokens_details": {"cached_tokens": 200},
            },
        },
    )


def settings():
    return Settings(
        _env_file=None,
        model_base_url="https://test.invalid",
        model_api_key="test-only",
        model_name="test-model",
        model_input_rate=".5",
        model_output_rate="2",
        model_cached_rate=".1",
    )
