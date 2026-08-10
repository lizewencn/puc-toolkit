# Duplicate-login forced logout

Use `scripts/Invoke-PucForceLogin.ps1` to inspect, enable, or disable the platform `FORCE_LOGIN` switch.

## Meaning

- `Enable` sends `Value = "True"`: allow forced login so a duplicate account login automatically logs out the previous session.
- `Disable` sends `Value = "False"`: do not automatically log out the previous session for a duplicate login.
- `Status` only queries the current value.

## Workflow

1. Resolve one exact environment and validate its saved token.
2. Call `/nmpuc/mml/getValidTopoInfo` and require exactly one common topology node whose project-derived type is `pucregcommon`.
3. Derive `neId` from the node and derive `neVersion` from `imageVersion` with dots removed. Never reuse example values or persist topology values in `config.json`.
4. Call `/nmpuc/mml/getMoConfigByType` with the resolved type and version. Find the unique `FunctionSwitchs` MO and its command whose type is `QRY`.
5. Call `/nmpuc/mml/sendMML` with that query command. Require outer `code: 0`, inner `Response.ErrorCode: "0"`, and one record with `Indx = 0` and `Key = "FORCE_LOGIN"`.
6. For `Enable` or `Disable`, show the environment, resolved topology fields, current value, desired value, and exact fixed MML command. Explain the session effect and require explicit confirmation.
7. Run the same arguments with `-Live -ConfirmLive`. If the value already matches, do not send `MOD`. Otherwise send one `MOD` request, never retry it, then run the query once more and require the desired value.

Run a read-only preflight:

```powershell
& <skill>\scripts\Invoke-PucForceLogin.ps1 `
  -Environment <environment> `
  -Action Enable `
  -DryRun
```

After confirmation, apply it:

```powershell
& <skill>\scripts\Invoke-PucForceLogin.ps1 `
  -Environment <environment> `
  -Action Enable `
  -Live `
  -ConfirmLive
```

Use this exact modification shape; only `Value` changes:

```text
MOD FunctionSwitchs : Indx = 0, Value = "True", Key = "FORCE_LOGIN", Description = "IS Allow Forced Login";
```

Stop on topology ambiguity, missing MO metadata, query failure, modification failure, or failed post-write verification. Report sanitized outer and inner result codes and messages. Do not guess `neId`, `neType`, `neVersion`, or a query command.
