---
name: puc-app-business
description: Use when an agent needs to log in to a PUC APP server and create chat groups in batches with automatically selected same-prefix dispatcher members. Do not use for PUC configuration API operations, account administration, personnel, licenses, or permission menus.
---

# PUC APP Business

Use the independent APP login and group-batch Python packages in this repository. The workflow shares only the configuration root selected by `puc-config`; it does not use `puc-config/config.json`, configuration APIs, credentials, tokens, or workflow scripts. The graphical launcher's APP Business tab is a backup interface over the same packages, not the primary agent workflow.

## Local profiles

Read `%LOCALAPPDATA%\puc-config\setting.json` to locate the selected `configRoot`, then use `<configRoot>\app-business.json`. This separate file stores APP environment URLs, account names, and plaintext passwords for reuse. Treat it as sensitive. Never add token, access token, Authorization, Cookie, or runtime session data; tokens exist only in the current Python process and are discarded when it exits.

For the first use of an environment, include `--environment`, `--server`, `--account`, and `--save-profile`; the command securely prompts for the password and saves the profile. The backup GUI saves the same profile when login is submitted. For later runs, use `--environment` and `--account`; omit `--server` and password input to reuse the saved values.

## Batch groups

Collect the APP server URL, login account, group count, and total member count. Treat an explicit request containing those exact values as authorization for the batch; otherwise obtain confirmation immediately before execution.

Member selection is deterministic:

- Total member count includes the login account, defaults to `3`, and must be at least `3`.
- Remove all trailing digits from the login account to derive the prefix (`lzw93001` becomes `lzw`).
- Use the APP login token with `Authorization: Bearer <token>` to POST `page_piece_account_list_request` to the APP server's HTTPS `/has` endpoint. `Basic <raw token>` is invalid because Basic authentication requires encoded credentials.
- Keep only accounts whose own trailing-digit-stripped prefix matches, exclude the login account, and select `member_count - 1` entries in API order.
- Add the login account as group owner. If eligible accounts are insufficient, stop before sending any group-create request.
- POST group creation and subject updates to the APP server's HTTPS `/has` endpoint and use the JSON HTTP Response as the command ACK. Do not send these business requests as WebSocket frames; WebSocket is retained for login, heartbeat, and server events.

From the repository root, run:

```powershell
$env:PYTHONPATH=(Resolve-Path 'app_puc_group_batch').Path + ';' + (Resolve-Path 'app_puc_login').Path
python -m app_puc_group_batch --environment <name> --account <account> --server <https://host:16663> --save-profile --password-dialog --group-count <count> --member-count <count>
```

For agent-driven first use or password replacement, prefer `--password-dialog`, which opens a local masked input dialog and subsequently reuses the saved plaintext value. If the user has already placed it in a process-scoped environment variable, pass its name with `--password-env`; never request or expose the password in chat, command arguments, logs, or reports. TLS certificate validation is disabled by default for APP business environments; use `--verify-tls` only when strict certificate validation is explicitly required.

The command emits JSON Lines progress and one final summary or error. Never retry a create request automatically. Report the selected server and account, requested counts, successful groups, failures, and whether execution stopped before creation. Do not print tokens or Authorization values.

If the agent process cannot reach the APP server address because of local network or endpoint-security restrictions, stop before creation and report the connectivity failure. Use the PUC Toolkit's APP Business GUI as the fallback entry point; it uses the same profiles and Python business implementation. Do not treat an agent-only socket denial as an APP protocol failure.
