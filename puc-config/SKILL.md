---
name: puc-config
description: Configure a named PUC environment through its configuration API, including reusable captcha login, saved-token validation, account creation, single or batch account-information completion, account updates, single or batch dispatcher password reset, batch personnel creation, configuration and License import/export, permission menu import, login-policy switches, and the graphical launcher's desktop shortcut. Use when Codex needs to authenticate to PUC; create accounts; complete or normalize one or many existing accounts from the environment's current systems, access points, and root organizations; update editable account information; reset passwords; create personnel; transfer configuration or License files; import permission menus; query or set first-login password validation; configure duplicate-login forced logout; open the PUC configuration GUI; or create or refresh its desktop entry point.
---

# PUC Config

Use this skill as the single PUC configuration entry point. Keep workflow-specific instructions in `references/` so new modules can be added without expanding this file.

## Windows execution

Run bundled PowerShell commands through `scripts\Invoke-PucScript.cmd`; do not invoke a bundled `.ps1` directly from the current PowerShell session. The launcher applies process-scoped `-NoProfile -ExecutionPolicy Bypass` without changing machine or user execution policy.

Use the bundled Node transport for every PUC HTTP operation, including authentication, lookups, live writes, multipart uploads, and downloads. It sends request descriptors through stdin, returns response bytes through stdout, supports modern TLS independently of Windows PowerShell 5 Schannel, and never opens a local proxy port. Workflow scripts must call `Invoke-PucHttpRequest`, `Invoke-PucJsonRequest`, or `Invoke-PucJsonHttpRequest`; never use `Invoke-RestMethod`, `Invoke-WebRequest`, .NET `HttpClient`, `curl`, or a loopback proxy.

Before the first command that contacts a PUC environment, uploads or downloads a file, writes the selected configuration root, or opens the captcha window, obtain the required network, filesystem, and GUI approval. In a managed filesystem/network sandbox, run `Invoke-PucScript.cmd` with `sandbox_permissions: require_escalated` from the first attempt. Local `PlanOnly`, configuration-root status, and syntax/test commands may remain sandboxed when they do not contact a PUC environment or write outside the workspace.

Do not diagnose a sandboxed `SEC_E_NO_CREDENTIALS`, `AcquireCredentialsHandle`, or `The underlying connection was closed` result as PUC service unavailability. Those errors show that a legacy Schannel path or restricted execution context was used. Stop before any write, report the execution-context error, and use the approved Node workflow. Never repeat the same command in the same restricted context.

## Confirmation policy

Separate business confirmation from host runtime approval. Network, filesystem, and GUI approval grants the process access to a protected capability; it does not authorize a PUC business change. Request each required host approval only when needed and do not describe it as confirmation of the business action.

Apply exactly one of these business-confirmation rules:

- Treat an explicit user instruction as confirmation when it resolves to one exact environment and an unambiguous action over exact targets or a deterministic generated range. Run the required preflight and, when it succeeds without changing the requested scope, proceed immediately to live mode without asking again.
- When a query, prefix, filter, or other discovery step determines a target set the user did not enumerate, preview the complete final target list and material changes, then require one explicit confirmation covering that exact manifest. After confirmation, execute it without another prompt.
- For configuration, License, or permission-menu imports that can replace platform state or access control, preview the exact environment, file, destination when applicable, size, and SHA-256, explain the replacement effect, and require one explicit confirmation before upload.
- Do not request business confirmation for read-only status, authentication validation, lookup, preview-only requests, or exports. Obtain only the host approvals required to access the environment or write the requested export.

Treat missing or ambiguous inputs as clarification, not confirmation. A script flag such as `-ConfirmLive` or `-ConfirmImport` is a deterministic execution guard after authorization has already been established; its name does not require another chat prompt. Reconfirm only when a previously confirmed discovered target set, file hash, destination, or material change set differs from the preview. A child workflow may add a stricter confirmation rule only when it names the concrete additional risk and explicitly declares an exception to this policy.

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

Never ask the user to paste a password, token, captcha value, captcha ID, or Cookie into chat. Never print credentials or protected values. Treat config and runtime state as sensitive. The graphical launcher may collect `adminPassword` and `newAccountPassword` through local password controls only when the user chooses not to reuse another environment; its user-controlled `显示密码` option is selected by default. Keep those values in the WinForms process, pass them directly to `Initialize-PucEnvironmentConfig`, atomically write `config.json`, clear launcher references afterward, and never place them in command-line arguments, child-process input/output, temporary files, environment variables, status text, or reports.

After the path selection is saved, if `config.json` is missing at the selected root, use the graphical launcher to collect local passwords or run `scripts/Initialize-PucConfig.ps1` with the base URL, realm, and administrator account. The script derives the environment name from the complete URL host and creates empty password, token, and PUC ID fields; the graphical launcher can initialize the password fields without requiring manual JSON creation.

Use the complete lowercase host from `baseUrl` as every environment's `name` key, for example `10.161.30.163`; never use abbreviated suffix keys such as `30_163`. Derive this key automatically during initialization. Before every environment resolution, display, or selection, atomically update legacy names from each entry's `baseUrl`, preserving every other field. A request that still supplies the old unique name must complete against the newly normalized name in the same call. Stop without writing when an old requested name is ambiguous or multiple entries resolve to the same complete host. Environment selectors must display the complete host so addresses such as `10.161.30.163` and `10.110.30.163` remain distinct.

## Route the request

- Authentication, captcha, saved-token status, or environment setup: read `references/login.md`.
- One-click graphical operation launcher: read `references/launcher.md` and the child references for each supported operation.
- Desktop shortcut creation or refresh: read `references/launcher.md`, obtain filesystem approval, then run the bundled shortcut installer. Do not create a desktop entry silently during skill installation.
- Batch dispatcher accounts: read `references/batch-accounts.md` and `references/login.md`.
- Single or batch dispatcher account password reset/change/update: read `references/reset-account-password.md` and `references/login.md`. Route every request whose intended changed value is one or more account passwords here, including requests such as "reset all mhw accounts", even when the user says "update account password" or mentions `update_account`; do not route it to general account information updates.
- Single or batch existing-account information completion: read `references/complete-account-information.md` and `references/login.md`. Route requests such as "complete all mhw accounts", "补全账号信息", or "补齐这个账号的授权" here. Use its exact-account mode even when only one account is requested.
- Existing dispatcher account updates: read `references/update-account.md` and `references/login.md`.
- Batch address-book personnel: read `references/batch-personnel.md` and `references/login.md`.
- Fixed police incident alarm-level configuration: read `references/incident-alarm-levels.md` and `references/login.md`.
- Configuration import or export: read `references/config-import-export.md` and `references/login.md`.
- Standalone License import or export: read `references/license.md` and `references/login.md`.
- Permission menu import: read `references/permission-menu-import.md` and `references/login.md`.
- Duplicate-account login forced logout: read `references/force-login.md` and `references/login.md`.
- First-login password validation status, enable, or disable: read `references/first-login-password-check.md` and `references/login.md`.

Read only the selected child reference. A new capability belongs in a new `references/<module>.md` file plus one routing bullet here.

## Safety boundaries

- Use the top-level `result` as the authoritative API outcome for every PUC interface. When `result` is numerically or textually equal to `0`, treat the interface call as successful even when any other returned field is `null`, missing, or empty. Never convert a successful `result == 0` response into an API error merely because a partial data field is empty.
- Normalize successful empty data for the consuming workflow: treat a null list as an empty collection, a null scalar as an empty or unavailable value, and a null object as no returned record. Report outcomes such as "no data", "no match", or "successful response with empty <field>" as appropriate; do not report them as interface exceptions.
- If a later step requires a field that is empty in a successful response, do not fabricate a value or continue unsafely. Stop or skip that dependent step and state that the interface succeeded but the required data was empty. This is a workflow data condition, not an API failure.
- Treat a response as an API failure only when `result` is present and not equal to `0`, the request has a transport/HTTP failure, the response cannot be decoded, or no response document is returned. A missing `result` is an invalid/unknown response contract, not evidence that a null business field caused failure.
- When a decoded interface response has top-level `result != 0`, stop the dependent workflow and show the complete structured response as a JSON preview. Preserve every field and nesting level, but replace credential material such as tokens, authorization values, Cookies, passwords, password ciphers, secrets, and captcha data with `[REDACTED]`. State that only credential fields were redacted. Do not reduce the preview to only `result` and `msg`.
- Serialize every JSON request exactly once with `ConvertTo-PucJsonBytes`, which converts non-ASCII values to standard JSON `\uXXXX` escapes and then returns UTF-8 bytes. Send those bytes as `application/json; charset=utf-8`; never send JSON through a legacy PowerShell HTTP cmdlet.
- Use `Invoke-PucHttpRequest`, `Invoke-PucJsonRequest`, or `Invoke-PucJsonHttpRequest` for every HTTP call. They resolve Node from `PUC_NODE_EXE`, `PATH`, or the bundled Codex runtime, pass credentials only through stdin, and handle TLS 1.2/1.3 without a listening port.
- Use `Write-PucJson` for configuration updates. It validates a temporary JSON file and atomically replaces the destination; never write `config.json` with `Set-Content` directly.
- Pass every JSON response through `ConvertFrom-PucResponseEncoding` before reading fields or checking duplicates. This safely reverses UTF-8 response bytes that Windows PowerShell 5 decoded as Latin-1 while leaving already-correct Unicode, ASCII, and invalid conversion candidates unchanged.
- Resolve one exact environment before any network call.
- Prefer a saved token. Use the authentication workflow's `Ensure` action for normal operations. For `role_request`, treat `result == 51800032` (`verify-token failed`) as the environment's explicit token-rejection signal; retain HTTP 401/403 only as compatibility rejection signals. When one of those signals occurs, or no token exists, automatically start the interactive login flow without another business-confirmation prompt. Preserve the token and stop with the full credential-redacted response preview for every other nonzero `result`.
- Display the captcha only in the local interactive login dialog. Never send it through chat, OCR it, infer it, or guess it.
- Before fetching a captcha, require write access to the selected configuration root and a visible desktop session. Obtain filesystem/GUI approval before starting login so a successful token can be saved directly to the authoritative config.
- Treat network failure as environment unavailability, not token rejection.
- Treat an explicit saved-token rejection as a recoverable authentication transition, not a retryable business error: atomically clear both the token and PUC ID, then start exactly one interactive login flow automatically. If no token exists, clear any stale PUC ID before continuing. On a rejected interactive login, transport failure, lookup failure, write failure, or any other error, stop and show the full credential-redacted response preview when available. Do not automatically retry the failed login or business request.
- Run an authenticated dry run or an equivalent in-process preflight before every live batch, except when a child workflow explicitly defines a single atomic lookup-and-live command.
- After preflight, apply the confirmation policy above. Execute an already authorized exact request immediately; pause once for a discovered target set or replacement import. Report the environment, generated range or target set, item count, authorization summary, duplicate skips, and final per-item results.
- Never retry a create request. Stop immediately when a write response fails or is uncertain.
- Do not modify the PUC frontend project.
