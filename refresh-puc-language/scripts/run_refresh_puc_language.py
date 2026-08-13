#!/usr/bin/env python3
import argparse
import getpass
import importlib.util
import json
import os
import re
import shutil
import shlex
import socket
import sys
from pathlib import Path


from ssh_config import load_environment as load_ssh_environment, merge_login


PLACEHOLDERS = {
    "",
    "username",
    "password",
    "your-env-name",
    "your-host",
    "your-username",
    "your-password",
}
REQUIRED_FIELDS = ("host", "username", "password", "namespace")


def default_config_path() -> Path:
    home = Path.home()
    return home / "Desktop" / "agentSkillLocalConfig" / "refresh-puc-language" / "puc-env.local.json"


def template_path() -> Path:
    return Path(__file__).resolve().parents[1] / "assets" / "puc-env.local.template.json"


def resolve_config_path(value: str | None) -> Path:
    if value:
        return Path(value).expanduser()

    env_path = os.environ.get("PUC_LANGUAGE_ENV_CONFIG", "").strip() or os.environ.get("PUC_ENV_CONFIG", "").strip()
    if env_path:
        return Path(env_path).expanduser()

    return default_config_path()


def ensure_config_exists(path: Path, initial_host: str | None = None) -> None:
    if path.exists():
        return

    path.parent.mkdir(parents=True, exist_ok=True)
    if initial_host and host_selector_can_be_created(initial_host):
        path.write_text(
            json.dumps({"environments": [build_environment_skeleton(initial_host)]}, indent=2) + "\n",
            encoding="utf-8",
        )
        raise SystemExit(
            "Config file was missing, so a new one was created with the requested host.\n"
            f"Created: {path}\n"
            f"Host: {initial_host}\n"
            "Confirm namespace and configure its login once in shared ssh-config, then rerun this command."
        )

    source = template_path()
    if not source.exists():
        raise SystemExit(f"Config file not found and template is missing: {source}")

    shutil.copyfile(source, path)
    raise SystemExit(
        "Config file was missing, so a template was created.\n"
        f"Created: {path}\n"
        "Fill in host and namespace, then configure login in shared ssh-config."
    )


def load_config(path: Path, initial_host: str | None = None) -> dict:
    ensure_config_exists(path, initial_host)
    if not path.exists():
        raise SystemExit(f"Config file not found: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc


def env_label(env: dict) -> str:
    name = non_placeholder(env.get("name"))
    host = non_placeholder(env.get("host"))
    if name and host and name != host:
        return f"{name} ({host})"
    return name or host or "<missing>"


def env_matches(env: dict, selector: str) -> bool:
    values = [
        non_placeholder(env.get("name")),
        non_placeholder(env.get("host")),
    ]
    values.extend(str(alias) for alias in (env.get("aliases") or []))
    return selector in values


def host_selector_can_be_created(selector: str) -> bool:
    text = selector.strip()
    if not text or text in PLACEHOLDERS:
        return False
    if text.startswith("-") or any(ch.isspace() for ch in text):
        return False
    if any(ch in text for ch in "/\\@"):
        return False

    ipv4_match = re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}", text)
    if ipv4_match:
        return all(0 <= int(part) <= 255 for part in text.split("."))

    if "." not in text:
        return False

    return re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]", text) is not None


def environment_has_reusable_login(env: dict) -> bool:
    namespace = non_placeholder(env.get("namespace"))
    return bool(namespace)


def build_environment_skeleton(host: str) -> dict:
    return {
        "host": host,
        "namespace": "puc",
        "skipApplyConfirmation": False,
    }


def build_environment_from_source(host: str, source: dict | None) -> dict:
    env = build_environment_skeleton(host)
    if not source:
        return env

    namespace = non_placeholder(source.get("namespace"))
    if namespace:
        env["namespace"] = namespace

    pattern = non_placeholder(source.get("pattern"))
    if pattern and pattern != "locale":
        env["pattern"] = pattern

    return env


def add_missing_environment(config_path: Path, config: dict, host: str, environments: list[dict]) -> dict:
    source = next((env for env in environments if environment_has_reusable_login(env)), None)
    env = build_environment_from_source(host, source)
    environments.append(env)
    save_config(config_path, config)

    print(f"No environment found for host/name/alias: {host}")
    if source:
        print(f"Added {host} to {config_path} using business defaults from {env_label(source)}.")
    else:
        print(f"Added {host} to {config_path}. Confirm namespace; login comes from shared ssh-config.")
    print("")
    return env


def find_environment(config_path: Path, config: dict, host: str | None) -> dict:
    environments = config.get("environments")
    if environments is None and host and host_selector_can_be_created(host):
        environments = []
        config["environments"] = environments

    if not isinstance(environments, list):
        raise SystemExit("Config must contain an environments array")

    if host:
        for env in environments:
            if env_matches(env, host):
                return env

        if host_selector_can_be_created(host):
            return add_missing_environment(config_path, config, host, environments)

        raise SystemExit(
            f"No environment found for host/name/alias: {host}\n"
            "Only host-like selectors such as an IP address or FQDN are auto-added to the local config."
        )

    if not environments:
        raise SystemExit("Config must contain a non-empty environments array")

    if len(environments) == 1:
        return environments[0]

    labels = ", ".join(env_label(env) for env in environments)
    raise SystemExit(f"Multiple environments configured; pass --host <host-or-name>. Available: {labels}")


def non_placeholder(value: object) -> str:
    text = "" if value is None else str(value)
    return "" if text.strip() in PLACEHOLDERS else text


def validate_environment(env: dict, label: str, config_path: Path) -> None:
    missing = []
    for field in REQUIRED_FIELDS:
        value = env.get(field)
        if field == "password" and non_placeholder(env.get("passwordEnv")):
            continue
        if not non_placeholder(value):
            missing.append(field)

    auth_method = non_placeholder(env.get("authMethod")) or "password"
    if auth_method != "password":
        missing.append("authMethod must be password")

    port = env.get("port", 22)
    try:
        parsed_port = int(port)
    except (TypeError, ValueError):
        missing.append("port must be a number")
    else:
        if parsed_port <= 0 or parsed_port > 65535:
            missing.append("port must be between 1 and 65535")

    if missing:
        fields = "\n".join(f"  - {item}" for item in missing)
        raise SystemExit(
            f"Environment config is incomplete for {label}.\n"
            f"Config file: {config_path}\n"
            "Please fill or fix:\n"
            f"{fields}"
        )


def config_bool(value: object) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    if isinstance(value, (int, float)):
        return value != 0
    text = str(value).strip().lower()
    return text in {"1", "true", "yes", "y", "on"}


def save_config(path: Path, config: dict) -> None:
    path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


def set_skip_apply_confirmation(config_path: Path, config: dict, env: dict, enabled: bool) -> None:
    env["skipApplyConfirmation"] = bool(enabled)
    save_config(config_path, config)
    state = "enabled" if enabled else "disabled"
    print(f"skipApplyConfirmation {state} for {env_label(env)}.")


def compact_environment(env: dict) -> dict:
    host = non_placeholder(env.get("host"))
    compact: dict = {}

    name = non_placeholder(env.get("name"))
    if name and name != host:
        compact["name"] = name

    compact["host"] = env.get("host", "")

    port = env.get("port")
    try:
        parsed_port = int(port)
    except (TypeError, ValueError):
        parsed_port = 22
    if parsed_port != 22:
        compact["port"] = port

    username = env.get("username", env.get("user", ""))
    compact["username"] = username

    password = non_placeholder(env.get("password"))
    password_env = non_placeholder(env.get("passwordEnv"))
    if password:
        compact["password"] = env.get("password", "")
    if password_env:
        compact["passwordEnv"] = password_env

    compact["namespace"] = env.get("namespace", "")

    aliases = env.get("aliases")
    if isinstance(aliases, list) and aliases:
        compact["aliases"] = aliases

    for key in ("pod", "localePath"):
        value = non_placeholder(env.get(key))
        if value:
            compact[key] = value

    pattern = non_placeholder(env.get("pattern"))
    if pattern and pattern != "locale":
        compact["pattern"] = pattern

    timeout = env.get("timeoutSeconds")
    try:
        parsed_timeout = int(timeout)
    except (TypeError, ValueError):
        parsed_timeout = 20
    if parsed_timeout != 20:
        compact["timeoutSeconds"] = timeout

    compact["skipApplyConfirmation"] = config_bool(env.get("skipApplyConfirmation"))
    return compact


def compact_selected_environment(config_path: Path, config: dict, env: dict) -> None:
    label = env_label(env)
    compact = compact_environment(env)
    env.clear()
    env.update(compact)
    save_config(config_path, config)
    print(f"Compacted config for {label}.")


def build_remote_args(
    args: argparse.Namespace,
    env: dict,
    apply: bool | None = None,
    yes: bool | None = None,
) -> list[str]:
    namespace = args.namespace or non_placeholder(env.get("namespace"))
    pod = args.pod or non_placeholder(env.get("pod"))
    locale_path = args.path or non_placeholder(env.get("localePath"))
    pattern = args.pattern or non_placeholder(env.get("pattern")) or "locale"
    should_apply = args.apply if apply is None else apply
    should_yes = args.yes if yes is None else yes

    remote_args: list[str] = []
    if namespace:
        remote_args.extend(["--namespace", namespace])
    if pod:
        remote_args.extend(["--pod", pod])
    if locale_path:
        remote_args.extend(["--path", locale_path])
    if pattern:
        remote_args.extend(["--pattern", pattern])
    if should_apply:
        if not should_yes:
            raise SystemExit("Refusing non-interactive apply without --yes. Run dry-run first, then rerun with --apply --yes.")
        remote_args.extend(["--apply", "--yes"])
    return remote_args


def require_paramiko():
    if importlib.util.find_spec("paramiko") is None:
        raise SystemExit(
            "Python package 'paramiko' is required for password-based SSH.\n"
            "Install it with: python -m pip install paramiko\n"
            "Or use FinalShell/native SSH and run refresh_puc_language.sh manually."
        )
    import paramiko

    return paramiko


def read_password(env: dict) -> str:
    password = non_placeholder(env.get("password"))
    if password:
        return password

    password_env = non_placeholder(env.get("passwordEnv"))
    if password_env:
        import os

        password = os.environ.get(password_env, "")
        if password:
            return password
        raise SystemExit(f"Environment variable configured by passwordEnv is empty: {password_env}")

    return getpass.getpass("SSH password: ")


def run_remote(script_path: Path, env: dict, remote_args: list[str]) -> int:
    paramiko = require_paramiko()

    auth_method = non_placeholder(env.get("authMethod")) or "password"
    if auth_method != "password":
        raise SystemExit(f"Unsupported authMethod '{auth_method}'. This runner currently supports password authentication.")

    name = non_placeholder(env.get("name"))
    host = non_placeholder(env.get("host"))
    username = non_placeholder(env.get("username") or env.get("user"))
    port = int(env.get("port") or 22)
    timeout = int(env.get("timeoutSeconds") or 20)
    password = read_password(env)

    if not host:
        raise SystemExit("Environment host is required")
    if not username:
        raise SystemExit("Environment username is required")
    if not password:
        raise SystemExit("Environment password is required")

    remote_command = "bash -s -- " + " ".join(shlex.quote(arg) for arg in remote_args)
    script = script_path.read_text(encoding="utf-8")

    if name:
        print(f"Environment: {name}")
    print(f"Connecting to {username}@{host}:{port}")
    print(f"Auth method: {auth_method}")
    print("Password: <redacted>")
    print(f"Remote command: {remote_command}")
    print("")

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        try:
            client.connect(
                hostname=host,
                port=port,
                username=username,
                password=password,
                timeout=timeout,
                banner_timeout=timeout,
                auth_timeout=timeout,
                look_for_keys=False,
                allow_agent=False,
            )
        except (OSError, socket.timeout, paramiko.SSHException) as exc:
            raise SystemExit(f"SSH connection failed for {username}@{host}:{port}: {exc}") from exc

        stdin, stdout, stderr = client.exec_command(remote_command)
        stdin.write(script)
        stdin.channel.shutdown_write()

        out = stdout.read().decode("utf-8", errors="replace")
        err = stderr.read().decode("utf-8", errors="replace")
        if out:
            print(out, end="")
        if err:
            print(err, end="", file=sys.stderr)
        return stdout.channel.recv_exit_status()
    finally:
        client.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Refresh PUC language/locale entries through password-based SSH config.")
    parser.add_argument("--host", help="Environment host, name, or alias from shared ssh-config")
    parser.add_argument("--ssh-config-root", help="One-command override for the shared ssh-config root")
    parser.add_argument("--config", help="Config path. Defaults to PUC_LANGUAGE_ENV_CONFIG, legacy PUC_ENV_CONFIG, or Desktop/agentSkillLocalConfig/refresh-puc-language/puc-env.local.json")
    parser.add_argument("--namespace", "-n", help="Override Kubernetes namespace")
    parser.add_argument("--pod", help="Override nmnginx pod name")
    parser.add_argument("--path", help="Override locale directory path")
    parser.add_argument("--pattern", help="Override describe grep pattern")
    parser.add_argument("--apply", action="store_true", help="Actually remove locale path and delete pod")
    parser.add_argument("--yes", action="store_true", help="Confirm non-interactive apply after reviewing dry-run output")
    parser.add_argument(
        "--auto-apply-if-trusted",
        action="store_true",
        help="Run dry-run first, then apply automatically when the selected environment has skipApplyConfirmation=true",
    )
    parser.add_argument(
        "--remember-apply-confirmation",
        action="store_true",
        help="After a successful --apply, set skipApplyConfirmation=true for this environment",
    )
    parser.add_argument(
        "--forget-apply-confirmation",
        action="store_true",
        help="Set skipApplyConfirmation=false for this environment and exit",
    )
    parser.add_argument(
        "--compact-config",
        action="store_true",
        help="Remove empty/default optional fields from the selected environment config and exit",
    )
    args = parser.parse_args()

    ssh_env, ssh_path = load_ssh_environment(args.host, args.ssh_config_root)
    resolved_host = non_placeholder(ssh_env.get("host"))
    config_path = resolve_config_path(args.config)
    config = load_config(config_path, resolved_host)
    business_env = find_environment(config_path, config, resolved_host)
    if args.compact_config:
        compact_selected_environment(config_path, config, business_env)
        return 0

    env = merge_login(business_env, ssh_env)
    validate_environment(env, env_label(env), ssh_path)
    script_path = Path(__file__).resolve().with_name("refresh_puc_language.sh")

    if args.apply and args.auto_apply_if_trusted:
        raise SystemExit("--auto-apply-if-trusted cannot be combined with --apply")
    if args.yes and not args.apply:
        raise SystemExit("--yes is only valid with --apply")
    if args.remember_apply_confirmation and not args.apply:
        raise SystemExit("--remember-apply-confirmation requires --apply --yes")

    if args.forget_apply_confirmation:
        set_skip_apply_confirmation(config_path, config, business_env, False)
        return 0

    if args.auto_apply_if_trusted:
        dry_run_args = build_remote_args(args, env, apply=False, yes=False)
        dry_run_status = run_remote(script_path, env, dry_run_args)
        if dry_run_status != 0:
            return dry_run_status

        if not config_bool(env.get("skipApplyConfirmation")):
            print("")
            print("Dry run complete. Ask for confirmation before applying, or rerun with --apply --yes.")
            print("To remember this choice after applying, use --remember-apply-confirmation.")
            return 0

        print("")
        print("skipApplyConfirmation=true for this environment; applying without an extra prompt.")
        apply_args = build_remote_args(args, env, apply=True, yes=True)
        return run_remote(script_path, env, apply_args)

    remote_args = build_remote_args(args, env)
    status = run_remote(script_path, env, remote_args)
    if status == 0 and args.apply and args.remember_apply_confirmation:
        set_skip_apply_confirmation(config_path, config, business_env, True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
