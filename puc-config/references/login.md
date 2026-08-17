# Login child workflow

Use this workflow for environment initialization, password setup, saved-token validation, captcha retrieval, and login.

## Initialize an environment

Before any initialization or authentication command, run:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Set-PucConfigRoot.ps1 -Status
```

The path selection is stored outside the Skill package in `%LOCALAPPDATA%\puc-config\setting.json`, which contains only `configRoot` and survives Skill updates. When the status is `first-use-required`, show the returned `defaultConfigRoot` and ask whether to use it or select another absolute path. Persist the answer with exactly one of:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Set-PucConfigRoot.ps1 -UseDefault
<skill>\scripts\Invoke-PucScript.cmd Set-PucConfigRoot.ps1 -Path <absolute-path>
```

Do not continue until a path is selected. Do not move existing files when the pointer changes. An explicitly supplied `-ConfigRoot` remains a temporary per-command override and does not change the saved pointer.

Collect the configuration-tool base URL, realm, administrator account, and whether self-signed TLS is allowed. Do not collect the password through chat or command-line arguments. The local graphical launcher may collect passwords through its password controls under the launcher rules below. Derive the environment name from the complete lowercase `baseUrl` host; do not ask for or create an abbreviated name.

Run every PowerShell workflow through `Invoke-PucScript.cmd`. It uses process-scoped execution-policy bypass and does not change system policy.

Run:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Initialize-PucConfig.ps1 `
  -BaseUrl <https://host:port> `
  -Realm <realm> `
  -AdminAccount <account>
```

When another configured environment is a valid template, reuse its common connection conventions and local credentials without asking the user to enter the same values again. Inspect only non-secret fields when selecting the template, then pass its complete environment host with `-TemplateEnvironment <existing-environment>`.

Normalize legacy environment names to their complete `baseUrl` hosts before selection. Preserve passwords, tokens, PUC IDs, and all other environment fields. Stop without writing if two entries resolve to the same complete host. An optional explicit `-Name` is accepted only when it exactly equals the derived complete host.

When `-TemplateEnvironment` is used, always set `allowInsecureTls` to `true` for the new environment. Do not inherit or require the template's value.

The template supplies the locally stored `adminPassword` and `newAccountPassword` only. Never copy its `token` or `pucId`; those values are environment-specific. When the target environment already exists, preserve its own password, token, and PUC ID values instead of replacing them from the template.

This writes the minimal `config.json` and preserves existing passwords, token, and PUC ID values when updating an environment. Command-line initialization leaves new password fields empty; the graphical launcher can populate them through local password inputs:

```json
{
  "name": "10.0.0.93",
  "baseUrl": "https://10.0.0.93:16890",
  "realm": "puc.com",
  "adminAccount": "admin",
  "adminPassword": "plaintext login password",
  "newAccountPassword": "plaintext password assigned to created accounts",
  "token": "",
  "pucId": "",
  "allowInsecureTls": true
}
```

Do not echo or copy configured passwords into logs or reports. `config.json` is sensitive and must remain local.

Before sending `login_puc_account`, encrypt the plaintext `adminPassword` exactly like the frontend: DES in CBC mode with PKCS7 padding; use UTF-8 `HytBSoft` as both key and IV; send the lowercase hexadecimal ciphertext as `puc_passwd`. Keep the plaintext only in memory while building the request.

## Reuse a saved token

For normal authenticated work, run:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAuth.ps1 -Action Ensure -Environment <environment>
```

- A valid saved token returns immediately.
- A missing token automatically starts the interactive captcha login.
- Treat `role_request` response `result: 51800032` (`verify-token failed`) as the environment's explicit saved-token rejection signal. Atomically clear both the token and PUC ID, show the complete credential-redacted rejection response preview, and automatically start one interactive captcha login. Do not ask the user whether to continue.
- Treat HTTP 401 or 403 from saved-token validation as compatibility rejection signals and follow the same automatic login transition.
- For every other nonzero `result`, preserve the saved token, show the complete credential-redacted response preview, and stop. Do not reinterpret an unrelated business or service error as token expiry.
- Network or TLS exception: preserve the token and report that the environment is unavailable.

Use `-Action Validate` only when the user explicitly requests token status without login. It remains read-only apart from atomically clearing the token and PUC ID when the server explicitly rejects the token, or clearing a stale PUC ID when no token exists.

## Captcha and login

Keep the full login exchange in one persistent PowerShell worker process. The worker must call `common_cfg_request`, call `puc_get_captcha`, keep the bootstrap PUC ID, captcha ID, and HTTP session in memory, display a local captcha-entry dialog, then call `login_puc_account` immediately after the user submits. After login succeeds, call `common_cfg_request` again with the returned token and the same Cookie session. Treat that authenticated response's `common_info.puc_id` as the effective PUC ID and atomically save it with the token. Never save the pre-login bootstrap PUC ID as the environment's authenticated PUC ID, and stop without saving authentication data when the post-login PUC ID is empty. Do not send captcha text through chat or reconstruct the login in another process.

`Ensure` runs the interactive login automatically after token validation reports `reason: missing` or `reason: rejected`. Before fetching the captcha, obtain write permission for the authoritative configuration root and GUI permission for the visible desktop session. These are host runtime approvals, not business-confirmation prompts. Do not log in through a temporary config copy and later synchronize the token.

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAuth.ps1 -Action InteractiveLogin -Environment <environment>
```

The worker displays the captcha in a local topmost window with an input field, a Login button, and a countdown. The server captcha expires 60 seconds after generation; enforce a 55-second client deadline so the login request has time to reach the server. The command remains running while the dialog is open and returns only after login succeeds, the user cancels, the captcha expires, or the server rejects the request.

Keep the captcha value, captcha ID, and HTTP state only in worker memory. On success, let the worker write the returned token and authenticated effective PUC ID into the selected environment in `config.json`, then remove worker metadata and temporary artifacts. Retain `Captcha` and `Login` only for compatibility; do not use their chat-mediated two-step flow for normal operation.

All PUC workflows use the bundled Node transport. Do not diagnose PowerShell Schannel by creating a loopback proxy or a sandboxed `curl` probe; the transport supports modern TLS without listening on a port. Cookie state remains in the login worker and is passed to the transport only as request headers through stdin.

On a rejected interactive login or request exception, show the complete structured server response with only credential fields redacted when available, then stop. Do not automatically start another worker, fetch another captcha, or retry the login. Wait until the user explicitly asks to continue.
