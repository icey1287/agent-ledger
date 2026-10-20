"""账号、会话和写操作校验。"""

import hashlib
import secrets
from datetime import timedelta

from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.entities import Session, User, now

router = APIRouter(prefix="/api/auth", tags=["accounts"])
passwords = PasswordHasher()
COOKIE = "agent_session"


class Credentials(BaseModel):
    username: str = Field(min_length=3, max_length=64, pattern=r"^[a-zA-Z0-9_.-]+$")
    password: str = Field(min_length=8, max_length=256)


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def db_session(request: Request):
    with request.app.state.sessions() as db:
        yield db


def current_user(request: Request, db=Depends(db_session)):
    token = request.cookies.get(COOKIE, "")
    session = db.scalar(
        select(Session).where(
            Session.token_hash == digest(token), Session.expires_at > now()
        )
    )
    if session is None:
        raise HTTPException(401, "请先登录")
    if request.method not in ("GET", "HEAD", "OPTIONS"):
        csrf = request.headers.get("X-CSRF-Token", "")
        if not secrets.compare_digest(csrf, session.csrf_token):
            raise HTTPException(403, "页面会话已变化，请刷新后重试")
    request.state.session = session
    return db.get(User, session.user_id)


def administrator(user=Depends(current_user)):
    if user.role != "admin":
        raise HTTPException(403, "需要管理员权限")
    return user


def public_user(user, csrf):
    return {
        "id": user.id,
        "username": user.username,
        "role": user.role,
        "csrf_token": csrf,
    }


def issue_session(db, user, response):
    token = secrets.token_urlsafe(32)
    session = Session(
        user_id=user.id,
        token_hash=digest(token),
        csrf_token=secrets.token_hex(32),
        expires_at=now() + timedelta(days=7),
    )
    db.add(session)
    db.commit()
    response.set_cookie(
        COOKIE, token, httponly=True, samesite="strict", max_age=604800, path="/api"
    )
    return public_user(user, session.csrf_token)


@router.post("/register", status_code=201)
def register(data: Credentials, response: Response, db=Depends(db_session)):
    user = User(
        username=data.username, password_hash=passwords.hash(data.password), role="user"
    )
    db.add(user)
    try:
        db.flush()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "用户名已存在") from None
    return issue_session(db, user, response)


@router.post("/login")
def login(data: Credentials, response: Response, db=Depends(db_session)):
    user = db.scalar(select(User).where(User.username == data.username))
    try:
        if user is None:
            raise VerificationError
        passwords.verify(user.password_hash, data.password)
    except VerificationError:
        raise HTTPException(401, "用户名或密码错误") from None
    return issue_session(db, user, response)


@router.get("/me")
def me(request: Request, user=Depends(current_user)):
    return public_user(user, request.state.session.csrf_token)


@router.post("/logout", status_code=204)
def logout(
    request: Request,
    response: Response,
    user=Depends(current_user),
    db=Depends(db_session),
):
    db.delete(request.state.session)
    db.commit()
    response.delete_cookie(COOKIE, path="/api")
