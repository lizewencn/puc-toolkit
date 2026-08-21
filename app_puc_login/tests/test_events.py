from dataclasses import FrozenInstanceError

import pytest

from app_puc_login.events import EventType, LoginEvent, LoginPhase, redact


def test_redact_removes_nested_secrets_without_mutating_source():
    source = {
        "result": 0,
        "token": "token-1",
        "nested": {"password": "secret", "Authorization": "Basic abc", "name": "alice"},
        "items": [{"access_token": "token-2"}],
    }

    sanitized = redact(source)

    assert sanitized == {
        "result": 0,
        "token": "***",
        "nested": {"password": "***", "Authorization": "***", "name": "alice"},
        "items": [{"access_token": "***"}],
    }
    assert source["token"] == "token-1"


def test_login_event_is_immutable_and_sanitizes_payload():
    event = LoginEvent.create(
        EventType.ERROR,
        LoginPhase.TOKEN,
        message="rejected",
        payload={"token": "token-1", "result": 12},
        code=12,
    )

    assert event.payload == {"token": "***", "result": 12}
    assert event.code == 12
    with pytest.raises(FrozenInstanceError):
        event.message = "changed"
