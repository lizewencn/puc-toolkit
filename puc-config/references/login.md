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

Collect the environment name, configuration-tool base URL, realm, administrator account, and whether self-signed TLS is allowed. Do not collect the password through chat.

Run every PowerShell workflow through `Invoke-PucScript.cmd`. It uses process-scoped execution-policy bypass and does not change system policy.

Run:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Initialize-PucConfig.ps1 `
  -Name <environment> `
  -BaseUrl <https://host:port> `
  -Realm <realm> `
  -AdminAccount <account>
```

When another configured environment is a valid template, reuse its common connection conventions and local credentials without asking the user to enter the same values again. Inspect only non-secret fields when selecting the template, then pass its exact environment name with `-TemplateEnvironment <existing-environment>`.

When `-TemplateEnvironment` is used, always set `allowInsecureTls` to `true` for the new environment. Do not inherit or require the template's value.

The template supplies the locally stored `adminPassword` and `newAccountPassword` only. Never copy its `token` or `pucId`; those values are environment-specific. When the target environment already exists, preserve its own password, token, and PUC ID values instead of replacing them from the template.

This writes the minimal `config.json` and preserves existing passwords, token, and PUC ID values when updating an environment. Tell the user to edit `adminPassword` and, when account creation or password reset is needed, `newAccountPassword` locally:

```json
{
  "name": "test-93",
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

Before captcha login, run:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAuth.ps1 -Action Validate -Environment <environment>
```

- `valid: true`: skip captcha and login.
- `reason: missing`: fetch a captcha.
- `reason: rejected`: clear `token` in that environment, report the rejection, and stop. Fetch a new captcha only after explicit user direction.
- Network or TLS exception: preserve the token and report that the environment is unavailable.

## Captcha and login

Keep the full unauthenticated login exchange in one persistent PowerShell worker process. The worker must call `common_cfg_request`, call `puc_get_captcha`, keep the PUC ID, captcha ID, and HTTP session in memory, display a local captcha-entry dialog, then call `login_puc_account` immediately after the user submits. Do not send captcha text through chat or reconstruct the login in another process.

Run the interactive login after token validation reports `reason: missing`. Before fetching the captcha, obtain write permission for the authoritative configuration root and GUI permission for the visible desktop session. Do not log in through a temporary config copy and later synchronize the token.

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAuth.ps1 -Action InteractiveLogin -Environment <environment>
```

The worker displays the captcha in a local topmost window with an input field, a Login button, and a countdown. The server captcha expires 60 seconds after generation; enforce a 55-second client deadline so the login request has time to reach the server. The command remains running while the dialog is open and returns only after login succeeds, the user cancels, the captcha expires, or the server rejects the request.

Keep the captcha value, captcha ID, and HTTP state only in worker memory. On success, let the worker write the returned token and PUC ID into the selected environment in `config.json`, then remove worker metadata and temporary artifacts. Retain `Captcha` and `Login` only for compatibility; do not use their chat-mediated two-step flow for normal operation.

Authentication uses `Invoke-PucJsonRequest` and the bundled Node transport. Do not diagnose PowerShell Schannel by creating a loopback proxy; the transport supports modern TLS without listening on a port. Cookie state remains in the login worker and is passed to the transport only as request headers through stdin.

On a rejected login or request exception, report the sanitized server result code, HTTP status, and error message when available, then stop. Do not automatically start another worker, fetch another captcha, or retry the login. Wait until the user explicitly asks to continue.
