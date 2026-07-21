# Configuration

## Batch file

```json
{
  "startSequence": 1,
  "count": 10,
  "accountPrefix": "lzw",
  "aliasPrefix": "alias",
  "defaultAccountPassword": "<REQUIRED_32_HEX_CIPHERTEXT>",
  "loginUserEnv": "PUC_ADMIN_USER",
  "loginPasswordEnv": "PUC_ADMIN_PASSWORD",
  "highestRoleName": "superadministrator",
  "loginTerminalName": "Dispatch APP",
  "rootOrganizationName": "Dispatch",
  "requestDelayMs": 250,
  "maxReadRetries": 2,
  "maxScanCount": 100
}
```

The manager injects `baseUrl`, `realm`, `ipSuffix`, `allowInsecureTls`, and `reportDirectory` at runtime. Account names use `<accountPrefix><ipSuffix><sequence:000>`. Aliases use `<aliasPrefix><sequence:000>`. Dispatch numbers use Unix timestamps in milliseconds.

`defaultAccountPassword` is the exact ciphertext sent as `dispatcher_pwd`. It is mandatory and must contain exactly 32 hexadecimal characters. Plaintext values and environment-variable overrides are rejected/ignored.

`allowInsecureTls` defaults to false. Set it to true only for a trusted internal server with a self-signed certificate. On Windows PowerShell 5, the script temporarily changes the process certificate callback and restores it on success or failure.

`maxScanCount` bounds how many sequential candidates may be checked while skipping duplicates. If omitted, it defaults to the larger of 100 or ten times `count`.

`maxReadRetries` controls retries for login and read-only lookups. Create-account requests are never retried automatically.

## Adapter file

The HAR converter writes an adapter containing endpoint templates, request bodies, response selectors, and captured header names. Fields containing `REVIEW_REQUIRED` must be resolved before execution.

The batch script requires these operations: `login`, `searchAccounts`, `roles`, `systems`, `accessPoints`, `deviceOrganizations`, `addressBookOrganizations`, and `createAccount`.
