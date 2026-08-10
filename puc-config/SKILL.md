---
name: puc-config
description: Configure a named PUC environment through its configuration API, including reusable captcha login, saved-token validation, account creation and updates, batch personnel creation, configuration and License import/export, permission menu import, and platform function switches. Use when Codex needs to authenticate to a PUC configuration tool, preview or create dispatcher accounts, safely update an existing account's editable information, preview or create address-book personnel, export or import PUC configuration or License files, upload a user-specified permission menu JSON file, configure duplicate-login forced logout, or extend the PUC configuration workflow with another reference module.
---

# PUC Config

Use this skill as the single PUC configuration entry point. Keep workflow-specific instructions in `references/` so new modules can be added without expanding this file.

## Local state

Use `Desktop\agentSkillLocalConfig\puc-config` by default:

- `config.json`: user-owned environment settings, plaintext administrator and new-account passwords, saved token, and PUC ID. Treat this file as sensitive.
- `runtime.json`: pending same-process login worker metadata only; never store captcha IDs, Cookies, or plaintext captcha values.

Keep only the empty `assets/config.template.json` in the Skill package or source repository. Never copy a user's `config.json`, `runtime.json`, or captcha into the Skill.

Never ask the user to paste a password, token, captcha value, captcha ID, or Cookie into chat. Never print credentials or protected values. Treat config and runtime state as sensitive. Require users to edit plaintext passwords only in their local `config.json`.

If `config.json` is missing, run `scripts/Initialize-PucConfig.ps1` with the environment name, base URL, realm, and administrator account. The script creates empty `adminPassword`, `newAccountPassword`, `token`, and `pucId` fields.

## Route the request

- Authentication, captcha, saved-token status, or environment setup: read `references/login.md`.
- Batch dispatcher accounts: read `references/batch-accounts.md` and `references/login.md`.
- Existing dispatcher account updates: read `references/update-account.md` and `references/login.md`.
- Batch address-book personnel: read `references/batch-personnel.md` and `references/login.md`.
- Configuration import or export: read `references/config-import-export.md` and `references/login.md`.
- Standalone License import or export: read `references/license.md` and `references/login.md`.
- Permission menu import: read `references/permission-menu-import.md` and `references/login.md`.
- Duplicate-account login forced logout: read `references/force-login.md` and `references/login.md`.

Read only the selected child reference. A new capability belongs in a new `references/<module>.md` file plus one routing bullet here.

## Safety boundaries

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
