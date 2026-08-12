---
name: puc-config
description: Configure a named PUC environment through its configuration API, including reusable captcha login, saved-token validation, account creation, account information updates, single or batch dispatcher account password reset or password change, batch personnel creation, configuration and License import/export, permission menu import, and platform function switches. Use when Codex needs to authenticate to a PUC configuration tool; preview or create dispatcher accounts; reset, change, modify, or update one or many accounts' passwords; safely update an existing account's other editable information; preview or create address-book personnel; export or import PUC configuration or License files; upload a permission menu JSON file; configure duplicate-login forced logout; or extend the PUC configuration workflow with another reference module.
---

# PUC Config

Use this skill as the single PUC configuration entry point. Keep workflow-specific instructions in `references/` so new modules can be added without expanding this file.

## Local state

Before the first operation for a Windows user, run `scripts/Set-PucConfigRoot.ps1 -Status`. If it returns `first-use-required`, show the resolved default path `Desktop\agentSkillLocalConfig\puc-config` and ask whether the user wants to keep it or choose another absolute path. Do not run environment initialization, authentication, reads, or writes until the user answers.

- If the user accepts the default, run `scripts/Set-PucConfigRoot.ps1 -UseDefault`.
- If the user supplies another path, run `scripts/Set-PucConfigRoot.ps1 -Path <absolute-path>`.
- If the user's request already explicitly specifies the desired configuration root, treat that as the answer and persist it with `-Path` without asking again.

Store only `configRoot` in `%LOCALAPPDATA%\puc-config\setting.json`. Do not include this runtime file in the Skill package, so installing or updating the Skill cannot overwrite the user's path choice. Resolve configuration roots in this order: an explicit script `-ConfigRoot` temporary override, the non-empty `setting.json` value, then no implicit selection. A missing file or an empty/missing `configRoot` is a first-use condition and must trigger the prompt; do not silently choose the default. When the user accepts the default, write the current user's resolved desktop path into `configRoot`. Changing this value affects future operations only and must never move, copy, delete, merge, or overwrite configuration files from the previous root.

Every workflow script must resolve its configuration directory through `Get-PucConfigRoot`; do not independently construct a desktop path or read `config.json` from a hard-coded location. This makes all authentication, account, personnel, import/export, License, permission, and password-reset operations read from the root selected in `%LOCALAPPDATA%\puc-config\setting.json` unless an explicit one-command `-ConfigRoot` override is supplied.

The suggested default is the current user's `Desktop\agentSkillLocalConfig\puc-config`:

- `config.json`: user-owned environment settings, plaintext administrator and new-account passwords, saved token, and PUC ID. Treat this file as sensitive.
- `runtime.json`: pending same-process login worker metadata only; never store captcha IDs, Cookies, or plaintext captcha values.

Keep only the empty `assets/config.template.json` in the Skill package or source repository. Never copy a user's `config.json`, `runtime.json`, or captcha into the Skill.

Never ask the user to paste a password, token, captcha value, captcha ID, or Cookie into chat. Never print credentials or protected values. Treat config and runtime state as sensitive. Require users to edit plaintext passwords only in their local `config.json`.

After the path selection is saved, if `config.json` is missing at the selected root, run `scripts/Initialize-PucConfig.ps1` with the environment name, base URL, realm, and administrator account. The script creates empty `adminPassword`, `newAccountPassword`, `token`, and `pucId` fields.

## Route the request

- Authentication, captcha, saved-token status, or environment setup: read `references/login.md`.
- Batch dispatcher accounts: read `references/batch-accounts.md` and `references/login.md`.
- Single or batch dispatcher account password reset/change/update: read `references/reset-account-password.md` and `references/login.md`. Route every request whose intended changed value is one or more account passwords here, including requests such as "reset all mhw accounts", even when the user says "update account password" or mentions `update_account`; do not route it to general account information updates.
- Existing dispatcher account updates: read `references/update-account.md` and `references/login.md`.
- Batch address-book personnel: read `references/batch-personnel.md` and `references/login.md`.
- Configuration import or export: read `references/config-import-export.md` and `references/login.md`.
- Standalone License import or export: read `references/license.md` and `references/login.md`.
- Permission menu import: read `references/permission-menu-import.md` and `references/login.md`.
- Duplicate-account login forced logout: read `references/force-login.md` and `references/login.md`.

Read only the selected child reference. A new capability belongs in a new `references/<module>.md` file plus one routing bullet here.

## Safety boundaries

- Use the top-level `result` as the authoritative API outcome for every PUC interface. When `result` is numerically or textually equal to `0`, treat the interface call as successful even when any other returned field is `null`, missing, or empty. Never convert a successful `result == 0` response into an API error merely because a partial data field is empty.
- Normalize successful empty data for the consuming workflow: treat a null list as an empty collection, a null scalar as an empty or unavailable value, and a null object as no returned record. Report outcomes such as "no data", "no match", or "successful response with empty <field>" as appropriate; do not report them as interface exceptions.
- If a later step requires a field that is empty in a successful response, do not fabricate a value or continue unsafely. Stop or skip that dependent step and state that the interface succeeded but the required data was empty. This is a workflow data condition, not an API failure.
- Treat a response as an API failure only when `result` is present and not equal to `0`, the request has a transport/HTTP failure, the response cannot be decoded, or no response document is returned. A missing `result` is an invalid/unknown response contract, not evidence that a null business field caused failure.
- Serialize every JSON request exactly once with `ConvertTo-PucJsonBytes`, which converts non-ASCII values to standard JSON `\uXXXX` escapes and then returns UTF-8 bytes. Send those bytes as `application/json; charset=utf-8`. Never pass a JSON string directly to `Invoke-RestMethod`; Windows PowerShell 5 or a legacy server can otherwise replace or misdecode non-ASCII parameter values.
- Pass every JSON response through `ConvertFrom-PucResponseEncoding` before reading fields or checking duplicates. This safely reverses UTF-8 response bytes that Windows PowerShell 5 decoded as Latin-1 while leaving already-correct Unicode, ASCII, and invalid conversion candidates unchanged.
- Resolve one exact environment before any network call.
- Prefer a saved token. Validate it with an authenticated read before requesting a captcha.
- Display the captcha only in the local interactive login dialog. Never send it through chat, OCR it, infer it, or guess it.
- Treat network failure as environment unavailability, not token rejection.
- On any authentication, lookup, or write error, stop and show the user the sanitized HTTP status, server result code, and server error message when available. Do not automatically retry or fetch another captcha; wait for explicit user direction.
- Run an authenticated dry run or an equivalent in-process preflight before every live batch.
- After the authenticated preflight succeeds, execute the same prepared batch immediately without asking for another confirmation. Report the environment, generated range, item count, authorization summary, duplicate skips, and final per-item results.
- Never retry a create request. Stop immediately when a write response fails or is uncertain.
- Do not modify the PUC frontend project.
