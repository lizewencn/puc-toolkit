---
name: refresh-puc-language
description: Refresh or rebuild PUC environment locale entries on a remote Kubernetes host. Use when the user needs to log in to an environment host, inspect nmnginx pods, find the locale path from `kubectl describe pod ... | grep locale`, remove that locale directory, and delete the nmnginx pod so Kubernetes recreates it. Also use when the user mentions FinalShell, target IP environments such as 10.x.x.x, PUC namespace differences, or updating environment word/locale entries.
---

# Refresh PUC Locale

## Core Safety Rules

- Never store usernames, passwords, IPs, or FinalShell credentials inside the skill folder.
- Read SSH login fields from shared `ssh-config/environments.local.json`; keep only locale-specific fields in this skill's business config.
- Prefer an already-open FinalShell session, SSH config alias, SSH key, or user-provided runtime input.
- Treat `rm -rf` as live-environment work. Run a dry run first and show the namespace, pod, locale lines, selected path, and exact commands before applying.
- If `skipApplyConfirmation: true` is set for the selected environment, still run the dry run first; after a successful dry run, apply without asking again. This setting is per environment only.
- Do not guess the namespace if `puc` is not present. Run `kubectl get ns`, show candidates, and ask the user which namespace to use.
- Do not delete unless the selected path is absolute, contains `locale`, is not a root/system directory, and comes from the `kubectl describe pod` locale output or is explicitly supplied by the user.

## Shared SSH Config

Before first connection, run this skill's `scripts/Set-SshConfigRoot.ps1 -Status`. Let the user select the default `Desktop\agentSkillLocalConfig\ssh-config` or an absolute custom root when required. Persist the choice with `-UseDefault` or `-Path <absolute-path>`; immediately create `environments.local.json` from the bundled template when missing and never overwrite it. Resolve login fields as `defaults + environment`, with environment overrides taking precedence. Use `--ssh-config-root <absolute-path>` only for a one-command override.

When a concrete new host is supplied, add only its host to shared SSH config so it inherits port, username, password/passwordEnv, and timeout from `defaults`.

Keep `scripts/ssh_config.py`, `scripts/Set-SshConfigRoot.ps1`, and `assets/environments.local.template.json` self-contained in this skill. Do not require a separately installed `ssh-config` skill.

## Business Config

Before connecting, resolve the config path in this order:

1. `--config <path>` argument
2. `PUC_LANGUAGE_ENV_CONFIG` environment variable (`PUC_ENV_CONFIG` remains a compatibility fallback)
3. Default path: `C:\Users\<user>\Desktop\agentSkillLocalConfig\refresh-puc-language\puc-env.local.json`

If the resolved config file does not exist and the user supplied a concrete environment host/IP in the current request, let `scripts/run_refresh_puc_language.py --host <host>` create a new local config containing that host. If no host/IP was supplied, copy `assets/puc-env.local.template.json` from this skill to that path, then stop and ask the user to fill it in.

Store only locale workflow settings in the existing business config. Minimal shape:

```json
{
  "environments": [
    {
      "host": "your-host",
      "namespace": "puc",
      "skipApplyConfirmation": false
    }
  ]
}
```

Rules:

- Keep `assets/puc-env.local.template.json` as the reusable template. Do not put real credentials in the template.
- Optional business fields: `name`, `aliases`, `pod`, `localePath`, and `pattern`.
- `pattern` defaults to `locale`.
- Support password authentication in `scripts/run_refresh_puc_language.py`; use FinalShell/manual SSH for private-key auth.
- Match the requested environment by `host`, `name`, or optional `aliases`.
- If a supplied host/IP is missing, let shared SSH config append only that host and inherit login fields from `defaults`. Let this business config inherit only reusable locale fields such as namespace and pattern; never inherit pod or localePath.
- Use `namespace`, `pod`, and `localePath` from config only when present; otherwise let the remote script discover them.
- Redact `password` in all output.
- If `password` is empty and `passwordEnv` is set, read the password from that environment variable.
- If both `password` and `passwordEnv` are empty, prompt interactively.
- Treat SSH host/authentication as required in shared config and `namespace` as required in business config.
- If shared login values remain placeholders, stop and tell the user which shared `defaults` fields to fill.
- Treat `skipApplyConfirmation` as an optional per-environment trust preference. It defaults to `false`. Only set it to `true` after the user explicitly chooses an option like "do not ask again for this environment".
- Use `--compact-config` to remove empty/default optional fields from an existing environment config.

## Workflow

1. Identify how commands will run.
   - If the user's request includes a concrete host/IP, pass it with `--host <host>` immediately. The runner will create or append that environment in the local config before connecting.
   - If the resolved config file is missing and no concrete host/IP was supplied, let `scripts/run_refresh_puc_language.py` create it from `assets/puc-env.local.template.json`, then ask the user to fill in the required fields.
   - If the resolved config file exists but the supplied host/IP is missing, let the runner append the new environment. If the runner inherited enough login defaults, continue to dry run. If required values are still missing, stop and tell the user which fields to fill.
   - If the resolved config file exists but required fields are missing or still placeholders, stop and tell the user which fields to fill.
   - If the resolved config file has credentials for the host, use `scripts/run_refresh_puc_language.py` from the skill.
   - If Codex has SSH access to the host through keys, use SSH without saving secrets.
   - If password login is only available through FinalShell, ask the user to open the target host in FinalShell and paste/run the generated command there.
   - If the current shell is already on the environment host, run the script locally.

2. Confirm Kubernetes context on the environment host.
   - Run `kubectl get ns`.
   - Use `puc` only when it exists exactly.
   - If the namespace has a different name, ask the user to choose it from `kubectl get ns`.

3. Find the nmnginx pod.
   - Run `kubectl get pods -n <namespace> | grep '^nmnginx-'`.
   - If exactly one running `nmnginx-*` pod exists, use it.
   - If multiple exist, ask which pod to refresh.

4. Find the locale directory.
   - Run `kubectl describe pod -n <namespace> <pod> | grep -i locale`.
   - Extract the absolute path containing `locale`.
   - If multiple paths are found, ask the user which path to remove.

5. Dry run, then apply.
   - First run the bundled script without `--apply`.
   - If `skipApplyConfirmation: true` is configured for the selected environment, rerun with `--apply --yes` after a successful dry run without asking again.
   - Otherwise, ask the user to confirm the preview before rerunning with `--apply`.
   - When asking, offer two choices: one-time apply, or apply and remember "do not ask again for this environment".
   - Use `--yes` only when the user has already confirmed the exact namespace, pod, and locale path, or when `skipApplyConfirmation: true` is set for that environment.

## Bundled Script

Use `scripts/refresh_puc_language.sh` for the actual operation. It performs namespace/pod discovery, path extraction, safety checks, dry-run output, optional deletion, and pod restart.

Use `scripts/run_refresh_puc_language.py` after shared SSH configuration is selected. It reads shared login fields plus this skill's business config, connects with Paramiko, streams `refresh_puc_language.sh`, and never prints the password.

Default config path:

```text
C:\Users\<user>\Desktop\agentSkillLocalConfig\refresh-puc-language\puc-env.local.json
```

Dry run:

```powershell
python C:\Users\<user>\.codex\skills\refresh-puc-language\scripts\run_refresh_puc_language.py --host 10.161.42.196
```

The `--host` value can be the configured `host`, `name`, or one of `aliases`.
If the value is an unconfigured IP/host, the runner appends it to the local config before validating required fields.

Dry run, then auto-apply only when the environment is trusted:

```powershell
python C:\Users\<user>\.codex\skills\refresh-puc-language\scripts\run_refresh_puc_language.py --host 10.161.42.196 --auto-apply-if-trusted
```

Apply after the dry-run output is confirmed:

```powershell
python C:\Users\<user>\.codex\skills\refresh-puc-language\scripts\run_refresh_puc_language.py --host 10.161.42.196 --apply --yes
```

Apply and remember that this environment should skip this confirmation next time:

```powershell
python C:\Users\<user>\.codex\skills\refresh-puc-language\scripts\run_refresh_puc_language.py --host 10.161.42.196 --apply --yes --remember-apply-confirmation
```

Disable the remembered skip-confirmation preference:

```powershell
python C:\Users\<user>\.codex\skills\refresh-puc-language\scripts\run_refresh_puc_language.py --host 10.161.42.196 --forget-apply-confirmation
```

Compact an existing config entry:

```powershell
python C:\Users\<user>\.codex\skills\refresh-puc-language\scripts\run_refresh_puc_language.py --host 10.161.42.196 --compact-config
```

If Paramiko is missing, install it in the current Python environment:

```powershell
python -m pip install paramiko
```

Local or already inside FinalShell:

```bash
bash scripts/refresh_puc_language.sh --namespace puc
bash scripts/refresh_puc_language.sh --namespace puc --apply
```

From Windows PowerShell through native SSH when key-based or interactive SSH is usable:

```powershell
Get-Content -Raw ".\.codex\skills\refresh-puc-language\scripts\refresh_puc_language.sh" |
  ssh user@10.161.42.196 "bash -s -- --namespace puc"
```

Apply after confirmation:

```powershell
Get-Content -Raw ".\.codex\skills\refresh-puc-language\scripts\refresh_puc_language.sh" |
  ssh user@10.161.42.196 "bash -s -- --namespace puc --apply"
```

If password login only works in FinalShell, paste the script content into the remote shell or upload it temporarily, then run:

```bash
bash refresh_puc_language.sh --namespace <namespace>
bash refresh_puc_language.sh --namespace <namespace> --apply
```

## Handling Missing Inputs

- Missing IP or login method: ask for the target IP and whether SSH from the terminal works, or ask the user to open FinalShell.
- Environment host/IP present but not configured: run with `--host <host>` so shared SSH config adds the host and this skill adds its business entry. Ask the user to edit shared defaults only if login fields remain missing.
- Missing password: use the resolved local config only if the user has chosen local plaintext config; otherwise let SSH/FinalShell prompt for it interactively.
- Missing namespace: run `kubectl get ns` on the host and ask the user to choose.
- Multiple `nmnginx-*` pods: ask the user which pod to delete, or use `--pod <pod-name>` if they provide it.
- Multiple locale paths: ask the user which path to delete, or use `--path <absolute-locale-path>` if they provide it.

## Manual Fallback

When the script cannot be used, execute this sequence on the environment host:

```bash
kubectl get ns
kubectl get pods -n <namespace> | grep '^nmnginx-'
kubectl describe pod -n <namespace> <nmnginx-pod> | grep -i locale
rm -rf -- <locale-path>
kubectl delete pod -n <namespace> <nmnginx-pod>
```

Before running `rm -rf`, restate the selected `<locale-path>` and confirm it is the intended locale directory.

