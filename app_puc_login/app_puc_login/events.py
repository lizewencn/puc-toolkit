"""Structured, secret-safe events emitted by the login client."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Any


class EventType(str, Enum):
    CONNECTING = "connecting"
    TOKEN_ACQUIRED = "token_acquired"
    WEBSOCKET_CONNECTED = "websocket_connected"
    LOGIN_SUCCESS = "login_success"
    MESSAGE = "message"
    RECONNECTING = "reconnecting"
    DISCONNECTED = "disconnected"
    ERROR = "error"
    STOPPED = "stopped"


class LoginPhase(str, Enum):
    VALIDATION = "validation"
    TOKEN = "token"
    WEBSOCKET = "websocket"
    LOGIN = "login"
    ONLINE = "online"
    RECONNECT = "reconnect"
    LIFECYCLE = "lifecycle"


SECRET_KEYS = {"password", "token", "access_token", "authorization"}


def redact(value: Any) -> Any:
    """Copy JSON-like data while masking credential-bearing fields."""
    if isinstance(value, dict):
        return {
            key: "***" if str(key).lower() in SECRET_KEYS else redact(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, tuple):
        return tuple(redact(item) for item in value)
    return value


@dataclass(frozen=True)
class LoginEvent:
    event_type: EventType
    timestamp: str
    phase: LoginPhase
    message: str = ""
    code: int | None = None
    payload: Any = None

    @classmethod
    def create(
        cls,
        event_type: EventType,
        phase: LoginPhase,
        *,
        message: str = "",
        code: int | None = None,
        payload: Any = None,
    ) -> "LoginEvent":
        return cls(
            event_type=event_type,
            timestamp=datetime.now(timezone.utc).isoformat(),
            phase=phase,
            message=message,
            code=code,
            payload=redact(payload),
        )


class PucLoginError(RuntimeError):
    """Base class for client-visible PUC failures."""


class AuthenticationError(PucLoginError):
    def __init__(self, message: str, *, code: int | None = None, payload: Any = None) -> None:
        super().__init__(message)
        self.code = code
        self.payload = redact(payload)


class TransportError(PucLoginError):
    """Retryable network or transport failure."""


class ReceiveTimeout(TransportError):
    """WebSocket receive idle timeout used to drive active heartbeats."""


class ClientStateError(PucLoginError):
    """Invalid start/stop lifecycle operation."""


class RequestTimeout(PucLoginError):
    """An authenticated command did not receive its matching ACK in time."""


class RequestDisconnected(PucLoginError):
    """An authenticated command was interrupted by connection loss."""
