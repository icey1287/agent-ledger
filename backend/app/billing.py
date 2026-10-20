"""用量口径与金额计算集中在这里，HTTP 和执行器不自行算账。"""

from decimal import Decimal


class UnknownUsage(ValueError):
    pass


def calculate(usage, price):
    if not isinstance(usage, dict):
        raise UnknownUsage("供应商未返回可确认的用量")
    incoming, outgoing = usage.get("prompt_tokens"), usage.get("completion_tokens")
    details = usage.get("prompt_tokens_details") or {}
    cached = details.get("cached_tokens", 0) if isinstance(details, dict) else None
    if (
        any(type(v) is not int or v < 0 for v in (incoming, outgoing, cached))
        or cached > incoming
    ):
        raise UnknownUsage("供应商 token 计数不完整或不合法")
    if cached and price.cached_rate is None:
        raise UnknownUsage("存在缓存输入，但价格版本未配置缓存费率")
    cost = (
        Decimal(incoming - cached) * price.input_rate
        + Decimal(outgoing) * price.output_rate
        + Decimal(cached) * (price.cached_rate or Decimal(0))
    ) / Decimal(1_000_000)
    return incoming, outgoing, cached, cost
