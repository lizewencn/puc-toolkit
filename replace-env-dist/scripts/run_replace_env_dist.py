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
import subprocess
import sys
import time
import uuid
from pathlib import Path, PurePosixPath
from urllib.parse import urlencode


from ssh_config import load_environment as load_ssh_environment, merge_login


PLACEHOLDERS = {"", "your-host", "your-username", "your-password", "username", "password"}


class MissingServiceError(RuntimeError):
    pass


def config_path(value):
    if value:
        return Path(value).expanduser()
    env = os.environ.get("REPLACE_ENV_DIST_CONFIG", "").strip()
    if env:
        return Path(env).expanduser()
    return Path.home() / "Desktop" / "agentSkillLocalConfig" / "replace-env-dist" / "puc-env.local.json"


def non_placeholder(value):
    text = "" if value is None else str(value).strip()
    return "" if text in PLACEHOLDERS else text


def valid_host(value):
    return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value or ""))


def environment_matches(env, selector):
    values = [env.get("host"), env.get("name"), *(env.get("aliases") or [])]
    return selector in values


def ensure_config(path, host):
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if host and valid_host(host):
        data = {"environments": [{"host": host, "namespace": "puc"}]}
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    else:
        template = Path(__file__).resolve().parents[1] / "assets" / "puc-env.local.template.json"
        shutil.copyfile(template, path)
    message = f"Created local config: {path}"
    message += "\nReview host and namespace; SSH login comes from shared ssh-config. Then rerun."
    raise SystemExit(message)


def load_environment(path, selector):
    ensure_config(path, selector)
    try:
        config = json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc
    environments = config.get("environments")
    if not isinstance(environments, list) or not environments:
        raise SystemExit("Config must contain a non-empty environments array")
    if selector:
        for env in environments:
            if environment_matches(env, selector):
                return env
        if valid_host(selector):
            source = environments[0] if environments else {}
            env = {"host": selector, "namespace": source.get("namespace", "puc")}
            environments.append(env)
            path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
            return env
        raise SystemExit(f"No configured environment matches: {selector}")
    if len(environments) != 1:
        raise SystemExit("Multiple environments configured; pass --host <host-or-name>")
    return environments[0]


def validate_remote_dir(value):
    if not value or value.startswith(("/", "\\")) or ".." in PurePosixPath(value).parts:
        raise SystemExit("--remote-dir must be a relative path below /home and cannot contain '..'")
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", value) or "//" in value:
        raise SystemExit("--remote-dir contains unsupported characters or empty path segments")
    return "/home/" + value.strip("/")


def resolve_dist(args):
    project = Path(args.project).expanduser().resolve() if args.project else None
    if args.build_command:
        if not project or not project.is_dir():
            raise SystemExit("--build-command requires an existing --project directory")
        print(f"Building in: {project}")
        result = subprocess.run(args.build_command, cwd=project, shell=True)
        if result.returncode:
            raise SystemExit(f"Build command failed with exit code {result.returncode}")
    dist = Path(args.dist).expanduser() if args.dist else (project / "dist" if project else None)
    if dist is None:
        raise SystemExit("Provide --dist, or provide --project (optionally with --build-command)")
    dist = dist.resolve()
    if not dist.is_dir():
        raise SystemExit(f"Dist directory does not exist: {dist}")
    if not any(dist.iterdir()):
        raise SystemExit(f"Dist directory is empty: {dist}")
    return dist


def require_paramiko():
    if importlib.util.find_spec("paramiko") is None:
        raise SystemExit("Paramiko is required. Run: python -m pip install paramiko, or use FinalShell manual fallback.")
    import paramiko
    return paramiko


def password_for(env):
    value = non_placeholder(env.get("password"))
    if value:
        return value
    name = non_placeholder(env.get("passwordEnv"))
    if name:
        value = os.environ.get(name, "")
        if value:
            return value
        raise SystemExit(f"passwordEnv variable is empty: {name}")
    return getpass.getpass("SSH password: ")


def run(client, command, check=True):
    _, stdout, stderr = client.exec_command(command)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    status = stdout.channel.recv_exit_status()
    if check and status:
        raise RuntimeError(f"Remote command failed ({status}): {command}\n{err or out}")
    return status, out, err


def ysp_request(client, endpoint, query=None, method="GET"):
    url = f"https://127.0.0.1:12183/dpProxyApi/dp/deployMng/{endpoint}"
    if query:
        url += "?" + urlencode(query)
    method_args = ""
    if method == "POST":
        method_args = " -X POST -H 'Content-Type: application/json' --data '{}'"
    command = (
        "curl -k -sS --connect-timeout 5 --max-time 30"
        f"{method_args} -w '\n__YSP_HTTP__%{{http_code}}' {shlex.quote(url)}"
    )
    _, out, _ = run(client, command)
    body, marker, status_text = out.rpartition("\n__YSP_HTTP__")
    if not marker or not status_text.isdigit():
        raise RuntimeError(f"YSP API returned an unreadable HTTP response for {endpoint}")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"YSP API returned invalid JSON for {endpoint}: {exc}") from exc
    http_status = int(status_text)
    api_status = payload.get("status")
    if http_status != 200 or api_status != 0:
        description = payload.get("desc")
        detail = f": {description}" if description else ""
        raise RuntimeError(
            f"YSP API {endpoint} failed (HTTP {http_status}, status {api_status}){detail}"
        )
    return payload


def select_puc_product(entries):
    candidates = []
    for entry in entries if isinstance(entries, list) else []:
        product = entry.get("product") if isinstance(entry, dict) else None
        if not isinstance(product, dict):
            continue
        if str(product.get("productName") or "").lower() != "puc":
            continue
        if str(product.get("productType") or "").upper() != "PUC":
            continue
        real_type = str(product.get("realProductType") or "PUC").upper()
        if real_type == "PUC":
            candidates.append((entry, product))
    if not candidates:
        raise RuntimeError("YSP getProducts returned no productName=puc, productType=PUC product")
    if len(candidates) > 1:
        choices = ", ".join(
            f"{product.get('productId')} ({product.get('productVersion')})"
            for _, product in candidates
        )
        raise RuntimeError(f"YSP returned multiple matching PUC products: {choices}")
    return candidates[0]


def inspect_ysp_service(client, service):
    products = ysp_request(client, "getProducts").get("data")
    entry, product = select_puc_product(products)
    details = entry.get("details")
    details = details if isinstance(details, list) else []
    service_record = next(
        (
            detail
            for detail in details if isinstance(detail, dict)
            and detail.get("serviceName") == service
        ),
        None,
    )
    return product, service_record


def validate_ysp_service_type(client, product, service):
    product_type = product.get("productType")
    product_version = product.get("productVersion")
    if not product.get("productId") or not product_type or not product_version:
        raise RuntimeError("The selected PUC product is missing productId, productType, or productVersion")
    payload = ysp_request(
        client,
        "getServiceType",
        {"productType": product_type, "productVersion": product_version},
    )
    supported = payload.get("data")
    if not isinstance(supported, list) or service not in supported:
        raise RuntimeError(
            f"Service '{service}' is not available from YSP getServiceType for {product_type} {product_version}"
        )


def add_ysp_service(client, product, service, node_ip):
    ysp_request(
        client,
        "deployAddedOnService",
        {
            "serviceName": service,
            "productId": product["productId"],
            "nodeIp": node_ip,
        },
        method="POST",
    )


def select_namespace(client, requested):
    _, out, _ = run(client, "kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{\"\\n\"}{end}'")
    namespaces = [line.strip() for line in out.splitlines() if line.strip()]
    if requested:
        if requested not in namespaces:
            raise SystemExit(f"Namespace '{requested}' does not exist. Available: {', '.join(namespaces)}")
        return requested, namespaces
    if "puc" in namespaces:
        return "puc", namespaces
    raise SystemExit("Namespace 'puc' does not exist. Choose one with --namespace. Available: " + ", ".join(namespaces))


def choose_pod(items, namespace, service, exact):
    matches = []
    for item in items:
        metadata = item.get("metadata") or {}
        name = str(metadata.get("name") or "")
        if (exact and name == exact) or (not exact and name.startswith(service + "-")):
            matches.append((name, str(metadata.get("creationTimestamp") or "")))
    if not matches:
        raise MissingServiceError(
            f"Service '{service}' does not exist in namespace '{namespace}' (no matching pod)."
        )
    matches.sort(key=lambda pod: (pod[1], pod[0]), reverse=True)
    return matches[0][0], matches


def select_pod(client, namespace, service, exact):
    cmd = f"kubectl get pods -n {shlex.quote(namespace)} -o json"
    _, out, _ = run(client, cmd)
    try:
        payload = json.loads(out)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"kubectl returned invalid pod JSON: {exc}") from exc
    items = payload.get("items")
    if not isinstance(items, list):
        raise RuntimeError("kubectl pod JSON does not contain an items array")
    return choose_pod(items, namespace, service, exact)


def pod_is_ready(item):
    status = item.get("status") or {}
    if status.get("phase") != "Running":
        return False
    return any(
        condition.get("type") == "Ready" and condition.get("status") == "True"
        for condition in status.get("conditions") or []
    )


def wait_for_ready_pod(client, namespace, service, exact, timeout_seconds):
    deadline = time.monotonic() + timeout_seconds
    last_state = "no matching pod"
    while time.monotonic() < deadline:
        cmd = f"kubectl get pods -n {shlex.quote(namespace)} -o json"
        _, out, _ = run(client, cmd)
        try:
            items = json.loads(out).get("items")
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"kubectl returned invalid pod JSON while waiting: {exc}") from exc
        if not isinstance(items, list):
            raise RuntimeError("kubectl pod JSON does not contain an items array")
        try:
            pod, matches = choose_pod(items, namespace, service, exact)
        except MissingServiceError:
            time.sleep(5)
            continue
        selected = next(item for item in items if (item.get("metadata") or {}).get("name") == pod)
        status = selected.get("status") or {}
        last_state = f"{pod}: phase={status.get('phase')}, ready={pod_is_ready(selected)}"
        if pod_is_ready(selected):
            return pod, matches
        time.sleep(5)
    raise RuntimeError(
        f"Timed out after {timeout_seconds}s waiting for service '{service}' to become Ready ({last_state})"
    )


def mkdir_sftp(sftp, path):
    current = ""
    for part in PurePosixPath(path).parts:
        if part == "/":
            current = "/"
            continue
        current = str(PurePosixPath(current) / part)
        try:
            sftp.stat(current)
        except OSError:
            sftp.mkdir(current)


def upload_tree(sftp, local, remote):
    mkdir_sftp(sftp, remote)
    for item in local.iterdir():
        target = str(PurePosixPath(remote) / item.name)
        if item.is_dir():
            upload_tree(sftp, item, target)
        else:
            sftp.put(str(item), target)


def main():
    parser = argparse.ArgumentParser(description="Build and replace dist in a PUC Kubernetes environment")
    parser.add_argument("--host", help="Configured host, name, alias, or a new host/IP")
    parser.add_argument("--config")
    parser.add_argument("--ssh-config-root", help="One-command override for the shared ssh-config root")
    parser.add_argument("--dist")
    parser.add_argument("--project")
    parser.add_argument("--build-command")
    parser.add_argument("--remote-dir", required=True, help="Relative directory below /home")
    parser.add_argument("--service", default="websttf")
    parser.add_argument("--namespace", "-n")
    parser.add_argument("--pod")
    parser.add_argument(
        "--service-ready-timeout",
        type=int,
        default=300,
        help="Seconds to wait for an added or already-starting service pod to become Ready",
    )
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--yes", action="store_true")
    args = parser.parse_args()
    if args.yes and not args.apply:
        raise SystemExit("--yes is only valid with --apply")
    if args.apply and not args.yes:
        raise SystemExit("Refusing apply without --yes. Run preflight first, confirm it, then use --apply --yes.")
    if args.service_ready_timeout <= 0:
        raise SystemExit("--service-ready-timeout must be greater than zero")

    dist = resolve_dist(args)
    remote_root = validate_remote_dir(args.remote_dir)
    ssh_env, ssh_path = load_ssh_environment(args.host, args.ssh_config_root)
    resolved_host = non_placeholder(ssh_env.get("host"))
    path = config_path(args.config)
    business_env = load_environment(path, resolved_host)
    env = merge_login(business_env, ssh_env)
    host = non_placeholder(env.get("host"))
    username = non_placeholder(env.get("username") or env.get("user"))
    if not host or not username:
        raise SystemExit(f"Environment config is incomplete: {ssh_path} (host and username are required)")
    paramiko = require_paramiko()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(host, port=int(env.get("port", 22)), username=username, password=password_for(env), timeout=int(env.get("timeoutSeconds", 20)), look_for_keys=False, allow_agent=False)
        requested_ns = args.namespace or non_placeholder(env.get("namespace"))
        namespace, namespaces = select_namespace(client, requested_ns)
        product = None
        service_record = None
        try:
            pod, matching_pods = select_pod(client, namespace, args.service, args.pod)
        except MissingServiceError:
            if args.pod:
                raise SystemExit(
                    f"Exact pod '{args.pod}' does not exist; automatic service creation cannot guarantee an exact pod name."
                )
            product, service_record = inspect_ysp_service(client, args.service)
            if not service_record:
                validate_ysp_service_type(client, product, args.service)
            pod = None
            matching_pods = []
        print(f"Local dist: {dist}")
        print(f"Environment: {username}@{host}:{env.get('port', 22)}")
        print(f"Namespaces: {', '.join(namespaces)}")
        print(f"Namespace: {namespace}")
        print(f"Service: {args.service}")
        print(f"Pod: {pod or '(not created yet)'}")
        if len(matching_pods) > 1:
            candidates = ", ".join(f"{name} ({created or 'unknown creation time'})" for name, created in matching_pods)
            print(f"Matching pods: {candidates}")
            print("Pod selection: newest metadata.creationTimestamp")
        print(f"Remote dist: {remote_root}/dist")
        print(f"Container destination: /usr/share/nginx/html/")
        if product:
            print(
                "YSP product: "
                f"{product.get('productName')} {product.get('productVersion')} "
                f"(productId={product.get('productId')})"
            )
            if service_record:
                print(
                    "Service action: wait for the existing YSP service record to create a Ready pod; "
                    "do not add a duplicate"
                )
            else:
                print("Service action: add through the YSP localhost API during apply, then wait for a Ready pod")
        if not args.apply:
            print("Preflight complete. Confirm these values, then rerun with --apply --yes.")
            return 0

        if not pod:
            if service_record:
                print("YSP service record already exists; waiting for its pod instead of adding a duplicate.")
            else:
                # Recheck immediately before the mutation to keep repeated or concurrent runs idempotent.
                product, service_record = inspect_ysp_service(client, args.service)
                if service_record:
                    print("YSP service record appeared after preflight; waiting for its pod.")
                else:
                    validate_ysp_service_type(client, product, args.service)
                    add_ysp_service(client, product, args.service, host)
                    print(f"YSP accepted the request to add service: {args.service}")
            pod, matching_pods = wait_for_ready_pod(
                client,
                namespace,
                args.service,
                args.pod,
                args.service_ready_timeout,
            )
            print(f"Service pod is Ready: {pod}")

        staging = f"{remote_root}/.dist-upload-{uuid.uuid4().hex}"
        run(client, f"mkdir -p -- {shlex.quote(remote_root)} && rm -rf -- {shlex.quote(staging)}")
        sftp = client.open_sftp()
        try:
            upload_tree(sftp, dist, staging)
        finally:
            sftp.close()
        remote_dist = f"{remote_root}/dist"
        run(client, f"rm -rf -- {shlex.quote(remote_dist)} && mv -- {shlex.quote(staging)} {shlex.quote(remote_dist)}")
        run(client, f"cd {shlex.quote(remote_root)} && chmod 777 -R *")
        cp = f"cd {shlex.quote(remote_root)} && kubectl cp ./dist {shlex.quote(pod)}:/usr/share/nginx/html/ -n {shlex.quote(namespace)}"
        _, out, err = run(client, cp)
        if out:
            print(out, end="")
        if err:
            print(err, end="", file=sys.stderr)
        print(f"Deployment succeeded: {pod} ({namespace})")
        environment_address = args.host or host
        print(f"Visit https://{environment_address}:16886 to verify the result.")
        return 0
    except (OSError, socket.timeout, paramiko.SSHException, RuntimeError) as exc:
        raise SystemExit(f"Deployment failed: {exc}") from exc
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
