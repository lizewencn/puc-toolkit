# Batch accounts child workflow

Use `scripts/Invoke-PucAccounts.ps1`. Authentication is shared through the token saved in the selected `config.json` environment.

## Inputs

Resolve these per batch instead of persisting them in `config.json`: exact environment, account prefix, start sequence, optional count, optional dispatch-number start, optional exact role name, and optional exact root organization name. When the user does not specify a count, use `1`; do not ask for confirmation of that default.

Account naming is `<prefix><environment-suffix><NNN>`. Derive `environment-suffix` from the last IPv4 octet of the selected environment's `baseUrl`; do not derive it from the local environment name. Keep the octet in its natural decimal form without zero-padding. For example, prefix `mhw`, environment host `10.161.30.163`, and sequence `1` produce account `mhw163001` and alias `mhw163001_alias`. A supplied dispatch-number start increments by one; otherwise use a monotonic millisecond value.

Before generating candidates, call `account_list_request` once with `<prefix><environment-suffix>` as `querykey` and fixed `page_sizes: 30`. Use that response to build in-memory sets of existing account names and dispatch numbers. Generate the complete batch and all `add_account` request parameters before sending the first write. Do not query once per candidate account or dispatch number.

If the prefix lookup reports more than 30 existing accounts, more than one page, or the existing count plus the requested batch would exceed 30, stop before generating or creating accounts. Ask whether the user wants to continue creating accounts or update existing account information instead. After the user explicitly chooses creation, rerun with `-ContinueWhenMoreThan30Accounts` and collect the remaining pages using increasing `page_index` values bounded by the returned `page_count`; this explicitly approved large-result path is the only case where the prefix lookup uses multiple requests.

Treat the target-environment response as the only source of truth. Compare each generated full account name and dispatch number against the in-memory sets and reserve generated values within the batch. Do not use local history or reports for duplicate detection.

The default account password comes from the selected environment's plaintext `newAccountPassword` in `config.json`. Encrypt it in memory using the same DES-CBC/PKCS7, UTF-8 `HytBSoft` key/IV, lowercase-hex rule as login before sending `add_account`. Select roles by exact alias priority: `superadministrator`, then `administrator`, then `operations`; only when none exist, select the unique role with the highest enabled-permission count. An explicitly supplied role name must match exactly once and must never fall back. Select all returned valid systems and access points. Use the unique root device and address-book organizations unless an exact name is supplied.

## Execute

1. Run the login workflow's `Ensure` action. It validates a saved token and automatically starts one interactive login when the token is missing or explicitly rejected.
2. For an actual creation request, run one live command. It performs the authenticated prefix lookup, prepares the complete batch in memory, and only then sends `add_account` requests:

   Obtain network and configuration-root approval before this command and run the launcher outside a restricted sandbox from the first attempt. Do not run a sandboxed Schannel probe first.

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAccounts.ps1 `
  -Environment <environment> `
  -Prefix <prefix> `
  -StartSequence <start> `
  -Count <count, default 1> `
  -Live `
  -ConfirmLive
```

If it stops with `ACCOUNT_LOOKUP_DECISION_REQUIRED`, show the returned count and ask the user to choose between continuing account creation and updating existing account information. Continue creation only after an explicit choice, then rerun the live command with `-ContinueWhenMoreThan30Accounts`.

3. Use `-DryRun` only when the user explicitly asks for a preview without creation. A later live command performs a fresh single lookup because dry-run state is not persisted.
4. After the live creation batch finishes, query the login policy once. Report whether "dispatcher first-login password validation" is enabled. If disabled, tell the user they can run the first-login password validation setting workflow; do not enable it automatically. If the query fails, preserve the creation result and report that policy status is unknown.
5. Return prepared and created accounts, generated range, duplicates, selected role, authorization lookups, final per-item results, and `firstLoginPasswordValidation` directly to the user. Do not persist dry-run or live reports.

Omit `-Count` when the user did not provide it; the script defaults it to `1`. The resulting single-account request is already authorized by the user's creation instruction and must not trigger another confirmation prompt.

Do not retry `add_account`. Stop on the first failed or uncertain response.
