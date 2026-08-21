import json

import pytest

from app_puc_login.__main__ import build_config, build_parser, event_json
from app_puc_login.events import EventType, LoginEvent, LoginPhase


def test_cli_reads_password_from_named_environment_variable():
    args = build_parser().parse_args(
        [
            "--account",
            "alice",
            "--server",
            "https://puc.test",
            "--password-env",
            "PUC_TEST_PASSWORD",
        ]
    )

    config = build_config(args, environ={"PUC_TEST_PASSWORD": "secret"})

    assert config.password == "secret"
    assert config.realm == "puc.com"


def test_cli_rejects_missing_password_environment_variable():
    args = build_parser().parse_args(
        [
            "--account",
            "alice",
            "--server",
            "https://puc.test",
            "--password-env",
            "MISSING",
        ]
    )

    with pytest.raises(ValueError, match="MISSING"):
        build_config(args, environ={})


def test_event_json_uses_enum_values_and_contains_no_secret():
    event = LoginEvent.create(
        EventType.ERROR,
        LoginPhase.LOGIN,
        payload={"token": "secret", "result": 10},
    )

    payload = json.loads(event_json(event))

    assert payload["event_type"] == "error"
    assert payload["phase"] == "login"
    assert payload["payload"] == {"token": "***", "result": 10}
