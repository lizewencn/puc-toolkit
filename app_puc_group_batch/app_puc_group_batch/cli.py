"""Command-line workflow for one APP PUC batch group operation."""

from __future__ import annotations

import argparse
import dataclasses
import getpass
import json
import os
import threading
from collections.abc import Sequence
from enum import Enum

from app_puc_login import LoginConfig, PucLoginClient
from app_puc_login.events import EventType

from .service import AppPucGroupBatchService
from .local_config import AppBusinessConfigError, load_profile, save_profile


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Create APP PUC groups with automatic members")
    parser.add_argument("--environment", help="Saved APP environment name")
    parser.add_argument("--account", required=True)
    parser.add_argument("--server", help="APP server URL, for example https://host:16663")
    parser.add_argument("--group-count", required=True, type=int)
    parser.add_argument("--member-count", type=int, default=3, help="Total members including owner")
    parser.add_argument("--password-env", help="Read password from this environment variable")
    parser.add_argument("--password-dialog", action="store_true",
                        help="Open a local masked password dialog")
    parser.add_argument("--save-profile", action="store_true",
                        help="Save environment, account, and plaintext password locally")
    parser.add_argument("--login-timeout", type=float, default=30.0)
    tls = parser.add_mutually_exclusive_group()
    tls.add_argument("--verify-tls", action="store_true", default=False,
                     help="Enable TLS certificate validation")
    tls.add_argument("--insecure", action="store_false", dest="verify_tls",
                     help=argparse.SUPPRESS)
    return parser


def _password_dialog() -> str:
    import tkinter
    from tkinter import simpledialog

    root = tkinter.Tk()
    root.withdraw()
    root.attributes("-topmost", True)
    try:
        value = simpledialog.askstring(
            "APP PUC Login", "Password:", show="*", parent=root,
        )
    finally:
        root.destroy()
    if not value:
        raise ValueError("APP password input was cancelled")
    return value


def acquire_password(args, *, saved=None, environ=None, dialog=None, prompt=None) -> str:
    environment = os.environ if environ is None else environ
    if args.password_env:
        password = environment.get(args.password_env)
        if password is None:
            raise ValueError(f"password environment variable is not set: {args.password_env}")
        return password
    if args.password_dialog:
        return (dialog or _password_dialog)()
    if saved and saved.get("password"):
        return str(saved["password"])
    return (prompt or getpass.getpass)("APP PUC password: ")


def _json_value(value):
    if dataclasses.is_dataclass(value):
        value = dataclasses.asdict(value)
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    return value


def run_batch(args, *, password: str, client=None, service=None, on_progress=None):
    if args.group_count <= 0:
        raise ValueError("group_count must be positive")
    if args.member_count < 3:
        raise ValueError("member_count must be at least 3 (including owner)")
    if args.login_timeout <= 0:
        raise ValueError("login_timeout must be positive")

    client = client or PucLoginClient()
    service = service or AppPucGroupBatchService()
    ready = threading.Event()
    failure = []

    def handle_login(event):
        if event.event_type is EventType.LOGIN_SUCCESS:
            ready.set()
        elif event.event_type in {EventType.ERROR, EventType.STOPPED}:
            failure.append(event.message or event.event_type.value)
            ready.set()

    config = LoginConfig(
        account=args.account.strip(), password=password, server=args.server.strip(),
        verify_tls=args.verify_tls,
    )
    try:
        client.start(config, handle_login)
        if not ready.wait(args.login_timeout):
            raise RuntimeError("APP login timed out")
        if failure:
            raise RuntimeError(f"APP login failed: {failure[0]}")
        return service.create_groups(
            member_count=args.member_count,
            group_count=args.group_count,
            on_progress=on_progress,
        )
    finally:
        client.stop()


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    saved = None
    if args.environment:
        try:
            saved = load_profile(args.environment, args.account)
        except AppBusinessConfigError:
            if not args.server:
                raise
    if not args.server and saved:
        args.server = saved["server"]
    if not args.server:
        parser.error("--server is required when no saved environment profile exists")
    try:
        password = acquire_password(args, saved=saved)
    except ValueError as exc:
        parser.error(str(exc))

    if args.save_profile:
        if not args.environment:
            parser.error("--environment is required with --save-profile")
        save_profile(args.environment, args.server, args.account, password)

    def emit_progress(progress):
        print(json.dumps({"type": "progress", "data": _json_value(progress)},
                         ensure_ascii=False, separators=(",", ":")), flush=True)

    try:
        summary = run_batch(args, password=password, on_progress=emit_progress)
    except Exception as exc:
        print(json.dumps({"type": "error", "message": str(exc)},
                         ensure_ascii=False, separators=(",", ":")), flush=True)
        return 1
    print(json.dumps({"type": "summary", "data": _json_value(summary)},
                     ensure_ascii=False, separators=(",", ":")), flush=True)
    return 0
