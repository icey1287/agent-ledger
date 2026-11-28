from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from pathlib import Path
from threading import Barrier

import pytest
from app.admin import Reconcile, reconcile
from app.entities import ModelCall, Price, Task, User
from app.schema import initialize_database
from sqlalchemy import inspect, select
from sqlalchemy.exc import IntegrityError

ROOT = Path(__file__).resolve().parents[2]


def sql(engine, source):
    schema = engine.get_execution_options()["schema_translate_map"][None]
    with engine.begin() as c:
        c.exec_driver_sql(f'SET LOCAL search_path TO "{schema}"')
        return c.exec_driver_sql(source, execution_options={"no_parameters": True})


@pytest.mark.parametrize(
    "change",
    [
        "cost=0",
        "cost=1",
        "usage_status='known'",
        "usage_status='known',input_tokens=1,output_tokens=0,cost=0",
        "usage_status='known',input_tokens=1,cached_tokens=0,cost=0",
        "usage_status='known',output_tokens=1,cached_tokens=0,cost=0",
        "usage_status='known',input_tokens=1,output_tokens=1,cached_tokens=0",
        "usage_status='known',input_tokens=1,output_tokens=1,cached_tokens=2,cost=0",
        "usage_status='invalid'",
        "status='invalid'",
        "input_tokens=-1",
    ],
)
def test_invalid_call_writes_rejected(engine, seeded, change):
    with pytest.raises(IntegrityError):
        sql(engine, f"UPDATE model_calls SET {change} WHERE id='c'")
    with seeded() as db:
        assert db.get(ModelCall, "c").cost is None
        assert db.get(ModelCall, "c").usage_status == "unknown"


@pytest.mark.parametrize(
    "change",
    [
        "cost=NULL",
        "usage_status='known',input_tokens=0,output_tokens=0,cached_tokens=0,cost=0",
        "usage_status='known',input_tokens=1000,output_tokens=100,cached_tokens=200,cost=.00062",
    ],
)
def test_valid_usage_states(engine, seeded, change):
    sql(engine, f"UPDATE model_calls SET {change} WHERE id='c'")


def catalog(engine):
    schema = engine.get_execution_options()["schema_translate_map"][None]
    with engine.connect() as c:
        i = inspect(c)
        return {
            t: (
                {
                    x["name"]: x["sqltext"]
                    for x in i.get_check_constraints(t, schema=schema)
                    if x["name"].startswith("ck_")
                },
                {
                    x["name"]
                    for x in i.get_indexes(t, schema=schema)
                    if x["name"].startswith("ix_")
                },
            )
            for t in i.get_table_names(schema=schema)
        }


def test_fresh_sql_and_app_constraints_and_indexes_match(engine):
    sql(engine, (ROOT / "db/schema.sql").read_text())
    expected = catalog(engine)
    initialize_database(engine)
    assert catalog(engine) == expected
    schema = engine.get_execution_options()["schema_translate_map"][None]
    with engine.begin() as c:
        c.exec_driver_sql(f'DROP SCHEMA "{schema}" CASCADE')
        c.exec_driver_sql(f'CREATE SCHEMA "{schema}"')
    initialize_database(engine)
    assert catalog(engine) == expected
    initialize_database(engine)
    assert catalog(engine) == expected


def test_legacy_upgrade_preserves_rows(engine, seeded):
    sql(engine, "ALTER TABLE model_calls DROP CONSTRAINT ck_model_calls_usage_complete")
    sql(engine, "UPDATE tasks SET conversation_id=NULL WHERE id='t'")
    initialize_database(engine)
    initialize_database(engine)
    with seeded() as db:
        assert db.get(ModelCall, "c").cost is None
        assert db.get(Task, "t").conversation_id is not None
        assert db.get(Price, "p").input_rate == Decimal(".5")
    with pytest.raises(IntegrityError):
        sql(engine, "UPDATE model_calls SET cost=0 WHERE id='c'")


def test_dirty_legacy_data_blocks_migration_without_rewriting(engine, seeded):
    sql(engine, "ALTER TABLE model_calls DROP CONSTRAINT ck_model_calls_usage_complete")
    sql(engine, "UPDATE model_calls SET cost=0 WHERE id='c'")
    with pytest.raises(IntegrityError):
        initialize_database(engine)
    with seeded() as db:
        assert db.get(ModelCall, "c").cost == 0
        assert db.get(ModelCall, "c").usage_status == "unknown"


def test_transaction_rolls_back_all_writes(engine, seeded):
    with pytest.raises(IntegrityError):
        with seeded.begin() as db:
            db.add(User(id="rollback", username="rollback", password_hash="unused"))
            db.flush()
            db.get(ModelCall, "c").cost = Decimal("0")
            db.flush()
    with seeded() as db:
        assert db.get(User, "rollback") is None


def test_concurrent_reconciliation_uses_original_price_once(seeded):
    with seeded.begin() as db:
        db.add(
            Price(
                id="p2",
                model_id="m",
                version=2,
                input_rate=Decimal("50"),
                output_rate=Decimal("200"),
                cached_rate=Decimal("10"),
            )
        )
    barrier = Barrier(2)

    def submit():
        with seeded() as db:
            admin = db.get(User, "a")
            barrier.wait(timeout=5)
            return reconcile(
                "c",
                Reconcile(
                    input_tokens=1000,
                    output_tokens=100,
                    cached_tokens=200,
                    evidence="test evidence",
                ),
                admin,
                db,
            )

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(submit) for _ in range(2)]
        results = [f.result(timeout=10) for f in futures]
    assert sorted(r["already_reconciled"] for r in results) == [False, True]
    assert all(Decimal(r["cost"]) == Decimal(".00062") for r in results)
    with seeded() as db:
        assert len(db.scalars(select(ModelCall)).all()) == 1
        assert db.get(Task, "t").status == "interrupted"
        assert db.get(ModelCall, "c").evidence == "test evidence"


def test_sample_data_and_assertions(engine):
    sql(engine, (ROOT / "db/schema.sql").read_text())
    sql(engine, (ROOT / "db/sample-data.sql").read_text())
    # All pre-V10 assertions must have no result rows. V10 is observational.
    source = (ROOT / "db/verification.sql").read_text().split("-- V10")[0]
    for statement in source.split(";"):
        query = "\n".join(
            x for x in statement.splitlines() if not x.lstrip().startswith("--")
        ).strip()
        if query.upper().startswith("SELECT"):
            assert sql(engine, query).fetchall() == []


def test_pre_conversation_database_upgrades(engine, seeded):
    sql(engine, "ALTER TABLE tasks DROP COLUMN conversation_id CASCADE")
    sql(engine, "DROP TABLE conversations")
    initialize_database(engine)
    with seeded() as db:
        task = db.get(Task, "t")
        assert task.conversation_id is not None
        assert task.price_id == "p"
        assert db.get(ModelCall, "c").run_id == "r"


def test_reconcile_retry_cannot_overwrite_confirmed_usage(seeded):
    with seeded() as db:
        reconcile(
            "c",
            Reconcile(
                input_tokens=1000,
                output_tokens=100,
                cached_tokens=200,
                evidence="first evidence",
            ),
            db.get(User, "a"),
            db,
        )
    with seeded() as db:
        result = reconcile(
            "c",
            Reconcile(
                input_tokens=9999, output_tokens=9999, evidence="different retry"
            ),
            db.get(User, "a"),
            db,
        )
        assert result["already_reconciled"] is True
        call = db.get(ModelCall, "c")
        assert call.input_tokens == 1000
        assert call.evidence == "first evidence"


def test_inflight_call_cannot_be_reconciled(seeded):
    from fastapi import HTTPException

    with seeded.begin() as db:
        db.get(ModelCall, "c").status = "in_flight"
    with seeded() as db:
        with pytest.raises(HTTPException) as exc:
            reconcile(
                "c",
                Reconcile(input_tokens=0, output_tokens=0, evidence="too early"),
                db.get(User, "a"),
                db,
            )
        assert exc.value.status_code == 409
        assert db.get(ModelCall, "c").cost is None
