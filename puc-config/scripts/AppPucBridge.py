"""JSON-lines bridge for APP PUC login and group batch operations.

The launcher owns this process and communicates through stdin/stdout.  The
protocol implementation remains in the app_puc_login and app_puc_group_batch
packages; this module only adapts their lifecycle and events for a UI.
"""

from __future__ import annotations

import json
import queue
import sys
import threading
from dataclasses import asdict, is_dataclass
from enum import Enum
from pathlib import Path
from typing import Any


def _add_local_packages() -> None:
    """Make the repository packages importable when the bridge is run in-place."""
    repo_root = Path(__file__).resolve().parents[2]
    for package_root in (repo_root / "app_puc_group_batch", repo_root / "app_puc_login"):
        path = str(package_root)
        if path not in sys.path:
            sys.path.insert(0, path)


_add_local_packages()

from app_puc_group_batch import AppGroupMemberInput, AppPucGroupBatchService
from app_puc_login import LoginConfig, PucLoginClient, get_active_app_session
from app_puc_login.events import LoginEvent


_SECRET_KEYS = {"password", "token", "access_token", "authorization"}


def _json_value(value: Any) -> Any:
    """Convert enums/dataclasses and recursively redact secret-bearing fields."""
    if is_dataclass(value):
        value = asdict(value)
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, dict):
        return {
            str(key): "***" if str(key).lower() in _SECRET_KEYS else _json_value(item)
            for key, item in value.items()
        }
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    return value


class AppPucBridge:
    """Adapt one login client and one batch service to JSON-lines commands."""

    def __init__(self) -> None:
        self.client = PucLoginClient()
        self.batch_service = AppPucGroupBatchService()
        self._commands: queue.Queue[dict[str, Any] | None] = queue.Queue()
        self._events: queue.Queue[dict[str, Any]] = queue.Queue()
        self._reader_done = threading.Event()
        self._batch_thread: threading.Thread | None = None
        self._batch_lock = threading.Lock()
        self._password = ""

    def run(self) -> None:
        reader = threading.Thread(target=self._read_commands, name="app-puc-bridge-input", daemon=True)
        reader.start()
        try:
            while True:
                self._drain_events()
                try:
                    command = self._commands.get(timeout=0.05)
                except queue.Empty:
                    command = "__none__"
                if command != "__none__":
                    if command is None:
                        self._shutdown()
                    else:
                        self._handle_command(command)
                self._drain_events()
                if (
                    self._reader_done.is_set()
                    and self._commands.empty()
                    and self._events.empty()
                    and not self.client.is_running
                    and not self._batch_is_running()
                ):
                    break
        finally:
            self._shutdown()
            self._drain_events()

    def _read_commands(self) -> None:
        try:
            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue
                try:
                    command = json.loads(line)
                except json.JSONDecodeError as exc:
                    self._commands.put({"_invalid": f"invalid JSON: {exc.msg}"})
                    continue
                if not isinstance(command, dict):
                    self._commands.put({"_invalid": "command must be a JSON object"})
                    continue
                self._commands.put(command)
        finally:
            self._reader_done.set()
            self._commands.put(None)

    def _handle_command(self, command: dict[str, Any]) -> None:
        if "_invalid" in command:
            self._write({"type": "response", "ok": False, "error": {"message": command["_invalid"]}})
            return
        name = str(command.get("command") or "").strip()
        try:
            if name == "login":
                self._login(command)
            elif name == "stop":
                self._stop()
            elif name == "status":
                self._status()
            elif name == "batch_create_groups":
                self._batch(command)
            else:
                self._error(name, "unsupported command")
        except Exception as exc:
            self._error(name, str(exc))

    def _login(self, command: dict[str, Any]) -> None:
        required = ("account", "password", "server")
        missing = [name for name in required if not str(command.get(name) or "").strip()]
        if missing:
            raise ValueError(f"missing required field: {', '.join(missing)}")
        if self.client.is_running:
            raise RuntimeError("client is already running")
        password = str(command["password"])
        self._password = password
        options: dict[str, Any] = {
            "account": str(command["account"]).strip(),
            "password": password,
            "server": str(command["server"]).strip(),
        }
        for key in (
            "imei_list", "sn", "request_timeout", "websocket_timeout",
            "verify_tls", "heartbeat_idle", "reconnect_delays",
        ):
            if key in command:
                options[key] = command[key]
        if isinstance(options.get("imei_list"), list):
            options["imei_list"] = tuple(str(item) for item in options["imei_list"])
        if isinstance(options.get("reconnect_delays"), list):
            options["reconnect_delays"] = tuple(float(item) for item in options["reconnect_delays"])
        config = LoginConfig(**options)
        self.client.start(config, self._on_login_event)
        self._write({"type": "response", "command": "login", "ok": True, "data": {"state": "starting"}})

    def _stop(self) -> None:
        self.client.stop()
        self._write({"type": "response", "command": "stop", "ok": True, "data": {"state": "stopped"}})

    def _status(self) -> None:
        self._write({
            "type": "response", "command": "status", "ok": True,
            "data": {"online": self._online(), "running": self.client.is_running, "session": self._session()},
        })

    def _batch(self, command: dict[str, Any]) -> None:
        if not self._online():
            raise ValueError("active APP PUC session is required")
        members = command.get("members")
        if not isinstance(members, list) or not members:
            raise ValueError("members must be a non-empty array")
        try:
            group_count = int(command.get("group_count"))
        except (TypeError, ValueError):
            raise ValueError("group_count must be a positive integer") from None
        if group_count <= 0:
            raise ValueError("group_count must be a positive integer")
        inputs = []
        for member in members:
            if not isinstance(member, dict):
                raise ValueError("each member must be an object")
            inputs.append(AppGroupMemberInput(
                account=str(member.get("account") or ""),
                app_puc_id=str(member.get("app_puc_id") or ""),
            ))
        with self._batch_lock:
            if self._batch_is_running():
                raise RuntimeError("another APP PUC group batch is running")
            self._batch_thread = threading.Thread(
                target=self._run_batch,
                args=(inputs, group_count),
                name="app-puc-group-batch",
                daemon=True,
            )
            self._batch_thread.start()
        self._write({"type": "response", "command": "batch_create_groups", "ok": True, "data": {"state": "started"}})

    def _run_batch(self, members: list[AppGroupMemberInput], group_count: int) -> None:
        try:
            summary = self.batch_service.create_groups(
                members=members,
                group_count=group_count,
                on_progress=lambda progress: self._events.put({"kind": "batch_progress", "value": progress}),
            )
            self._events.put({"kind": "batch_done", "value": summary})
        except Exception as exc:
            self._events.put({"kind": "batch_error", "value": str(exc)})

    def _on_login_event(self, event: LoginEvent) -> None:
        self._events.put({"kind": "login_event", "value": event})

    def _drain_events(self) -> None:
        while True:
            try:
                item = self._events.get_nowait()
            except queue.Empty:
                return
            kind = item["kind"]
            if kind == "login_event":
                event: LoginEvent = item["value"]
                self._write({
                    "type": "event", "event": event.event_type.value,
                    "timestamp": event.timestamp, "phase": event.phase.value,
                    "message": self._safe_text(event.message), "code": event.code,
                    "payload": _json_value(event.payload), "online": self._event_online(event),
                    "session": self._session(),
                })
            elif kind == "batch_progress":
                self._write({"type": "event", "event": "batch_progress", "progress": _json_value(item["value"])})
            elif kind == "batch_done":
                self._write({"type": "response", "command": "batch_create_groups", "ok": True, "data": {"state": "completed", "summary": _json_value(item["value"])}})
            elif kind == "batch_error":
                self._error("batch_create_groups", str(item["value"]))

    def _shutdown(self) -> None:
        if self.client.is_running:
            try:
                self.client.stop()
            except Exception:
                pass

    def _batch_is_running(self) -> bool:
        thread = self._batch_thread
        return thread is not None and thread.is_alive()

    def _online(self) -> bool:
        return self.client.is_running and get_active_app_session() is not None

    def _event_online(self, event: LoginEvent) -> bool:
        # The client emits disconnected before clearing its session registry.
        # Derive the UI state from the lifecycle event so that transition is
        # shown as offline immediately rather than one event late.
        if event.event_type.value in {"disconnected", "reconnecting", "error", "stopped"}:
            return False
        if event.event_type.value == "login_success":
            return True
        return self._online()

    @staticmethod
    def _session() -> dict[str, str] | None:
        session = get_active_app_session()
        if session is None:
            return None
        return {
            "app_puc_id": session.app_puc_id,
            "account": session.app_user_id,
            "realm": session.app_realm,
            "alias": session.app_user_alias,
        }

    def _safe_text(self, text: str) -> str:
        if not text:
            return ""
        return text.replace(self._password, "***") if self._password else text

    def _error(self, command: str, message: str) -> None:
        self._write({"type": "response", "command": command or None, "ok": False, "error": {"message": self._safe_text(message)}})

    @staticmethod
    def _write(value: dict[str, Any]) -> None:
        sys.stdout.write(json.dumps(_json_value(value), ensure_ascii=False, separators=(",", ":")) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    AppPucBridge().run()
