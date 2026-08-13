---
name: replace-env-dist
description: Build an optional frontend project, upload its dist directory through SSH or FinalShell to a target PUC environment, discover or add a missing service through the environment-local YSP API, wait for its pod, and copy dist into /usr/share/nginx/html. Use when the user asks to replace, publish, upload, or deploy a local dist directory to a PUC environment, especially when a host/IP, FinalShell, YSP, websttf, kubectl cp, a missing service, or an optional build command is mentioned.
---

# Replace Environment Dist

## Safety Rules

- Never store credentials in this skill. Read SSH login fields from shared `ssh-config/environments.local.json`; keep deployment-specific fields in this skill's business config.
- Treat deployment as a live-environment mutation. Always run preflight first. Apply only after the user confirms the exact local dist, host, `/home` directory, namespace, pod, and destination.
- Never guess missing initialization information. Require the target environment, local dist (or project and build command), and `/home/<specified-directory>`. The service defaults to `websttf`; all other missing values require discovery or confirmation.
- Never create Kubernetes resources directly. If the requested service has no pod and no YSP service record, allow the bundled runner to add it only through `https://127.0.0.1:12183` after preflight confirmation. Do not add a duplicate when a YSP record already exists.
- Call the YSP API only from the authenticated SSH session through localhost. Do not send or store `access_token`; the environment-local endpoints have been verified to accept requests without it.
- Do not emulate shell Tab completion. Resolve pods deterministically from `kubectl get pods -n <namespace> -o json`. If multiple `<service>-*` pods match, select the one with the latest `metadata.creationTimestamp` and show that choice in preflight.
- Accept a remote directory only as a relative path below `/home`; reject absolute paths, `..`, empty segments, and shell metacharacters.
- Do not print passwords. Do not run a user-provided build command outside the explicitly selected local project directory.

## Required Initialization

Collect or resolve these values before apply:

1. Target host/name and SSH login method from shared SSH config, native SSH, or FinalShell.
2. Local source:
   - Existing `dist` path; or
   - Project directory plus the exact build command. Run the command locally, then require `<project>/dist` unless `--dist` overrides it.
3. Remote directory below `/home`, for example `frontend-release` meaning `/home/frontend-release`.
4. Service name. Default to `websttf` only when omitted.
5. Namespace. Use configured value only if it exists. Otherwise run `kubectl get ns`; if `puc` exists exactly, use it, and if not, show candidates and ask the user to choose.

Do not begin an apply while any required value remains ambiguous.

## Shared SSH Config

Before first connection, run this skill's `scripts/Set-SshConfigRoot.ps1 -Status`. Let the user select the default `Desktop\agentSkillLocalConfig\ssh-config` or an absolute custom root when required. Persist the choice with `-UseDefault` or `-Path <absolute-path>`; immediately create `environments.local.json` from the bundled template when missing and never overwrite it. Resolve login fields as `defaults + environment`, with environment fields taking precedence. Use `--ssh-config-root <absolute-path>` for a one-command override.

When a concrete new host is supplied, append only its host so it inherits port, username, password/passwordEnv, and timeout from `defaults`. Do not copy credentials from `refresh-puc-locale`.

Keep `scripts/ssh_config.py`, `scripts/Set-SshConfigRoot.ps1`, and `assets/environments.local.template.json` self-contained in this skill. Do not require a separately installed `ssh-config` skill.

## Business Config

Resolve config in this order: `--config`, `REPLACE_ENV_DIST_CONFIG`, then:

```text
C:\Users\<user>\Desktop\agentSkillLocalConfig\replace-env-dist\puc-env.local.json
```

If missing, the runner creates a business entry containing only `host` and `namespace`. Match SSH aliases in the shared config first, then use the resolved host for this business config. `REPLACE_ENV_DIST_CONFIG` and `--config` remain supported for selecting the business-config file.

## Workflow

1. If a build is requested, run it in the selected project directory. Stop on failure.
2. Resolve and validate the local dist directory. Reject a missing, non-directory, or empty dist.
3. Run the bundled runner without `--apply`. It connects to the host and reports namespaces, selected namespace, matching pods, target paths, and the exact operation.
4. If namespace discovery is ambiguous, stop and ask the user to resolve it. If the service has no pod, query YSP `getProducts`, select the unique product with `productName=puc`, `productType=PUC`, and `realProductType=PUC`, then inspect its service details.
5. If the target service has no YSP record, query `getServiceType` with the selected product type and version. Stop if the service is unsupported. Show the resolved product ID, version, node IP, and planned `deployAddedOnService` action in preflight. If a YSP record already exists, show that the runner will wait for its pod and will not add a duplicate.
6. After the user confirms the preview, rerun with `--apply --yes`. Recheck YSP immediately before adding so concurrent or repeated runs remain idempotent. Call `deployAddedOnService` without an access token only when the service record is still absent.
7. Wait until the selected service pod is Running and Ready. Stop on timeout; do not upload or copy dist to an unavailable pod. If multiple pods match the service, select the newest by Kubernetes creation time.
8. Apply then performs:
   - Create `/home/<specified-directory>` if absent.
   - Replace `/home/<specified-directory>/dist` via SFTP upload.
   - Run `cd /home/<specified-directory> && chmod 777 -R *`.
   - Run `kubectl cp ./dist <resolved-pod>:/usr/share/nginx/html/ -n <namespace>` from that directory.
9. Report the command result and resolved pod. Do not claim success unless `kubectl cp` exits zero.
10. Only after the entire operation succeeds, tell the user to visit `https://<specified-environment>:16886` to verify the result. Use the environment value supplied by the user; if none was supplied, use the configured host. Never show this verification prompt after a failed or partial deployment.

## Bundled Runner

Preflight an existing dist:

```powershell
python C:\Users\<user>\.codex\skills\replace-env-dist\scripts\run_replace_env_dist.py --host 10.0.0.1 --dist C:\path\to\dist --remote-dir frontend-release
```

Build, then preflight:

```powershell
python C:\Users\<user>\.codex\skills\replace-env-dist\scripts\run_replace_env_dist.py --host 10.0.0.1 --project C:\path\to\project --build-command "npm run build" --remote-dir frontend-release
```

Apply only after confirming preflight:

```powershell
python C:\Users\<user>\.codex\skills\replace-env-dist\scripts\run_replace_env_dist.py --host 10.0.0.1 --dist C:\path\to\dist --remote-dir frontend-release --apply --yes
```

Optional overrides: `--namespace <name>`, `--service <name>` (default `websttf`), `--config <business-config-path>`, `--ssh-config-root <root>`, `--pod <exact-pod>`, and `--service-ready-timeout <seconds>` (default `300`). An absent exact `--pod` cannot trigger automatic service creation because YSP does not guarantee an exact generated pod name.

If password SSH is unavailable but FinalShell is connected, use FinalShell for the same workflow. Preserve the same YSP discovery, preflight confirmation, duplicate prevention, Ready wait, and deployment rules.

## Manual Remote Fallback

```bash
kubectl get ns
kubectl get pods -n <namespace>
# If the pod is absent, call getProducts and getServiceType through https://127.0.0.1:12183.
# After confirmation only, call deployAddedOnService and wait for the pod to become Ready.
mkdir -p -- /home/<specified-directory>
# Upload/replace dist at /home/<specified-directory>/dist through FinalShell.
cd /home/<specified-directory>
chmod 777 -R *
kubectl cp ./dist <service-pod>:/usr/share/nginx/html/ -n <namespace>
```

Before `kubectl cp`, verify `<service-pod>` exists, belongs to the requested service, and is Ready. When several pods belong to the service, use the one with the latest `metadata.creationTimestamp`. Never call the YSP mutation before the user confirms the resolved environment, product, service, and destination.

After every command above succeeds, report:

```text
Visit https://<specified-environment>:16886 to verify the result.
```
