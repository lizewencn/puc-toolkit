#!/usr/bin/env python3
import argparse
import getpass
import importlib.util
import json
import os
import re
import shlex
import shutil
import socket
import sys
import tarfile
from pathlib import Path


from ssh_config import load_environment as load_ssh_environment, merge_login


PLACEHOLDERS = {
    "",
    "username",
    "password",
    "your-env-name",
    "your-host",
    "your-log-service-host",
    "your-log-service-name",
    "your-username",
    "your-password",
}


def default_config_path() -> Path:
    return Path.home() / "Desktop" / "agentSkillLocalConfig" / "get-business-log" / "business-log-env.local.json"


def template_path() -> Path:
    return Path(__file__).resolve().parents[1] / "assets" / "business-log-env.local.template.json"


def resolve_config_path(value: str | None) -> Path:
    if value:
        return Path(value).expanduser()

    env_path = os.environ.get("BUSINESS_LOG_ENV_CONFIG", "").strip()
    if env_path:
        return Path(env_path).expanduser()

    return default_config_path()


def non_placeholder(value: object) -> str:
    text = "" if value is None else str(value)
    return "" if text.strip() in PLACEHOLDERS else text.strip()


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

    if "." not in text and "-" not in text:
        return False

    return re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]", text) is not None


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
    values.extend(str(alias).strip() for alias in (env.get("aliases") or []))
    return selector in values


def environment_has_reusable_login(env: dict) -> bool:
    username = non_placeholder(env.get("username") or env.get("user"))
    password = non_placeholder(env.get("password"))
    password_env = non_placeholder(env.get("passwordEnv"))
    return bool(username and (password or password_env))


def build_environment_skeleton(host: str) -> dict:
    return {"host": host}


def build_environment_from_source(host: str, source: dict | None) -> dict:
    env = build_environment_skeleton(host)
    if not source:
        return env

    for key, default_value in (
        ("baseDir", "/opt/logserver/log"),
        ("remoteOutputDir", "/tmp/get-business-log"),
    ):
        value = non_placeholder(source.get(key))
        if value and value != default_value:
            env[key] = value

    return env


def save_config(path: Path, config: dict) -> None:
    path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def ensure_config_exists(path: Path, initial_host: str | None = None) -> None:
    if path.exists():
        return

    path.parent.mkdir(parents=True, exist_ok=True)
    if initial_host and host_selector_can_be_created(initial_host):
        config = {"environments": [build_environment_skeleton(initial_host)]}
        save_config(path, config)
        raise SystemExit(
            "Config file was missing, so a new one was created with the requested log service host.\n"
            f"Created: {path}\n"
            f"Log service host: {initial_host}\n"
            "Configure its login once in shared ssh-config, then rerun this command."
        )

    source = template_path()
    if not source.exists():
        raise SystemExit(f"Config file not found and template is missing: {source}")

    shutil.copyfile(source, path)
    raise SystemExit(
        "Config file was missing, so a template was created.\n"
        f"Created: {path}\n"
        "Fill in the log service host and configure its login in shared ssh-config, then rerun this command."
    )


def load_config(path: Path, initial_host: str | None = None) -> dict:
    ensure_config_exists(path, initial_host)
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc


def add_missing_environment(config_path: Path, config: dict, host: str, environments: list[dict]) -> dict:
    source = environments[0] if environments else None
    env = build_environment_from_source(host, source)
    environments.append(env)
    save_config(config_path, config)

    print(f"No log service environment found for host/name/alias: {host}")
    if source:
        print(f"Added {host} to {config_path} using business defaults from {env_label(source)}.")
    else:
        print(f"Added log service host {host} to {config_path}; login comes from shared ssh-config.")
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
            f"No log service environment found for host/name/alias: {host}\n"
            "Only host-like selectors such as an IP address or FQDN are auto-added to the local config."
        )

    if not environments:
        raise SystemExit("Config must contain a non-empty environments array")

    if len(environments) == 1:
        return environments[0]

    labels = ", ".join(env_label(env) for env in environments)
    raise SystemExit(f"Multiple log service environments configured; pass --host <host-or-name>. Available: {labels}")


def validate_environment(env: dict, label: str, config_path: Path) -> None:
    missing = []
    if not non_placeholder(env.get("host")):
        missing.append("host")
    if not non_placeholder(env.get("username") or env.get("user")):
        missing.append("username")
    if not non_placeholder(env.get("password")) and not non_placeholder(env.get("passwordEnv")):
        missing.append("password or passwordEnv")

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
            f"Log service config is incomplete for {label}.\n"
            f"Config file: {config_path}\n"
            "Please fill or fix:\n"
            f"{fields}"
        )


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

    compact["username"] = env.get("username", env.get("user", ""))

    password = non_placeholder(env.get("password"))
    password_env = non_placeholder(env.get("passwordEnv"))
    if password:
        compact["password"] = env.get("password", "")
    if password_env:
        compact["passwordEnv"] = password_env

    aliases = env.get("aliases")
    if isinstance(aliases, list) and aliases:
        compact["aliases"] = aliases

    for key, default_value in (
        ("baseDir", "/opt/logserver/log"),
        ("remoteOutputDir", "/tmp/get-business-log"),
    ):
        value = non_placeholder(env.get(key))
        if value and value != default_value:
            compact[key] = value

    timeout = env.get("timeoutSeconds")
    try:
        parsed_timeout = int(timeout)
    except (TypeError, ValueError):
        parsed_timeout = 20
    if parsed_timeout != 20:
        compact["timeoutSeconds"] = timeout

    return compact


def compact_selected_environment(config_path: Path, config: dict, env: dict) -> None:
    label = env_label(env)
    compact = compact_environment(env)
    env.clear()
    env.update(compact)
    save_config(config_path, config)
    print(f"Compacted config for {label}.")


def require_paramiko():
    if importlib.util.find_spec("paramiko") is None:
        raise SystemExit(
            "Python package 'paramiko' is required for password-based SSH.\n"
            "Install it with: python -m pip install paramiko\n"
            "Or use FinalShell/native SSH and run get_business_log.sh manually."
        )
    import paramiko

    return paramiko


def read_password(env: dict) -> str:
    password = non_placeholder(env.get("password"))
    if password:
        return password

    password_env = non_placeholder(env.get("passwordEnv"))
    if password_env:
        password = os.environ.get(password_env, "")
        if password:
            return password
        raise SystemExit(f"Environment variable configured by passwordEnv is empty: {password_env}")

    return getpass.getpass("SSH password: ")


def safe_local_segment(value: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value.strip())
    cleaned = cleaned.strip(" .")
    return cleaned or "environment"


def build_remote_args(args: argparse.Namespace, env: dict) -> tuple[list[str], str, str]:
    log_dir = args.log_dir or args.target_ip or args.log_ip
    if not log_dir:
        raise SystemExit("Log service environment directory name is required. Pass --log-dir <directory-name> after confirming it with the user.")

    base_dir = args.base_dir or non_placeholder(env.get("baseDir")) or "/opt/logserver/log"
    remote_output_dir = args.remote_output_dir or non_placeholder(env.get("remoteOutputDir")) or "/tmp/get-business-log"

    remote_args = [
        "--log-dir",
        log_dir,
        "--account",
        args.account,
        "--start",
        args.start,
        "--end",
        args.end,
        "--base-dir",
        base_dir,
        "--remote-output-dir",
        remote_output_dir,
    ]
    if args.include_gz or args.include_compressed:
        remote_args.append("--include-gz")
    if args.include_zst or args.include_compressed:
        remote_args.append("--include-zst")

    return remote_args, log_dir, remote_output_dir


def remote_command(remote_args: list[str]) -> str:
    return "bash -s -- " + " ".join(shlex.quote(arg) for arg in remote_args)


def parse_remote_value(output: str, key: str) -> str:
    pattern = re.compile(rf"^{re.escape(key)}=(.+)$", re.MULTILINE)
    match = pattern.search(output)
    return match.group(1).strip() if match else ""


def safe_extract_tar(archive_path: Path, output_dir: Path) -> list[Path]:
    output_root = output_dir.resolve()
    extracted: list[Path] = []

    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            target = (output_root / member.name).resolve()
            if target != output_root and output_root not in target.parents:
                raise SystemExit(f"Refusing to extract unsafe archive member: {member.name}")
        archive.extractall(output_root)
        extracted = [(output_root / member.name).resolve() for member in members]

    return extracted


def remote_path_under(path: str, root: str) -> bool:
    clean_root = root.rstrip("/")
    return bool(path and clean_root and (path == clean_root or path.startswith(clean_root + "/")))


def cleanup_remote(client, archive_path: str, work_dir: str, remote_output_dir: str) -> None:
    if not remote_path_under(archive_path, remote_output_dir):
        print(f"Skipping remote archive cleanup because path is outside output root: {archive_path}")
        return
    if work_dir and not remote_path_under(work_dir, remote_output_dir):
        print(f"Skipping remote work directory cleanup because path is outside output root: {work_dir}")
        work_dir = ""

    cleanup_parts = ["rm", "-f", "--", archive_path]
    cleanup_command = " ".join(shlex.quote(part) for part in cleanup_parts)
    if work_dir:
        cleanup_command += " && " + " ".join(shlex.quote(part) for part in ["rm", "-rf", "--", work_dir])

    _, stdout, stderr = client.exec_command(cleanup_command)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    status = stdout.channel.recv_exit_status()
    if out:
        print(out, end="")
    if err:
        print(err, end="", file=sys.stderr)
    if status != 0:
        print("Remote cleanup failed; downloaded files are still available locally.", file=sys.stderr)


def run_remote(args: argparse.Namespace, env: dict, config_path: Path) -> int:
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
    remote_args, log_dir, remote_output_dir = build_remote_args(args, env)

    if not host:
        raise SystemExit("Log service host is required")
    if not username:
        raise SystemExit("Environment username is required")
    if not password:
        raise SystemExit("Environment password is required")

    output_dir = Path(args.output_dir).expanduser() if args.output_dir else Path.home() / "Desktop" / f"{safe_local_segment(log_dir)}_业务日志"
    output_dir.mkdir(parents=True, exist_ok=True)

    script_path = Path(__file__).resolve().with_name("get_business_log.sh")
    script = script_path.read_text(encoding="utf-8")
    command = remote_command(remote_args)

    if name:
        print(f"Environment: {name}")
    print(f"Config file: {config_path}")
    if args.target_env:
        print(f"Target environment: {args.target_env}")
    print(f"Log service environment: {host}")
    print(f"Log service directory: {log_dir}")
    print(f"Connecting to {username}@{host}:{port}")
    print(f"Auth method: {auth_method}")
    print("Password: <redacted>")
    print(f"Remote command: {command}")
    print(f"Local output directory: {output_dir}")
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

        stdin, stdout, stderr = client.exec_command(command)
        stdin.write(script)
        stdin.channel.shutdown_write()

        out = stdout.read().decode("utf-8", errors="replace")
        err = stderr.read().decode("utf-8", errors="replace")
        status = stdout.channel.recv_exit_status()
        if out:
            print(out, end="")
        if err:
            print(err, end="", file=sys.stderr)
        if status != 0:
            return status

        archive_path = parse_remote_value(out, "ARCHIVE_PATH")
        work_dir = parse_remote_value(out, "WORK_DIR")
        if not archive_path:
            raise SystemExit("Remote script completed but did not print ARCHIVE_PATH.")

        local_archive = output_dir / Path(archive_path).name
        with client.open_sftp() as sftp:
            sftp.get(archive_path, str(local_archive))

        extracted = safe_extract_tar(local_archive, output_dir)
        matched_logs = [path for path in extracted if path.name == "matched.log"]

        if not args.keep_remote:
            cleanup_remote(client, archive_path, work_dir, remote_output_dir)

        print("")
        print(f"Downloaded archive: {local_archive}")
        print(f"Extracted to: {output_dir}")
        if matched_logs:
            print(f"Matched log: {matched_logs[0]}")
        return 0
    finally:
        client.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Collect account-scoped business logs from a log service host.")
    parser.add_argument("--target-env", help="Business target environment for user-facing context; does not determine the remote path")
    parser.add_argument("--host", help="Log service environment host, name, or alias from shared ssh-config")
    parser.add_argument("--ssh-config-root", help="One-command override for the shared ssh-config root")
    parser.add_argument("--config", help="Config path. Defaults to BUSINESS_LOG_ENV_CONFIG or Desktop/agentSkillLocalConfig/get-business-log/business-log-env.local.json")
    parser.add_argument("--log-dir", help="Directory used under /opt/logserver/log/<log-dir>/business_0")
    parser.add_argument("--target-ip", help="Backward-compatible alias for --log-dir")
    parser.add_argument("--log-ip", help="Backward-compatible alias for --log-dir")
    parser.add_argument("--account", required=True, help="Account text to match literally")
    parser.add_argument("--start", required=True, help='Inclusive start time, for example "2026-07-08 09:00:00"')
    parser.add_argument("--end", required=True, help='Inclusive end time, for example "2026-07-08 10:00:00"')
    parser.add_argument("--base-dir", help="Override remote log root. Default: /opt/logserver/log")
    parser.add_argument("--remote-output-dir", help="Override remote temp output root. Default: /tmp/get-business-log")
    parser.add_argument("--output-dir", help="Override local output directory. Default: Desktop/<log-dir>_业务日志")
    parser.add_argument("--include-gz", action="store_true", help="Also scan .gz log files")
    parser.add_argument("--include-zst", action="store_true", help="Also scan .zst log files")
    parser.add_argument("--include-compressed", action="store_true", help="Also scan .gz and .zst log files")
    parser.add_argument("--keep-remote", action="store_true", help="Keep remote archive and work directory after download")
    parser.add_argument("--compact-config", action="store_true", help="Remove empty/default optional fields from the selected environment config and exit")
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
    return run_remote(args, env, config_path)


if __name__ == "__main__":
    raise SystemExit(main())
