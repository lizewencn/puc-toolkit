import json
import threading
import time

from app_puc_login.client import PucLoginClient
from app_puc_login.config import LoginConfig
from app_puc_login.events import EventType, ReceiveTimeout, TransportError
from app_puc_login.protocol import MessageType, decode_frame, encode_frame
from app_puc_login.session import get_active_app_session


class BlockingTransport:
    def __init__(self, incoming):
        self.incoming = list(incoming)
        self.sent = []
        self.closed = threading.Event()
        self.token_calls = 0

    def request_token(self, authorization):
        self.token_calls += 1
        assert authorization.startswith("Basic ")
        return "token-1"

    def connect(self):
        pass

    def send_frame(self, data):
        self.sent.append(data)

    def recv(self):
        if self.incoming:
            item = self.incoming.pop(0)
            if isinstance(item, Exception):
                raise item
            return item
        self.closed.wait(2)
        raise TransportError("closed")

    def close(self):
        self.closed.set()


def ack(result=0, **extra):
    body = json.dumps({"result": result, "puc_id": "test-puc-id", **extra})
    return encode_frame(body, MessageType.AUTH_ACK)


def wait_for(predicate, timeout=2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("condition was not reached")


def make_config(**changes):
    values = {
        "account": "alice",
        "password": "secret",
        "server": "https://puc.test",
        "reconnect_delays": (0.01,),
    }
    values.update(changes)
    return LoginConfig(**values)


def test_client_logs_in_replies_to_heartbeat_and_stops():
    transport = BlockingTransport(
        [encode_frame(b"", MessageType.HEARTBEAT), ack(0, account="alice")]
    )
    events = []
    client = PucLoginClient(transport_factory=lambda _: transport)

    client.start(make_config(), events.append)
    wait_for(lambda: any(event.event_type is EventType.LOGIN_SUCCESS for event in events))

    sent_types = [decode_frame(frame).message_type for frame in transport.sent]
    assert sent_types == [MessageType.AUTH, MessageType.HEARTBEAT_ACK]
    assert client.is_running

    client.stop()
    assert not client.is_running
    assert events[-1].event_type is EventType.STOPPED


def test_idle_receive_timeout_sends_active_heartbeat_ack():
    transport = BlockingTransport([ack(), ReceiveTimeout("idle")])
    events = []
    client = PucLoginClient(transport_factory=lambda _: transport)

    client.start(make_config(), events.append)
    wait_for(lambda: len(transport.sent) >= 2)

    sent_types = [decode_frame(frame).message_type for frame in transport.sent]
    assert sent_types[:2] == [MessageType.AUTH, MessageType.HEARTBEAT_ACK]
    client.stop()


def test_ordinary_message_is_forwarded_with_secrets_redacted():
    message = encode_frame(
        json.dumps({"cmd_name": "notice", "token": "server-secret"}),
        MessageType.DEFAULT,
    )
    transport = BlockingTransport([ack(), message])
    events = []
    client = PucLoginClient(transport_factory=lambda _: transport)

    client.start(make_config(), events.append)
    wait_for(lambda: any(event.event_type is EventType.MESSAGE for event in events))

    event = next(event for event in events if event.event_type is EventType.MESSAGE)
    assert event.payload == {"cmd_name": "notice", "token": "***"}
    client.stop()


def test_terminal_login_failure_does_not_reconnect():
    transport = BlockingTransport([ack(52400053, remaining_chance=2)])
    events = []
    client = PucLoginClient(transport_factory=lambda _: transport)

    client.start(make_config(), events.append)
    wait_for(lambda: not client.is_running)

    assert transport.token_calls == 1
    error = next(event for event in events if event.event_type is EventType.ERROR)
    assert error.code == 52400053
    assert not any(event.event_type is EventType.RECONNECTING for event in events)


def test_network_disconnect_after_success_performs_full_login_again():
    first = BlockingTransport([ack(), TransportError("lost")])
    second = BlockingTransport([ack()])
    transports = iter([first, second])
    events = []
    client = PucLoginClient(transport_factory=lambda _: next(transports))

    client.start(make_config(), events.append)
    wait_for(
        lambda: sum(event.event_type is EventType.LOGIN_SUCCESS for event in events) == 2
    )

    assert first.token_calls == second.token_calls == 1
    reconnect = next(event for event in events if event.event_type is EventType.RECONNECTING)
    assert reconnect.payload == {"delay": 0.01, "attempt": 1}
    client.stop()


def test_callback_exception_does_not_kill_worker():
    transport = BlockingTransport([ack()])
    events = []

    def callback(event):
        events.append(event)
        if event.event_type is EventType.CONNECTING:
            raise RuntimeError("GUI callback failed")

    client = PucLoginClient(transport_factory=lambda _: transport)
    client.start(make_config(), callback)
    wait_for(lambda: any(event.event_type is EventType.LOGIN_SUCCESS for event in events))
    client.stop()


def test_login_publishes_session_and_stop_clears_it():
    transport = BlockingTransport([
        ack(0, puc_id="9003", user_id="lzw93003", realm="puc.com",
            user_alias="Dispatcher")
    ])
    client = PucLoginClient(transport_factory=lambda _: transport)

    client.start(make_config(account="lzw93003"), lambda _: None)
    wait_for(lambda: get_active_app_session() is not None)
    session = get_active_app_session()
    assert session.app_puc_id == "9003"
    assert session.app_user_id == "lzw93003"
    assert session.app_user_alias == "Dispatcher"
    assert session.client is client

    client.stop()
    assert get_active_app_session() is None
