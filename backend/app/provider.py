"""OpenAI 兼容接口 Adapter；不设置 token 上限，不自动重试。"""

import httpx


class RejectedRequest(Exception):
    pass


class UncertainRequest(Exception):
    pass


class ModelClient:
    def __init__(self, settings, transport=None):
        self.settings = settings
        self.http = httpx.Client(timeout=settings.model_timeout, transport=transport)

    @property
    def configured(self):
        return bool(
            self.settings.model_base_url
            and self.settings.model_api_key.get_secret_value()
        )

    def chat(self, model, messages, tools):
        if not self.configured:
            raise RejectedRequest("尚未配置模型接口和 API Key")
        base = self.settings.model_base_url.rstrip("/")
        if base.endswith("/chat/completions"):
            base = base[: -len("/chat/completions")]
        try:
            response = self.http.post(
                base + "/chat/completions",
                headers={
                    "Authorization": "Bearer "
                    + self.settings.model_api_key.get_secret_value()
                },
                json={"model": model, "messages": messages, "tools": tools},
            )
        except httpx.HTTPError:
            raise UncertainRequest("模型连接中断或超时，用量待核实") from None
        if response.status_code in (400, 401, 403, 404, 422, 429):
            raise RejectedRequest(
                f"供应商拒绝请求（HTTP {response.status_code}），请检查模型、密钥、上下文或供应商额度"
            )
        if not response.is_success:
            raise UncertainRequest(
                f"供应商异常（HTTP {response.status_code}），用量待核实"
            )
        try:
            result = response.json()
            if not isinstance(result, dict):
                raise ValueError
            return result
        except (ValueError, TypeError):
            raise UncertainRequest("供应商响应格式异常，用量待核实") from None

    def close(self):
        self.http.close()
