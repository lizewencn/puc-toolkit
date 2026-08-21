import pytest

from app_puc_login.config import LoginConfig


def test_config_derives_direct_source_urls():
    config = LoginConfig("alice", "secret", "https://puc.test:16663/")

    assert config.server == "https://puc.test:16663"
    assert config.token_url == "https://puc.test:16663/has"
    assert config.websocket_url == "wss://puc.test:16663/wsas"
    assert config.realm == "puc.com"


@pytest.mark.parametrize("value", ["", "alice", "ftp://puc.test"])
def test_config_rejects_invalid_server(value):
    with pytest.raises(ValueError):
        LoginConfig("alice", "secret", value)


@pytest.mark.parametrize("field", ["account", "password"])
def test_config_rejects_empty_required_value(field):
    values = {
        "account": "alice",
        "password": "secret",
        "server": "https://puc.test",
    }
    values[field] = ""

    with pytest.raises(ValueError, match=field):
        LoginConfig(**values)


def test_config_uses_explicit_device_identifiers():
    config = LoginConfig(
        "alice",
        "secret",
        "http://puc.test/base",
        imei_list=("imei-1", "imei-2"),
        sn="serial-1",
    )

    assert config.imei_list == ("imei-1", "imei-2")
    assert config.sn == "serial-1"
    assert config.token_url == "http://puc.test/base/has"
    assert config.websocket_url == "ws://puc.test/base/wsas"


@pytest.mark.parametrize("delays", [(), (0,), (-1, 2)])
def test_config_rejects_invalid_reconnect_delays(delays):
    with pytest.raises(ValueError, match="reconnect"):
        LoginConfig(
            "alice",
            "secret",
            "https://puc.test",
            reconnect_delays=delays,
        )
