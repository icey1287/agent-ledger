from pathlib import Path

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import URL, make_url

REPO_ROOT = Path(__file__).resolve().parents[3]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=REPO_ROOT / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    postgres_user: str = "agent_app"
    postgres_password: SecretStr = SecretStr("")
    postgres_db: str = "agent_platform"
    postgres_host: str = "127.0.0.1"
    postgres_port: int = Field(default=5432, ge=1, le=65535)
    database_url: SecretStr | None = None
    model_base_url: str = ""
    model_api_key: SecretStr = SecretStr("")
    model_name: str = ""
    model_timeout: float = Field(default=120, gt=0)
    model_input_rate: str = ""
    model_output_rate: str = ""
    model_cached_rate: str = ""
    model_price_source: str = ""
    model_billing_note: str = ""

    def connection_url(self) -> URL | None:
        if self.database_url and self.database_url.get_secret_value():
            try:
                url = make_url(self.database_url.get_secret_value())
                if url.drivername != "postgresql+psycopg":
                    raise ValueError
                return url
            except Exception:
                # 不让原始连接字符串出现在异常消息中。
                raise ValueError("DATABASE_URL must use postgresql+psycopg") from None

        password = self.postgres_password.get_secret_value()
        if not password:
            return None
        return URL.create(
            "postgresql+psycopg",
            username=self.postgres_user,
            password=password,
            host=self.postgres_host,
            port=self.postgres_port,
            database=self.postgres_db,
        )
