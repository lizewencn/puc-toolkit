from types import SimpleNamespace

import pytest

from app_puc_group_batch.cli import acquire_password, build_parser, run_batch
from app_puc_login.events import EventType, LoginEvent, LoginPhase


class FakeClient:
    def __init__(self, event):
        self.event = event
        self.started_with = None
        self.stopped = False

    def start(self, config, callback):
        self.started_with = config
        callback(self.event)

    def stop(self):
        self.stopped = True


class FakeService:
    def __init__(self):
        self.call = None

    def create_groups(self, **kwargs):
        self.call = kwargs
        return SimpleNamespace(requested_count=kwargs["group_count"], results=())


def event(event_type, message=""):
    return LoginEvent.create(event_type, LoginPhase.LOGIN, message=message)


def test_parser_rejects_member_count_below_three():
    parser = build_parser()
    args = parser.parse_args([
        "--account", "lzw93001", "--server", "https://127.0.0.1:16663",
        "--group-count", "1", "--member-count", "2",
    ])

    with pytest.raises(ValueError, match="at least 3"):
        run_batch(args, password="secret", client=FakeClient(event(EventType.LOGIN_SUCCESS)),
                  service=FakeService())


def test_parser_supports_saved_environment_profile():
    args = build_parser().parse_args([
        "--environment", "10.161.30.93", "--account", "lzw93001",
        "--group-count", "5",
    ])

    assert args.server is None
    assert args.save_profile is False


def test_password_dialog_overrides_saved_password():
    args = build_parser().parse_args([
        "--environment", "env", "--account", "account", "--group-count", "1",
        "--password-dialog",
    ])

    password = acquire_password(
        args, saved={"password": "old"}, environ={},
        dialog=lambda: "new-secret", prompt=lambda _: "prompt-secret",
    )

    assert password == "new-secret"


def test_run_batch_logs_in_then_calls_service_with_counts():
    args = build_parser().parse_args([
        "--account", "lzw93001", "--server", "https://127.0.0.1:16663",
        "--group-count", "2", "--member-count", "3",
    ])
    client = FakeClient(event(EventType.LOGIN_SUCCESS))
    service = FakeService()

    summary = run_batch(args, password="secret", client=client, service=service)

    assert summary.requested_count == 2
    assert service.call["group_count"] == 2
    assert service.call["member_count"] == 3
    assert client.started_with.account == "lzw93001"
    assert client.started_with.verify_tls is False
    assert client.stopped is True


def test_verify_tls_can_be_enabled_explicitly():
    args = build_parser().parse_args([
        "--account", "lzw93001", "--server", "https://127.0.0.1:16663",
        "--group-count", "1", "--verify-tls",
    ])
    client = FakeClient(event(EventType.LOGIN_SUCCESS))

    run_batch(args, password="secret", client=client, service=FakeService())

    assert client.started_with.verify_tls is True


def test_run_batch_does_not_create_groups_after_login_error():
    args = build_parser().parse_args([
        "--account", "lzw93001", "--server", "https://127.0.0.1:16663",
        "--group-count", "1", "--member-count", "3",
    ])
    client = FakeClient(event(EventType.ERROR, "login rejected"))
    service = FakeService()

    with pytest.raises(RuntimeError, match="login rejected"):
        run_batch(args, password="secret", client=client, service=service)

    assert service.call is None
    assert client.stopped is True
