import json
import threading
import time

import pytest

from app_puc_login.client import PucLoginClient
from app_puc_login.events import ClientStateError, RequestTimeout
from app_puc_login.protocol import MessageType, decode_frame, encode_frame


class RequestTransport:
    def __init__(self):
        self.sent = []
        self.incoming = []
        self.ready = threading.Event()
        self.closed = threading.Event()
        self.authenticated_response = {"result": 0, "account_list": []}

    def request_token(self, _): return "token"
    def post_authenticated(self, payload, token):
        self.http_request = (payload, token)
        if callable(self.authenticated_response):
            return self.authenticated_response(payload)
        return self.authenticated_response
    def connect(self): pass
    def close(self): self.closed.set(); self.ready.set()
    def send_frame(self, frame): self.sent.append(frame)
    def recv(self):
        while not self.incoming:
            self.ready.wait(0.05); self.ready.clear()
            if self.closed.is_set():
                from app_puc_login.events import TransportError
                raise TransportError("closed")
        return self.incoming.pop(0)
    def push(self, body, message_type=MessageType.DEFAULT):
        self.incoming.append(encode_frame(json.dumps(body), message_type))
        self.ready.set()


def config():
    from app_puc_login.config import LoginConfig
    return LoginConfig(account="owner", password="secret", server="https://puc.test")


def wait_for(predicate):
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if predicate(): return
        time.sleep(0.01)
    raise AssertionError("timeout")


def logged_in_client(events=None):
    transport = RequestTransport()
    transport.push({"result": 0, "puc_id": "1", "user_id": "owner"}, MessageType.AUTH_ACK)
    client = PucLoginClient(transport_factory=lambda _: transport)
    client.start(config(), (events if events is not None else []).append)
    wait_for(lambda: len(transport.sent) == 1)
    return client, transport


def test_request_posts_http_and_returns_matching_response():
    client, transport = logged_in_client()
    transport.authenticated_response = lambda payload: {
        "cmd_name": "chat_create_group_ack",
        "cmd_guid": payload["cmd_guid"],
        "result": 0,
    }

    result = client.request(
        {"cmd_name": "chat_create_group"}, expected_ack="chat_create_group_ack",
    )

    assert result["result"] == 0
    sent, token = transport.http_request
    assert sent["cmd_name"] == "chat_create_group"
    assert len(sent["cmd_guid"]) == 36
    assert token == "token"
    assert len(transport.sent) == 1
    client.stop()


def test_request_rejects_unexpected_http_ack_and_unauthenticated_error():
    client, transport = logged_in_client()
    transport.authenticated_response = {"cmd_name": "wrong_ack", "result": 0}
    with pytest.raises(Exception, match="wrong_ack"):
        client.request({"cmd_name": "x"}, expected_ack="x_ack")
    client.stop()
    with pytest.raises(ClientStateError):
        client.request({"cmd_name": "x"}, expected_ack="x_ack")


def test_authenticated_http_request_reuses_private_login_token():
    client, transport = logged_in_client()

    response = client.post_authenticated({"cmd_name": "page_piece_account_list_request"})

    assert response == {"result": 0, "account_list": []}
    assert transport.http_request == (
        {"cmd_name": "page_piece_account_list_request"}, "token"
    )
    client.stop()


def test_protocol_events_log_http_request_and_matching_response():
    events = []
    client, transport = logged_in_client(events)
    transport.authenticated_response = lambda payload: {
        "cmd_name": "chat_create_group_ack",
        "cmd_guid": payload["cmd_guid"],
        "result": 0,
    }
    result = client.request(
        {"cmd_name": "chat_create_group", "password": "hidden"},
        expected_ack="chat_create_group_ack",
    )

    messages = [event.message for event in events if event.event_type.value == "message"]
    assert any(message.startswith("[protocol-send] ") and '"password":"***"' in message
               for message in messages)
    assert any(message.startswith("[protocol-receive] ") and
               '"cmd_name":"chat_create_group_ack"' in message for message in messages)
    assert result["result"] == 0
    client.stop()


def test_protocol_events_log_authenticated_http_request_and_response():
    events = []
    client, _ = logged_in_client(events)

    client.post_authenticated({"cmd_name": "page_piece_account_list_request"})

    messages = [event.message for event in events if event.event_type.value == "message"]
    assert any(message.startswith("[protocol-send] ") and
               '"cmd_name":"page_piece_account_list_request"' in message
               for message in messages)
    assert any(message == '[protocol-receive] {"result":0,"account_list":[]}'
               for message in messages)
    client.stop()
