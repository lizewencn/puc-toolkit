from types import SimpleNamespace

import pytest

from app_puc_group_batch.models import AppGroupInputError
from app_puc_group_batch.service import (
    AppDispatcherSearchError, AppPucGroupBatchService,
    dispatcher_account_prefix, search_dispatchers,
)


class SearchClient:
    def __init__(self, response):
        self.response = response
        self.payload = None

    def post_authenticated(self, payload):
        self.payload = payload
        return self.response

    def request(self, payload, *, expected_ack):
        raise AssertionError("group creation must not start")


class GroupClient(SearchClient):
    def __init__(self, response):
        super().__init__(response)
        self.requests = []

    def request(self, payload, *, expected_ack):
        self.requests.append((payload, expected_ack))
        if expected_ack == "chat_create_group_ack":
            return {
                "result": 0,
                "group": {"group_id": "group-1", "puc_id": "03093",
                          "realm": "puc.com", "time_stamp": 123},
                "members": [{"account": "lzw93001", "role": 1}],
            }
        return {"result": 0}


def publish_session(monkeypatch, response):
    client = SearchClient(response)
    session = SimpleNamespace(
        app_puc_id="03093",
        app_user_id="lzw93001",
        app_realm="puc.com",
        app_session_id="session-1",
        client=client,
    )
    monkeypatch.setattr("app_puc_group_batch.service.get_active_app_session", lambda: session)
    return client


def test_search_dispatchers_posts_webpuc_protocol_and_maps_puc_id(monkeypatch):
    client = publish_session(monkeypatch, {
        "cmd_name": "page_piece_account_list_request_ack",
        "result": 0,
        "account_list": [
            {
                "dispatcher_account": "lzw93001",
                "dispatcher_name": "lzw93001_alias",
                "dispatcher_no": "1787275610121",
                "puc_id": "03093",
            }
        ],
    })

    results = search_dispatchers(" lzw ")

    assert results == [{
        "account": "lzw93001",
        "name": "lzw93001_alias",
        "appPucId": "03093",
        "label": "lzw93001_alias(lzw93001)",
    }]
    assert client.payload == {
        "puc_id": "03093",
        "cmd_guid": client.payload["cmd_guid"],
        "user_id": "lzw93001",
        "realm": "puc.com",
        "page": 1,
        "keyword": "lzw",
        "product_name": "WebPUC",
        "version": "10",
        "cmd_name": "page_piece_account_list_request",
        "page_size": 100,
        "version_seq": "0",
    }


@pytest.mark.parametrize("response", [
    {"cmd_name": "wrong_ack", "result": 0, "account_list": []},
    {"cmd_name": "page_piece_account_list_request_ack", "result": 12},
])
def test_search_dispatchers_rejects_invalid_response(monkeypatch, response):
    publish_session(monkeypatch, response)
    with pytest.raises(AppDispatcherSearchError):
        search_dispatchers("lzw")


def test_search_dispatchers_reports_api_failure_before_missing_ack(monkeypatch):
    publish_session(monkeypatch, {"result": 401, "msg": "token invalid"})

    with pytest.raises(AppDispatcherSearchError, match="401.*token invalid"):
        search_dispatchers("lzw")


def test_search_dispatchers_reports_received_ack_name(monkeypatch):
    publish_session(monkeypatch, {
        "cmd_name": "page_piece_account_list_response", "result": 0,
    })

    with pytest.raises(AppDispatcherSearchError, match="page_piece_account_list_response"):
        search_dispatchers("lzw")


@pytest.mark.parametrize(("account", "prefix"), [
    ("lzw93001", "lzw"),
    ("team_a93001", "team_a"),
])
def test_dispatcher_account_prefix_removes_all_trailing_digits(account, prefix):
    assert dispatcher_account_prefix(account) == prefix


def test_batch_rejects_member_count_below_three_before_search(monkeypatch):
    client = publish_session(monkeypatch, {})

    with pytest.raises(AppGroupInputError, match="at least 3"):
        AppPucGroupBatchService().create_groups(member_count=2, group_count=1)

    assert client.payload is None


def test_batch_fails_before_group_creation_when_matching_dispatchers_are_insufficient(monkeypatch):
    client = publish_session(monkeypatch, {
        "cmd_name": "page_piece_account_list_request_ack",
        "result": 0,
        "account_list": [
            {"dispatcher_account": "lzw93001", "puc_id": "03093"},
            {"dispatcher_account": "lzw93002", "puc_id": "03093"},
        ],
    })

    with pytest.raises(AppGroupInputError, match="insufficient matching dispatchers"):
        AppPucGroupBatchService().create_groups(member_count=3, group_count=1)

    assert client.payload["keyword"] == "lzw"


def test_batch_selects_matching_dispatchers_in_api_order_and_includes_owner(monkeypatch):
    client = GroupClient({
        "cmd_name": "page_piece_account_list_request_ack",
        "result": 0,
        "account_list": [
            {"dispatcher_account": "lzw93001", "puc_id": "03093"},
            {"dispatcher_account": "other93001", "puc_id": "03093"},
            {"dispatcher_account": "lzw93003", "puc_id": "03093"},
            {"dispatcher_account": "lzw93002", "puc_id": "03093"},
            {"dispatcher_account": "lzw93004", "puc_id": "03093"},
        ],
    })
    session = SimpleNamespace(
        app_puc_id="03093", app_user_id="lzw93001", app_realm="puc.com",
        app_session_id="session-1", client=client,
    )
    monkeypatch.setattr("app_puc_group_batch.service.get_active_app_session", lambda: session)

    summary = AppPucGroupBatchService().create_groups(member_count=3, group_count=1)

    create_payload = client.requests[0][0]
    assert [member["account"] for member in create_payload["members"]] == [
        "lzw93003", "lzw93002", "lzw93001",
    ]
    assert [member["role"] for member in create_payload["members"]] == [0, 0, 1]
    assert summary.results[0].members == (
        {"account": "lzw93003", "alias": "lzw93003"},
        {"account": "lzw93002", "alias": "lzw93002"},
        {"account": "lzw93001", "alias": "lzw93001"},
    )


def test_batch_create_request_matches_android_protocol_shape(monkeypatch):
    client = GroupClient({
        "cmd_name": "page_piece_account_list_request_ack",
        "result": 0,
        "account_list": [
            {"dispatcher_account": "lzw93002", "dispatcher_name": "lzw93002_alias", "puc_id": "03093"},
            {"dispatcher_account": "lzw93003", "dispatcher_name": "lzw93003_alias", "puc_id": "03093"},
        ],
    })
    session = SimpleNamespace(
        app_puc_id="03093", app_user_id="lzw93001", app_realm="puc.com",
        app_session_id="session-1", client=client,
    )
    monkeypatch.setattr("app_puc_group_batch.service.get_active_app_session", lambda: session)

    AppPucGroupBatchService().create_groups(member_count=3, group_count=1)

    create_payload = client.requests[0][0]
    assert {key: create_payload[key] for key in (
        "product_name", "version", "puc_id", "user_id", "realm",
    )} == {
        "product_name": "PUC", "version": "10", "puc_id": "03093",
        "user_id": "lzw93001", "realm": "puc.com",
    }
    for member in create_payload["members"]:
        assert member["system_id"] == "000"
        assert len(member["guid"]) == 36
    assert [member["alias"] for member in create_payload["members"]] == [
        "lzw93002_alias", "lzw93003_alias", "lzw93001",
    ]
    assert create_payload["subject"] == "lzw93002_alias、lzw93003_alia..."

    rename_payload = client.requests[1][0]
    assert rename_payload["product_name"] == "PUC"
    assert rename_payload["version"] == "10"
    assert rename_payload["user_id"] == "lzw93001"
