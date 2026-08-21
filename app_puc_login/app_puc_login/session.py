"""Thread-safe process-local APP PUC session registry."""

from __future__ import annotations

import threading
import uuid
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .client import PucLoginClient


@dataclass(frozen=True)
class AppPucSession:
    app_puc_id: str
    app_user_id: str
    app_realm: str
    app_user_alias: str
    app_session_id: str
    client: "PucLoginClient"


_lock = threading.Lock()
_active: AppPucSession | None = None


def get_active_app_session() -> AppPucSession | None:
    with _lock:
        return _active


def publish_active_app_session(
    *, app_puc_id: str, app_user_id: str, app_realm: str,
    app_user_alias: str, client: "PucLoginClient",
) -> AppPucSession:
    global _active
    snapshot = AppPucSession(
        app_puc_id, app_user_id, app_realm, app_user_alias,
        str(uuid.uuid4()), client,
    )
    with _lock:
        _active = snapshot
    return snapshot


def clear_active_app_session(app_session_id: str | None = None) -> None:
    global _active
    with _lock:
        if app_session_id is None or (
            _active is not None and _active.app_session_id == app_session_id
        ):
            _active = None
