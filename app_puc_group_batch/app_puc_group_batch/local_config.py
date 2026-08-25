"""Persistent APP business profiles stored beside puc-config configuration."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path


class AppBusinessConfigError(RuntimeError):
    pass


def resolve_config_path(*, environ=None) -> Path:
    environment = os.environ if environ is None else environ
    local_app_data = str(environment.get("LOCALAPPDATA") or "").strip()
    settings_path = Path(local_app_data) / "puc-config" / "setting.json"
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        raise AppBusinessConfigError(
            f"puc-config setting.json is unavailable: {settings_path}"
        ) from exc
    root_value = str(settings.get("configRoot") or "").strip() if isinstance(settings, dict) else ""
    root = Path(root_value)
    if not root_value or not root.is_absolute() or not root.is_dir():
        raise AppBusinessConfigError("puc-config setting.json has an invalid configRoot")
    return root / "app-business.json"


def _read_document(path: Path) -> dict:
    if not path.exists():
        return {"version": 1, "environments": []}
    try:
        document = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        raise AppBusinessConfigError(f"APP business config is invalid: {path}") from exc
    if not isinstance(document, dict) or not isinstance(document.get("environments"), list):
        raise AppBusinessConfigError(f"APP business config has an invalid schema: {path}")
    return document


def _write_document(path: Path, document: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(document, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def save_profile(environment: str, server: str, account: str, password: str) -> Path:
    values = [value.strip() for value in (environment, server, account)]
    if not all(values) or not password:
        raise AppBusinessConfigError("environment, server, account, and password are required")
    environment, server, account = values
    path = resolve_config_path()
    document = _read_document(path)
    environments = document["environments"]
    target = next((item for item in environments
                   if isinstance(item, dict) and str(item.get("name") or "").casefold() == environment.casefold()), None)
    if target is None:
        target = {"name": environment, "server": server, "accounts": []}
        environments.append(target)
    target["name"] = environment
    target["server"] = server
    accounts = target.get("accounts")
    if not isinstance(accounts, list):
        accounts = []
        target["accounts"] = accounts
    saved = next((item for item in accounts
                  if isinstance(item, dict) and str(item.get("account") or "").casefold() == account.casefold()), None)
    if saved is None:
        saved = {"account": account, "password": password}
        accounts.append(saved)
    else:
        saved.clear()
        saved.update({"account": account, "password": password})
    document["version"] = 1
    _write_document(path, document)
    return path


def load_profile(environment: str, account: str) -> dict:
    path = resolve_config_path()
    document = _read_document(path)
    environment_key, account_key = environment.strip().casefold(), account.strip().casefold()
    target = next((item for item in document["environments"]
                   if isinstance(item, dict) and str(item.get("name") or "").casefold() == environment_key), None)
    if target is None:
        raise AppBusinessConfigError(f"APP environment is not configured: {environment}")
    saved = next((item for item in target.get("accounts") or []
                  if isinstance(item, dict) and str(item.get("account") or "").casefold() == account_key), None)
    if saved is None:
        raise AppBusinessConfigError(f"APP account is not configured: {account}")
    return {
        "environment": str(target.get("name") or ""),
        "server": str(target.get("server") or ""),
        "account": str(saved.get("account") or ""),
        "password": str(saved.get("password") or ""),
    }
