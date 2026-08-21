"""Configuration and endpoint derivation for PUC login."""

from __future__ import annotations

import socket
import uuid
from dataclasses import dataclass, field
from urllib.parse import urlsplit, urlunsplit

PUC_REALM = "puc.com"


def default_device_id() -> str:
    """Return a stable, non-Android identifier for the current machine."""
    return uuid.uuid5(uuid.NAMESPACE_DNS, socket.gethostname()).hex


@dataclass(frozen=True)
class LoginConfig:
    """External inputs and runtime settings for one login client."""

    account: str
    password: str
    server: str
    realm: str = field(default=PUC_REALM, init=False)
    imei_list: tuple[str, ...] = field(default_factory=lambda: (default_device_id(),))
    sn: str = field(default_factory=default_device_id)
    request_timeout: float = 15.0
    websocket_timeout: float = 20.0
    verify_tls: bool = True
    heartbeat_idle: float = 15.0
    reconnect_delays: tuple[float, ...] = (1, 2, 4, 8, 16, 30)

    def __post_init__(self) -> None:
        for name in ("account", "password"):
            if not getattr(self, name):
                raise ValueError(f"{name} must not be empty")

        parsed = urlsplit(self.server)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("server must be an http or https URL")
        if parsed.query or parsed.fragment:
            raise ValueError("server must not contain a query or fragment")
        if self.request_timeout <= 0 or self.websocket_timeout <= 0 or self.heartbeat_idle <= 0:
            raise ValueError("timeouts must be positive")
        if not self.reconnect_delays or any(delay <= 0 for delay in self.reconnect_delays):
            raise ValueError("reconnect delays must contain positive values")
        if not self.imei_list or any(not value for value in self.imei_list) or not self.sn:
            raise ValueError("device identifiers must not be empty")

        normalized_path = parsed.path.rstrip("/")
        normalized = urlunsplit((parsed.scheme, parsed.netloc, normalized_path, "", ""))
        object.__setattr__(self, "server", normalized)

    @property
    def token_url(self) -> str:
        return f"{self.server}/has"

    @property
    def websocket_url(self) -> str:
        parsed = urlsplit(self.server)
        scheme = "wss" if parsed.scheme == "https" else "ws"
        return urlunsplit((scheme, parsed.netloc, f"{parsed.path}/wsas", "", ""))
