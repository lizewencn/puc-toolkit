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

    def request_token(self, _): return "token"
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


def logged_in_client():
    transport = RequestTransport()
    transport.push({"result": 0, "puc_id": "1", "user_id": "owner"}, MessageType.AUTH_ACK)
    client = PucLoginClient(transport_factory=lambda _: transport)
    client.start(config(), lambda _: None)
    wait_for(lambda: len(transport.sent) == 1)
    return client, transport


def test_request_correlates_guid_and_expected_ack():
    client, transport = logged_in_client()
    result = {}
    thread = threading.Thread(target=lambda: result.update(client.request(
        {"cmd_name": "chat_create_group"}, expected_ack="chat_create_group_ack",
    )))
    thread.start()
    wait_for(lambda: len(transport.sent) == 2)
    sent = json.loads(decode_frame(transport.sent[-1]).body)
    transport.push({"cmd_name": "wrong_ack", "cmd_guid": sent["cmd_guid"], "result": 0})
    time.sleep(0.03)
    assert thread.is_alive()
    transport.push({"cmd_name": "chat_create_group_ack", "cmd_guid": sent["cmd_guid"], "result": 0})
    thread.join(1)
    assert result["result"] == 0
    client.stop()


def test_request_timeout_and_unauthenticated_error():
    client, _ = logged_in_client()
    with pytest.raises(RequestTimeout):
        client.request({"cmd_name": "x"}, expected_ack="x_ack", timeout=0.01)
    client.stop()
    with pytest.raises(ClientStateError):
        client.request({"cmd_name": "x"}, expected_ack="x_ack")
