# First-login password validation

Use `scripts/Invoke-PucFirstLoginPasswordCheck.ps1` to query, enable, or disable the dispatcher requirement to change a password on first login.

## Meaning

- `Status` queries the current policy. `first_login_change_flag = 1` means enabled and `0` means disabled.
- `Enable` sets `first_login_change_flag` to `1`.
- `Disable` sets `first_login_change_flag` to `0`.

Account creation and password-reset workflows automatically run `Status` after their writes. Always tell the user whether the policy is enabled so they can decide whether to run `Enable`; never enable it implicitly.

## Confirmation rule

Treat an explicit user instruction to enable or disable first-login password validation as confirmation for that exact action and environment. Run the authenticated dry run, and when it resolves one exact environment, returns a usable configuration GUID, and reports that a write is required, proceed immediately with `-Live -ConfirmLive` without asking for a second confirmation. If the requested state already matches, report that no write was needed.

Do not infer confirmation from a status question, discussion, recommendation, or account-creation/password-reset policy notice. Stop for user input when the environment is missing or ambiguous. Stop without writing on authentication failure, transport failure, nonzero server result, missing configuration, missing GUID, unsupported non-null flag, or any other unexpected response.

## Workflow

1. Resolve one exact environment and validate its saved token.
2. POST `conf_query_dc_pwd_config_request` to `/confs` with `product_name = "PUC"`, `version = "10"`, and fresh request GUIDs.
3. Require top-level `result = 0`, a non-empty `dispatcher_password_config`, and a non-empty `dispatcher_password_config.guid`. Match the frontend's `first_login_change_flag ?? 0` behavior: interpret a missing or JSON `null` flag as `0` and report `flagDefaulted = true`; require every non-null flag to equal `0` or `1`.
4. For `Status`, return the queried state without writing.
5. For `Enable` or `Disable`, use the `guid` returned by that query in `conf_edit_dc_pwd_config_req`. Never use an example, cached, or fabricated configuration GUID.
6. If the queried flag already matches the requested state, skip the write.
7. Otherwise send exactly one edit request, never retry it, then query once more and require both the requested flag and the same configuration GUID.

Run a read-only authenticated check:

```powershell
scripts\Invoke-PucScript.cmd Invoke-PucFirstLoginPasswordCheck.ps1 `
  -Environment <environment> `
  -Action Status `
  -DryRun
```

Preview an intended change:

```powershell
scripts\Invoke-PucScript.cmd Invoke-PucFirstLoginPasswordCheck.ps1 `
  -Environment <environment> `
  -Action Enable `
  -DryRun
```

After the user's explicit enable/disable instruction and a successful dry run, apply it without another confirmation prompt:

```powershell
scripts\Invoke-PucScript.cmd Invoke-PucFirstLoginPasswordCheck.ps1 `
  -Environment <environment> `
  -Action Enable `
  -Live `
  -ConfirmLive
```

Report the environment, previous state, desired state, whether a write was used, and the verified final state. Stop on transport failure, a nonzero server result, missing configuration, missing GUID, unsupported non-null flag, edit failure, or failed verification.
