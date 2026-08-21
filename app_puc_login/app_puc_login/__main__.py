"""Command-line adapter for local PUC login diagnostics."""

from __future__ import annotations

import argparse
import dataclasses
import getpass
import json
import os
import time
from collections.abc import Mapping, Sequence

from .client import PucLoginClient
from .config import LoginConfig
from .events import LoginEvent


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Log in to PUC and keep the WebSocket online")
    parser.add_argument("--account", required=True)
    parser.add_argument("--server", required=True, help="Source http(s) server URL")
    parser.add_argument(
        "--password-env",
        help="Read the password from this environment variable; otherwise prompt securely",
    )
    parser.add_argument("--imei", action="append", dest="imei_list")
    parser.add_argument("--sn")
    parser.add_argument("--request-timeout", type=float, default=15.0)
    parser.add_argument("--websocket-timeout", type=float, default=20.0)
    parser.add_argument("--heartbeat-idle", type=float, default=15.0)
    parser.add_argument(
        "--reconnect-delays",
        default="1,2,4,8,16,30",
        help="Comma-separated reconnect delays in seconds",
    )
    parser.add_argument("--insecure", action="store_true", help="Disable TLS certificate checks")
    return parser


def build_config(
    args: argparse.Namespace,
    *,
    environ: Mapping[str, str] | None = None,
) -> LoginConfig:
    environment = os.environ if environ is None else environ
    if args.password_env:
        password = environment.get(args.password_env)
        if password is None:
            raise ValueError(f"password environment variable is not set: {args.password_env}")
    else:
        password = getpass.getpass("PUC password: ")
    delays = tuple(float(value.strip()) for value in args.reconnect_delays.split(","))
    options = {
        "request_timeout": args.request_timeout,
        "websocket_timeout": args.websocket_timeout,
        "heartbeat_idle": args.heartbeat_idle,
        "reconnect_delays": delays,
        "verify_tls": not args.insecure,
    }
    if args.imei_list:
        options["imei_list"] = tuple(args.imei_list)
    if args.sn:
        options["sn"] = args.sn
    return LoginConfig(args.account, password, args.server, **options)


def event_json(event: LoginEvent) -> str:
    data = dataclasses.asdict(event)
    data["event_type"] = event.event_type.value
    data["phase"] = event.phase.value
    return json.dumps(data, ensure_ascii=False, separators=(",", ":"))


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        config = build_config(args)
    except ValueError as exc:
        parser.error(str(exc))

    client = PucLoginClient()
    client.start(config, lambda event: print(event_json(event), flush=True))
    try:
        while client.is_running:
            time.sleep(0.2)
    except KeyboardInterrupt:
        pass
    finally:
        client.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
