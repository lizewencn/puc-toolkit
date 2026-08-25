import json
from pathlib import Path

import pytest

from app_puc_group_batch.local_config import (
    AppBusinessConfigError, load_profile, resolve_config_path, save_profile,
)


def configure_root(tmp_path, monkeypatch):
    local_app_data = tmp_path / "local"
    config_root = tmp_path / "shared" / "puc-config"
    config_root.mkdir(parents=True)
    settings = local_app_data / "puc-config" / "setting.json"
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({"configRoot": str(config_root)}), encoding="utf-8")
    monkeypatch.setenv("LOCALAPPDATA", str(local_app_data))
    return config_root


def test_resolve_config_path_uses_puc_config_selected_root(tmp_path, monkeypatch):
    config_root = configure_root(tmp_path, monkeypatch)

    assert resolve_config_path() == config_root / "app-business.json"


def test_save_and_reuse_plaintext_account_without_persisting_token(tmp_path, monkeypatch):
    config_root = configure_root(tmp_path, monkeypatch)

    save_profile(
        environment="10.161.30.93", server="https://10.161.30.93:16663",
        account="lzw93001", password="plain-secret",
    )

    profile = load_profile("10.161.30.93", "lzw93001")
    assert profile == {
        "environment": "10.161.30.93",
        "server": "https://10.161.30.93:16663",
        "account": "lzw93001",
        "password": "plain-secret",
    }
    text = (config_root / "app-business.json").read_text(encoding="utf-8")
    assert "plain-secret" in text
    assert "token" not in text.lower()
    assert "authorization" not in text.lower()


def test_save_profile_preserves_other_accounts_and_updates_matching_account(tmp_path, monkeypatch):
    configure_root(tmp_path, monkeypatch)
    save_profile("env", "https://one:16663", "account1", "first")
    save_profile("env", "https://one:16663", "account2", "second")
    save_profile("env", "https://two:16663", "account1", "updated")

    assert load_profile("env", "account1")["password"] == "updated"
    assert load_profile("env", "account1")["server"] == "https://two:16663"
    assert load_profile("env", "account2")["password"] == "second"


def test_missing_puc_config_root_is_reported(tmp_path, monkeypatch):
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))

    with pytest.raises(AppBusinessConfigError, match="puc-config.*setting.json"):
        resolve_config_path()
