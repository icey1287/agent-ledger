from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.core.config import Settings


def create_database(settings: Settings):
    url = settings.connection_url()
    if url is None:
        raise RuntimeError("请先在根目录 .env 配置 PostgreSQL。")
    return create_engine(url, pool_pre_ping=True, connect_args={"connect_timeout": 5})


def sessions(engine):
    return sessionmaker(engine, expire_on_commit=False)
