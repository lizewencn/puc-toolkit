#!/usr/bin/env python3
"""Self-contained shared SSH config loader. Keep copies identical across dependent skills."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

CONFIG_FILENAME = "environments.local.json"
PLACEHOLDERS = {"", "username", "password", "your-host", "your-username", "your-password"}


def default_config_root() -> Path:
    return Path.home() / "Desktop" / "agentSkillLocalConfig" / "ssh-config"


def settings_path() -> Path:
    value = os.environ.get("LOCALAPPDATA", "").strip()
    if not value:
        raise SystemExit("LOCALAPPDATA is unavailable; pass --ssh-config-root explicitly.")
    return Path(value) / "ssh-config" / "setting.json"


def non_placeholder(value: object) -> str:
    text = "" if value is None else str(value).strip()
    return "" if text in PLACEHOLDERS else text


def resolve_config_root(override: str | None = None) -> Path:
    if override:
        return Path(override).expanduser().resolve()
    path = settings_path()
    if not path.exists():
        raise SystemExit(
            "SSH config path has not been selected.\n"
            f"Suggested default: {default_config_root()}\n"
            "Run this skill's Set-SshConfigRoot.ps1 -UseDefault, or choose an absolute path with -Path."
        )
    try:
        settings = json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc
    value = str(settings.get("configRoot") or "").strip()
    if not value:
        raise SystemExit(f"SSH config root is empty in {path}.")
    return Path(value).expanduser().resolve()


def valid_host(value: str) -> bool:
    text = value.strip()
    if not text or text.startswith("-") or any(ch.isspace() for ch in text):
        return False
    ipv4 = re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}", text)
    if ipv4:
        return all(0 <= int(part) <= 255 for part in text.split("."))
    return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", text))


def matches(environment: dict, selector: str) -> bool:
    values = [environment.get("name"), environment.get("host"), *(environment.get("aliases") or [])]
    return selector in {str(value).strip() for value in values if value is not None}


def save_config(path: Path, config: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def ensure_config(path: Path, selector: str | None = None) -> None:
    if path.exists():
        return
    environment = {"host": selector} if selector and valid_host(selector) else {"host": "your-host"}
    save_config(path, {
        "defaults": {"port": 22, "username": "your-username", "password": "your-password", "timeoutSeconds": 20},
        "environments": [environment],
    })
    raise SystemExit(f"Created shared SSH config: {path}\nFill in defaults once, then rerun.")


def load_environment(selector: str | None, root_override: str | None = None) -> tuple[dict, Path]:
    path = resolve_config_root(root_override) / CONFIG_FILENAME
    ensure_config(path, selector)
    try:
        config = json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc
    defaults = config.get("defaults", {})
    environments = config.get("environments")
    if not isinstance(defaults, dict) or not isinstance(environments, list):
        raise SystemExit(f"Config must contain a defaults object and environments array: {path}")
    selected = None
    if selector:
        selected = next((item for item in environments if isinstance(item, dict) and matches(item, selector)), None)
        if selected is None and valid_host(selector):
            selected = {"host": selector}
            environments.append(selected)
            save_config(path, config)
        elif selected is None:
            raise SystemExit(f"No shared SSH environment matches: {selector}")
    elif len(environments) == 1:
        selected = environments[0]
    elif not environments:
        raise SystemExit(f"No SSH environments configured in {path}")
    else:
        labels = ", ".join(str(item.get("name") or item.get("host") or "<missing>") for item in environments)
        raise SystemExit(f"Multiple SSH environments configured; pass --host. Available: {labels}")
    merged = dict(defaults)
    merged.update(selected)
    validate_environment(merged, path)
    return merged, path


def validate_environment(environment: dict, path: Path) -> None:
    missing = []
    if not non_placeholder(environment.get("host")):
        missing.append("host")
    if not non_placeholder(environment.get("username") or environment.get("user")):
        missing.append("username")
    if not non_placeholder(environment.get("password")) and not non_placeholder(environment.get("passwordEnv")):
        missing.append("password or passwordEnv")
    try:
        port = int(environment.get("port", 22))
    except (TypeError, ValueError):
        missing.append("port must be a number")
    else:
        if not 1 <= port <= 65535:
            missing.append("port must be between 1 and 65535")
    if missing:
        details = "\n".join(f"  - {item}" for item in missing)
        raise SystemExit(f"Shared SSH config is incomplete.\nConfig file: {path}\nPlease fill or fix:\n{details}")


def merge_login(business_environment: dict, ssh_environment: dict) -> dict:
    merged = dict(business_environment)
    for key in ("host", "port", "username", "user", "password", "passwordEnv", "authMethod", "timeoutSeconds"):
        merged.pop(key, None)
    merged.update(ssh_environment)
    return merged
