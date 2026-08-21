"""HTTP and WebSocket transport adapters for PUC login."""

from __future__ import annotations

import ssl
from typing import Any, Callable

import requests
import websocket

from .config import LoginConfig
from .events import AuthenticationError, ReceiveTimeout, TransportError


class PucTransport:
    """One connection attempt against the exact configured source server."""

    def __init__(
        self,
        config: LoginConfig,
        *,
        session: requests.Session | None = None,
        websocket_factory: Callable[..., Any] | None = None,
    ) -> None:
        self.config = config
        self._session = session or requests.Session()
        self._websocket_factory = websocket_factory or websocket.create_connection
        self._socket: Any = None

    def request_token(self, authorization: str) -> str:
        try:
            response = self._session.post(
                self.config.token_url,
                headers={
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Authorization": authorization,
                },
                timeout=self.config.request_timeout,
                verify=self.config.verify_tls,
            )
            response.raise_for_status()
            payload = response.json()
        except (requests.RequestException, OSError, ValueError) as exc:
            raise TransportError(f"token request failed: {exc}") from exc

        result = payload.get("result") if isinstance(payload, dict) else None
        token = payload.get("access_token") if isinstance(payload, dict) else None
        if result != 0 or not token:
            raise AuthenticationError("token request rejected", code=result, payload=payload)
        return str(token)

    def connect(self) -> None:
        cert_reqs = ssl.CERT_REQUIRED if self.config.verify_tls else ssl.CERT_NONE
        try:
            self._socket = self._websocket_factory(
                self.config.websocket_url,
                timeout=self.config.websocket_timeout,
                sslopt={"cert_reqs": cert_reqs},
            )
            self._socket.settimeout(self.config.heartbeat_idle)
        except (OSError, websocket.WebSocketException) as exc:
            raise TransportError(f"websocket connection failed: {exc}") from exc

    def send_frame(self, data: bytes) -> None:
        if self._socket is None:
            raise TransportError("websocket is not connected")
        try:
            self._socket.send_binary(data)
        except (OSError, websocket.WebSocketException) as exc:
            raise TransportError(f"websocket send failed: {exc}") from exc

    def recv(self) -> bytes | str:
        if self._socket is None:
            raise TransportError("websocket is not connected")
        try:
            data = self._socket.recv()
        except websocket.WebSocketTimeoutException as exc:
            raise ReceiveTimeout("websocket receive timed out") from exc
        except (OSError, websocket.WebSocketException) as exc:
            raise TransportError(f"websocket receive failed: {exc}") from exc
        if data in (None, b"", ""):
            raise TransportError("websocket closed")
        return data

    def close(self) -> None:
        socket, self._socket = self._socket, None
        if socket is not None:
            try:
                socket.close()
            except (OSError, websocket.WebSocketException):
                pass
        self._session.close()
