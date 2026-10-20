from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.auth import administrator, current_user, db_session
from app.entities import Model, Price

router = APIRouter(prefix="/api", tags=["models"])


class ModelInput(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    display_name: str = Field(min_length=1, max_length=200)
    input_rate: Decimal = Field(
        ge=0, allow_inf_nan=False, max_digits=24, decimal_places=12
    )
    output_rate: Decimal = Field(
        ge=0, allow_inf_nan=False, max_digits=24, decimal_places=12
    )
    cached_rate: Decimal | None = Field(
        default=None, ge=0, allow_inf_nan=False, max_digits=24, decimal_places=12
    )
    currency: str = Field(default="USD", pattern="^[A-Z]{3}$")
    enabled: bool = True
    source_url: str = ""
    billing_note: str = ""


def latest_price(db, model_id):
    return db.scalar(
        select(Price).where(Price.model_id == model_id).order_by(Price.version.desc())
    )


def public_model(db, model):
    price = latest_price(db, model.id)
    return {
        "id": model.id,
        "name": model.name,
        "display_name": model.display_name,
        "enabled": model.enabled,
        "price": {
            "id": price.id,
            "version": price.version,
            "currency": price.currency,
            "input_rate": str(price.input_rate),
            "output_rate": str(price.output_rate),
            "cached_rate": str(price.cached_rate)
            if price.cached_rate is not None
            else None,
            "source_url": price.source_url,
            "billing_note": price.billing_note,
        },
    }


@router.get("/models")
def list_models(request: Request, user=Depends(current_user), db=Depends(db_session)):
    models = db.scalars(
        select(Model).where(Model.enabled.is_(True)).order_by(Model.created_at)
    ).all()
    return {
        "models": [public_model(db, m) for m in models],
        "provider_configured": request.app.state.provider.configured,
    }


@router.get("/admin/models")
def admin_models(request: Request, user=Depends(administrator), db=Depends(db_session)):
    return {
        "models": [
            public_model(db, m)
            for m in db.scalars(select(Model).order_by(Model.created_at))
        ],
        "provider_configured": request.app.state.provider.configured,
        "base_url": request.app.state.settings.model_base_url,
    }


@router.post("/admin/models", status_code=201)
def create_model(data: ModelInput, user=Depends(administrator), db=Depends(db_session)):
    model = Model(name=data.name, display_name=data.display_name, enabled=data.enabled)
    db.add(model)
    try:
        db.flush()
        db.add(
            Price(
                model_id=model.id,
                version=1,
                **data.model_dump(exclude={"name", "display_name", "enabled"}),
            )
        )
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "模型名称已存在") from None
    return public_model(db, model)


@router.put("/admin/models/{model_id}")
def update_model(
    model_id: str, data: ModelInput, user=Depends(administrator), db=Depends(db_session)
):
    model = db.scalar(select(Model).where(Model.id == model_id).with_for_update())
    if model is None:
        raise HTTPException(404, "模型不存在")
    if data.name != model.name:
        raise HTTPException(422, "已有模型的供应商标识不可修改，请新增模型")
    model.display_name, model.enabled = data.display_name, data.enabled
    price = latest_price(db, model_id)
    fields = data.model_dump(exclude={"name", "display_name", "enabled"})
    if any(getattr(price, name) != value for name, value in fields.items()):
        db.add(Price(model_id=model_id, version=price.version + 1, **fields))
    db.commit()
    return public_model(db, model)
