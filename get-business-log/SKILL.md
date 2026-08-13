---
name: get-business-log
description: Read and collect business logs from a log service environment using an explicit log directory name. Use when the user asks to get or inspect business logs by account and time range, especially with FinalShell, a target environment, a separate log service host, a log service directory under /opt/logserver/log, the business_0 directory, or output to a desktop business-log folder.
---

# Get Business Log

## Core Rules

- Always confirm all required inputs before collecting logs:
  - **Target environment**: the business environment the user cares about. This is for context and reporting; it may differ from the directory name.
  - **Log service environment**: the host to log in to. This host owns `/opt/logserver/log`.
  - **Log service environment directory name**: the directory under `/opt/logserver/log` to query. The actual path is `/opt/logserver/log/<log-dir>/business_0`.
  - **Account**: the account string to search as a literal substring.
  - **Time range**: exact start and end times.
- Do not assume any two of target environment, log service environment, and log service environment directory name are the same.
- Never store usernames, passwords, IPs, or FinalShell credentials inside the skill folder.
- Read SSH login fields from the shared `ssh-config/environments.local.json`; never duplicate credentials in this skill's business config.
- Treat this as a read-only operation. Do not delete, truncate, rotate, or edit remote log files.
- Use `/opt/logserver/log/<log-dir>/business_0` on the log service host as the default remote log directory.
- Put downloaded results under `C:\Users\<user>\Desktop\<log-dir>_业务日志` unless the user explicitly chooses another local output directory.
- Normalize user-provided time ranges to `YYYY-MM-DD HH:mm:ss` when possible. If the user's time is ambiguous, ask once for the exact start and end.
- Redact `password` in all output.

## Shared SSH Config

Before the first connection, use this skill's `scripts/Set-SshConfigRoot.ps1 -Status`. If first use is required, let the user choose the suggested default `Desktop\agentSkillLocalConfig\ssh-config` or an absolute custom root. Persist the choice with `-UseDefault` or `-Path <absolute-path>`; the script immediately creates `environments.local.json` from this skill's bundled template when missing and never overwrites an existing file. Resolve each login as `defaults + environment`, with environment fields taking precedence.

Use `--ssh-config-root <absolute-path>` for a one-command override. Match `--host` by shared SSH `name`, `host`, or `aliases`. When a new concrete host is supplied, the shared config adds only its host so it inherits port, username, password/passwordEnv, and timeout from `defaults`.

Keep `scripts/ssh_config.py`, `scripts/Set-SshConfigRoot.ps1`, and `assets/environments.local.template.json` self-contained in this skill. Do not require a separately installed `ssh-config` skill.

## Business Config

Before connecting, resolve the config path in this order:

1. `--config <path>` argument
2. `BUSINESS_LOG_ENV_CONFIG` environment variable
3. Default path: `C:\Users\<user>\Desktop\agentSkillLocalConfig\get-business-log\business-log-env.local.json`

This optional legacy-compatible business config stores log-service options, not SSH credentials. Minimal shape:

```json
{
  "environments": [
    {
      "name": "log-service-a",
      "host": "log-service-host",
      "baseDir": "/opt/logserver/log",
      "remoteOutputDir": "/tmp/get-business-log"
    }
  ]
}
```

Rules:

- Keep `assets/business-log-env.local.template.json` as the reusable template. Do not put real credentials in the template.
- Optional business fields are `name`, `aliases`, `baseDir`, and `remoteOutputDir`.
- `baseDir` defaults to `/opt/logserver/log`; `remoteOutputDir` defaults to `/tmp/get-business-log`.
- Support password authentication in `scripts/run_get_business_log.py`; use FinalShell/manual SSH for private-key auth or hosts that only work inside FinalShell.
- Match the requested login in shared SSH config; use its resolved host to match this business config.
- If the user supplies an unconfigured log-service host/IP, let shared SSH config append only that host and inherit login fields from `defaults`. Let this business config inherit only `baseDir` and `remoteOutputDir` from an existing business entry.
- If `password` is empty and `passwordEnv` is set, read the password from that environment variable.
- If both `password` and `passwordEnv` are empty, prompt interactively.
- Treat `host`, `username`, and `password` or `passwordEnv` as required in shared SSH config before running remote commands.

## Workflow

1. Confirm the five required inputs.
   - Target environment, for example `10.110.39.28`.
   - Log service environment host/name/alias, passed as `--host`.
   - Log service environment directory name, passed as `--log-dir`.
   - Account string, passed as `--account`.
   - Start and end time, passed as `--start` and `--end`.

2. Use the bundled runner when local SSH with password works.
   - It connects to the log service host, streams `scripts/get_business_log.sh` to that host, downloads the generated tarball, extracts it to the desktop output folder, and removes the temporary remote tarball unless asked to keep it.
   - The remote script scans text logs under `/opt/logserver/log/<log-dir>/business_0`; pass `--include-gz`, `--include-zst`, or `--include-compressed` to scan compressed historical logs.
   - The output contains `matched.log`, `summary.txt`, `manifest.json`, and `scanned_files.txt`.

3. If password login only works through FinalShell.
   - Ask the user to open the log service environment in FinalShell.
   - Provide the `bash get_business_log.sh --log-dir ...` command and either paste/upload the bundled script there.
   - Ask the user to download the printed `ARCHIVE_PATH` tarball to `Desktop\<log-dir>_业务日志`, then extract it.

4. Report the target environment, log service environment, log directory name, final local folder, and matched log file.

## Bundled Script

Use `scripts/run_get_business_log.py` from Windows PowerShell after shared SSH configuration is selected.

Default collection:

```powershell
python C:\Users\<user>\.codex\skills\get-business-log\scripts\run_get_business_log.py --target-env 10.110.39.28 --host 10.110.39.28 --log-dir 10.110.39.198 --account hxy03 --start "2026-07-04 13:45:00" --end "2026-07-04 14:00:00"
```

Here `--target-env` is user-facing context, `--host` is the log service environment, and `--log-dir` is the directory under `/opt/logserver/log`.

Include compressed historical logs:

```powershell
python C:\Users\<user>\.codex\skills\get-business-log\scripts\run_get_business_log.py --target-env 10.110.39.28 --host 10.110.39.28 --log-dir 10.110.39.198 --account hxy03 --start "2026-07-04 13:45:00" --end "2026-07-04 14:00:00" --include-compressed
```

If Paramiko is missing, install it in the current Python environment:

```powershell
python -m pip install paramiko
```

Local or already inside FinalShell on the log service host:

```bash
bash get_business_log.sh --log-dir 10.110.39.198 --account hxy03 --start "2026-07-04 13:45:00" --end "2026-07-04 14:00:00" --include-compressed
```

`--target-ip` and `--log-ip` remain accepted as backward-compatible aliases for `--log-dir`, but prefer `--log-dir`.

## Handling Missing Inputs

- Missing target environment: ask for the business environment the user cares about.
- Missing log service environment: ask which host to log in to for `/opt/logserver/log`.
- Missing log service environment directory name: ask which directory under `/opt/logserver/log` should be queried.
- User supplies only one IP: ask which role it plays before running.
- Log service host/IP present but not configured: run with `--host <log-service-host>` so shared SSH config adds the host and this skill adds its business entry. Ask the user to edit shared `defaults` only when inherited login fields remain missing.
- Missing account: ask for the exact account string.
- Missing or ambiguous time range: ask for exact start and end times.
- No matches: still provide the output folder and summary file; do not broaden the time range unless the user asks.
