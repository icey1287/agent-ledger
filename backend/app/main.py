from contextlib import asynccontextmanager
from decimal import Decimal

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from sqlalchemy import select

from app import admin, auth, catalog, workspaces
from app.core.config import Settings
from app.core.database import create_database, sessions
from app.entities import Base, Model, Price
from app.execution import Runner
from app.provider import ModelClient
from app.schema import upgrade_conversations


def seed_model(factory, settings):
    if (
        not settings.model_name
        or not settings.model_input_rate
        or not settings.model_output_rate
    ):
        return
    with factory.begin() as db:
        if db.scalar(select(Model).where(Model.name == settings.model_name)):
            return
        model = Model(name=settings.model_name, display_name=settings.model_name)
        db.add(model)
        db.flush()
        db.add(
            Price(
                model_id=model.id,
                version=1,
                input_rate=Decimal(settings.model_input_rate),
                output_rate=Decimal(settings.model_output_rate),
                cached_rate=Decimal(settings.model_cached_rate)
                if settings.model_cached_rate
                else None,
                source_url=settings.model_price_source,
                billing_note=settings.model_billing_note,
            )
        )


def create_app(settings=None, engine=None, provider=None):
    settings = settings or Settings()

    @asynccontextmanager
    async def lifespan(app):
        actual_engine = engine if engine is not None else create_database(settings)
        Base.metadata.create_all(actual_engine)
        factory = sessions(actual_engine)
        upgrade_conversations(actual_engine, factory)
        client = provider if provider is not None else ModelClient(settings)
        app.state.settings, app.state.sessions, app.state.provider = (
            settings,
            factory,
            client,
        )
        seed_model(factory, settings)
        runner = Runner(factory, client)
        app.state.runner = runner
        runner.recover()
        try:
            yield
        finally:
            runner.close()
            client.close()
            if engine is None:
                actual_engine.dispose()

    app = FastAPI(title="Agent Desk 对话与用量管理", version="0.2.0", lifespan=lifespan)

    @app.middleware("http")
    async def same_origin(request: Request, call_next):
        origin = request.headers.get("origin")
        allowed = {
            f"http://{host}:{port}"
            for host in ("localhost", "127.0.0.1")
            for port in (5173, 4173, 8000)
        }
        if (
            request.method not in ("GET", "HEAD", "OPTIONS")
            and origin
            and origin not in allowed
        ):
            return JSONResponse({"detail": "不接受此来源的写入请求"}, status_code=403)
        return await call_next(request)

    for router in (
        auth.router,
        catalog.router,
        workspaces.router,
        workspaces.chat_router,
        admin.router,
    ):
        app.include_router(router)
    return app


app = create_app()
