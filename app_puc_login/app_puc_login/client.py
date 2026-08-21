"""Threaded PUC login lifecycle, heartbeat, and reconnect management."""

from __future__ import annotations

import json
import threading
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from .config import LoginConfig
from .events import (
    AuthenticationError,
    ClientStateError,
    EventType,
    LoginEvent,
    LoginPhase,
    ReceiveTimeout,
    RequestDisconnected,
    RequestTimeout,
    TransportError,
)
from .protocol import (
    FrameError,
    MessageType,
    build_authorization,
    build_login_payload,
    decode_frame,
    encode_frame,
)
from .transport import PucTransport
from .session import clear_active_app_session, publish_active_app_session


EventCallback = Callable[[LoginEvent], None]
TransportFactory = Callable[[LoginConfig], Any]


@dataclass
class _PendingRequest:
    expected_ack: str
    ready: threading.Event = field(default_factory=threading.Event)
    response: dict[str, Any] | None = None
    error: Exception | None = None


class PucLoginClient:
    """Run one PUC account session without blocking the caller's GUI thread."""

    def __init__(self, *, transport_factory: TransportFactory | None = None) -> None:
        self._transport_factory = transport_factory or PucTransport
        self._lock = threading.Lock()
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._transport: Any = None
        self._callback: EventCallback | None = None
        self._attempt_authenticated = False
        self._active_session_id: str | None = None
        self._pending_lock = threading.Lock()
        self._pending: dict[str, _PendingRequest] = {}

    @property
    def is_running(self) -> bool:
        thread = self._thread
        return thread is not None and thread.is_alive()

    def start(self, config: LoginConfig, on_event: EventCallback) -> None:
        with self._lock:
            if self.is_running:
                raise ClientStateError("client is already running")
            self._stop_event.clear()
            self._callback = on_event
            self._thread = threading.Thread(
                target=self._run,
                args=(config,),
                name="puc-login-client",
                daemon=True,
            )
            self._thread.start()

    def stop(self, timeout: float = 5.0) -> None:
        self._stop_event.set()
        self._clear_session()
        self._fail_pending(RequestDisconnected("PUC session disconnected"))
        with self._lock:
            transport = self._transport
            thread = self._thread
        if transport is not None:
            transport.close()
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout)
            if thread.is_alive():
                raise ClientStateError("client worker did not stop in time")

    def _emit(
        self,
        event_type: EventType,
        phase: LoginPhase,
        *,
        message: str = "",
        code: int | None = None,
        payload: Any = None,
    ) -> None:
        callback = self._callback
        if callback is None:
            return
        event = LoginEvent.create(
            event_type,
            phase,
            message=message,
            code=code,
            payload=payload,
        )
        try:
            callback(event)
        except Exception:
            # GUI callback failures must not terminate the connection worker.
            pass

    def _run(self, config: LoginConfig) -> None:
        had_success = False
        reconnect_attempt = 0
        try:
            while not self._stop_event.is_set():
                transport = self._transport_factory(config)
                self._attempt_authenticated = False
                with self._lock:
                    self._transport = transport
                try:
                    self._login_and_receive(config, transport)
                    return
                except AuthenticationError as exc:
                    self._emit(
                        EventType.ERROR,
                        LoginPhase.LOGIN,
                        message=str(exc),
                        code=exc.code,
                        payload=exc.payload,
                    )
                    return
                except TransportError as exc:
                    if self._stop_event.is_set():
                        return
                    had_success = had_success or self._attempt_authenticated
                    if not had_success:
                        self._emit(
                            EventType.ERROR,
                            LoginPhase.WEBSOCKET,
                            message=str(exc),
                        )
                        return
                    self._emit(
                        EventType.DISCONNECTED,
                        LoginPhase.ONLINE,
                        message=str(exc),
                    )
                    delays = config.reconnect_delays
                    delay = delays[min(reconnect_attempt, len(delays) - 1)]
                    reconnect_attempt += 1
                    self._emit(
                        EventType.RECONNECTING,
                        LoginPhase.RECONNECT,
                        message="reconnecting after network failure",
                        payload={"delay": delay, "attempt": reconnect_attempt},
                    )
                    if self._stop_event.wait(delay):
                        return
                except (FrameError, ValueError, TypeError, json.JSONDecodeError) as exc:
                    self._emit(EventType.ERROR, LoginPhase.LOGIN, message=str(exc))
                    return
                finally:
                    self._clear_session()
                    self._fail_pending(RequestDisconnected("PUC session disconnected"))
                    transport.close()
                    with self._lock:
                        if self._transport is transport:
                            self._transport = None

                had_success = True
        finally:
            self._emit(EventType.STOPPED, LoginPhase.LIFECYCLE, message="client stopped")

    def _login_and_receive(self, config: LoginConfig, transport: Any) -> None:
        self._emit(EventType.CONNECTING, LoginPhase.TOKEN, message="requesting token")
        authorization = build_authorization(config.account, config.password)
        token = transport.request_token(authorization)
        self._emit(EventType.TOKEN_ACQUIRED, LoginPhase.TOKEN, message="token acquired")

        transport.connect()
        self._emit(
            EventType.WEBSOCKET_CONNECTED,
            LoginPhase.WEBSOCKET,
            message="websocket connected",
        )
        payload = build_login_payload(config, token)
        transport.send_frame(
            encode_frame(json.dumps(payload, separators=(",", ":")), MessageType.AUTH)
        )

        while not self._stop_event.is_set():
            try:
                raw = transport.recv()
            except ReceiveTimeout:
                transport.send_frame(encode_frame(b"", MessageType.HEARTBEAT_ACK))
                continue
            if not isinstance(raw, bytes):
                raise FrameError("PUC websocket returned a non-binary frame")
            frame = decode_frame(raw)
            if frame.message_type is MessageType.HEARTBEAT:
                transport.send_frame(encode_frame(b"", MessageType.HEARTBEAT_ACK))
                continue
            if frame.message_type is not MessageType.AUTH_ACK:
                continue

            response = json.loads(frame.body.decode("utf-8"))
            result = response.get("result")
            if result != 0:
                raise AuthenticationError(
                    "login rejected",
                    code=result,
                    payload=response,
                )
            app_puc_id = str(response.get("puc_id") or "").strip()
            if not app_puc_id:
                raise ValueError("login ACK is missing puc_id")
            session = publish_active_app_session(
                app_puc_id=app_puc_id,
                app_user_id=str(response.get("user_id") or config.account),
                app_realm=str(response.get("realm") or config.realm),
                app_user_alias=str(
                    response.get("user_alias") or response.get("alias") or config.account
                ),
                client=self,
            )
            self._active_session_id = session.app_session_id
            self._emit(
                EventType.LOGIN_SUCCESS,
                LoginPhase.ONLINE,
                message="login succeeded",
                code=0,
                payload=response,
            )
            self._attempt_authenticated = True
            break

        while not self._stop_event.is_set():
            try:
                raw = transport.recv()
            except ReceiveTimeout:
                transport.send_frame(encode_frame(b"", MessageType.HEARTBEAT_ACK))
                continue
            if not isinstance(raw, bytes):
                raise FrameError("PUC websocket returned a non-binary frame")
            frame = decode_frame(raw)
            if frame.message_type is MessageType.HEARTBEAT:
                transport.send_frame(encode_frame(b"", MessageType.HEARTBEAT_ACK))
                continue
            body_text = frame.body.decode("utf-8")
            try:
                body: Any = json.loads(body_text)
            except json.JSONDecodeError:
                body = body_text
            if isinstance(body, dict) and self._resolve_pending(body):
                continue
            self._emit(EventType.MESSAGE, LoginPhase.ONLINE, payload=body)

    def request(
        self, payload: dict[str, Any], *, expected_ack: str, timeout: float = 30.0,
    ) -> dict[str, Any]:
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        request_payload = dict(payload)
        guid = str(uuid.uuid4())
        request_payload["cmd_guid"] = guid
        pending = _PendingRequest(expected_ack)
        with self._pending_lock:
            if not self._attempt_authenticated or self._transport is None:
                raise ClientStateError("client is not authenticated")
            self._pending[guid] = pending
            transport = self._transport
        try:
            transport.send_frame(encode_frame(
                json.dumps(request_payload, separators=(",", ":")), MessageType.DEFAULT
            ))
        except Exception:
            with self._pending_lock:
                self._pending.pop(guid, None)
            raise
        if not pending.ready.wait(timeout):
            with self._pending_lock:
                self._pending.pop(guid, None)
            raise RequestTimeout(f"request timed out: {expected_ack}")
        if pending.error is not None:
            raise pending.error
        if pending.response is None:
            raise RequestDisconnected("PUC session disconnected")
        return pending.response

    def _resolve_pending(self, body: dict[str, Any]) -> bool:
        guid = body.get("cmd_guid")
        command = body.get("cmd_name")
        if not isinstance(guid, str):
            return False
        with self._pending_lock:
            pending = self._pending.get(guid)
            if pending is None or command != pending.expected_ack:
                return False
            self._pending.pop(guid)
            pending.response = body
        pending.ready.set()
        return True

    def _fail_pending(self, error: Exception) -> None:
        with self._pending_lock:
            pending = list(self._pending.values())
            self._pending.clear()
        for item in pending:
            item.error = error
            item.ready.set()

    def _clear_session(self) -> None:
        session_id = self._active_session_id
        self._active_session_id = None
        if session_id is not None:
            clear_active_app_session(session_id)
