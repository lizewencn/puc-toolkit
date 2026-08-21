import json

import pytest

from app_puc_login.config import LoginConfig
from app_puc_login.events import AuthenticationError, TransportError
from app_puc_login.transport import PucTransport


class FakeResponse:
    def __init__(self, payload, status_error=None):
        self._payload = payload
        self._status_error = status_error

    def raise_for_status(self):
        if self._status_error:
            raise self._status_error

    def json(self):
        return self._payload


class FakeSession:
    def __init__(self, response):
        self.response = response
        self.calls = []

    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return self.response

    def close(self):
        pass


class FakeWebSocket:
    def __init__(self):
        self.sent = []
        self.closed = False
        self.timeout = None

    def settimeout(self, timeout):
        self.timeout = timeout

    def send_binary(self, data):
        self.sent.append(data)

    def recv(self):
        return b"frame"

    def close(self):
        self.closed = True


@pytest.fixture
def config():
    return LoginConfig("alice", "secret", "https://puc.test:16663")


def test_token_request_uses_source_server_without_probe(config):
    session = FakeSession(FakeResponse({"result": 0, "access_token": "token-1"}))
    transport = PucTransport(config, session=session)

    token = transport.request_token("Basic abc")

    assert token == "token-1"
    assert session.calls == [
        (
            "https://puc.test:16663/has",
            {
                "headers": {
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Authorization": "Basic abc",
                },
                "timeout": 15.0,
                "verify": True,
            },
        )
    ]


@pytest.mark.parametrize("payload", [{"result": 12}, {"result": 0}, {"result": 0, "access_token": ""}])
def test_token_request_rejects_business_failure(config, payload):
    transport = PucTransport(config, session=FakeSession(FakeResponse(payload)))

    with pytest.raises(AuthenticationError) as caught:
        transport.request_token("Basic abc")

    assert caught.value.code == payload["result"]


def test_connect_uses_derived_wss_url_and_tls_verification(config):
    socket = FakeWebSocket()
    calls = []

    def factory(url, **kwargs):
        calls.append((url, kwargs))
        return socket

    transport = PucTransport(config, websocket_factory=factory)
    transport.connect()

    assert calls == [
        (
            "wss://puc.test:16663/wsas",
            {"timeout": 20.0, "sslopt": {"cert_reqs": 2}},
        )
    ]
    assert socket.timeout == 15.0
    transport.send_frame(b"hello")
    assert transport.recv() == b"frame"
    assert socket.sent == [b"hello"]
    transport.close()
    assert socket.closed


def test_network_exception_becomes_transport_error(config):
    session = FakeSession(FakeResponse({}, status_error=OSError("offline")))
    transport = PucTransport(config, session=session)

    with pytest.raises(TransportError, match="token request failed"):
        transport.request_token("Basic abc")
