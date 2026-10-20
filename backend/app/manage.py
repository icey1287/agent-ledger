"""创建本机管理员：uv run python -m app.manage create-admin --username admin"""

import argparse
import getpass
import os

from sqlalchemy import select

from app.auth import Credentials, passwords
from app.core.config import Settings
from app.core.database import create_database, sessions
from app.entities import Base, User


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["create-admin"])
    parser.add_argument("--username", default="admin")
    parser.add_argument(
        "--password-env", help="可选：从指定环境变量读取密码，避免出现在命令历史"
    )
    args = parser.parse_args()
    password = (
        os.environ.get(args.password_env, "")
        if args.password_env
        else getpass.getpass("管理员密码（至少 8 位）: ")
    )
    if not args.password_env and password != getpass.getpass("再次输入密码: "):
        raise SystemExit("两次密码不一致")
    data = Credentials(username=args.username, password=password)
    engine = create_database(Settings())
    Base.metadata.create_all(engine)
    with sessions(engine).begin() as db:
        if db.scalar(select(User).where(User.username == data.username)):
            raise SystemExit("用户名已存在；不会覆盖已有账号或提升其权限")
        db.add(
            User(
                username=data.username,
                password_hash=passwords.hash(data.password),
                role="admin",
            )
        )
    engine.dispose()
    print("管理员已创建，可以在页面登录。")


if __name__ == "__main__":
    main()
