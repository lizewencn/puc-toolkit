# Reset dispatcher account password

Use `scripts/Invoke-PucAccountPasswordReset.ps1` for every request to reset, change, modify, or update one dispatcher account password. For more than one account, use `scripts/Invoke-PucAccountPasswordResetBatch.ps1`; do not run a hand-written loop of live reset commands. This routing takes priority over the general account-information update workflow.

In the graphical launcher's single-account form, resolve the dispatcher through the shared asynchronous server-side fuzzy-search dropdown backed by `account_list_request`. Require one selected returned account and reject free-form text before starting the authenticated preview; the reset workflow still re-queries and validates that exact account.

## Verified protocol

Match the PUC frontend reset-password behavior:

1. Query `account_list_request` and require exactly one case-insensitive exact `dispatcher_account` match. Match the verified frontend request shape: send `user_id`, `realm`, paging, `querykey`, `lock_query`, and `filter`, but do not add `puc_id`; on some PUC versions, adding `puc_id` changes the account scope and can return an empty list even when the token-authorized account query has matches.
   Treat a null `account_list` as empty and ignore null or malformed list entries that do not contain a dispatcher account; never fail by dereferencing an absent response row.
2. Start the `update_account` payload from that fresh complete account record so all returned account parameters remain unchanged.
3. Set `cmd_name` to `update_account`.
4. Build one payload from the fresh record, preserve all other fields, set `is_change_pwd` to `1`, and normalize `imei_list` exactly as the frontend does because the API requires an array.
5. Send the first `update_account` with `dispatcher_pwd` set to an encrypted current Unix timestamp in milliseconds.
6. Only after the first response returns `result: 0`, send the second `update_account` with only `dispatcher_pwd` replaced by the encrypted selected environment `newAccountPassword`.
7. Preserve the record's `puc_id`; only fall back to the selected environment's PUC ID when the record has none.

`ConvertTo-PucDesHex` is the same algorithm used for PUC login: DES-CBC, PKCS7 padding, UTF-8 `HytBSoft` as both key and IV, and lowercase hexadecimal ciphertext.

## Secret handling

Never accept or request a reset password in chat, a dialog, command-line arguments, JSON changes, environment variables, or reports. Require a non-empty `newAccountPassword` in the selected environment's sensitive local `config.json`. Keep the generated timestamp and both plaintext/ciphertext values only in process memory and never print them.

Treat the two writes as two required stages, not retries. Never retry either write. If stage 1 fails or is uncertain, stop without stage 2. If stage 1 succeeds and stage 2 fails or is uncertain, stop and report partial success: the account may currently use the generated timestamp password. Do not print that timestamp password.

## Execute

Run an authenticated preview first:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAccountPasswordReset.ps1 `
  -Environment <environment> `
  -Account <dispatcher-account> `
  -DryRun
```

Show the exact environment, account, and returned snapshot hash without password material. Treat the user's explicit instruction naming that exact environment and account as confirmation. Run live mode with that hash without asking again:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAccountPasswordReset.ps1 `
  -Environment <environment> `
  -Account <dispatcher-account> `
  -Live `
  -ConfirmLive `
  -ExpectedSnapshotHash <dry-run-hash>
```

Live mode re-queries the account before writing and refuses to write when the fresh record no longer matches the preview snapshot. It then sends the timestamp-password stage followed by the `newAccountPassword` stage, with no post-write account refresh. Success requires `result: 0` from both requests.

After a successful single reset, query the login policy and report whether "dispatcher first-login password validation" is enabled. If disabled, tell the user they can run the first-login password validation setting workflow; do not enable it automatically. A policy-query failure does not change the successful reset result; report the policy state as unknown.

## Batch reset protocol

A batch reset is a set of independent per-account workflows:

- Discover every matching account across all account-list pages and preview every target before authorization.
- For query-based discovery, send `is_fuzzy_qry: 1` and `online_query: 0` so account prefixes and substrings use the same server-side fuzzy semantics as the launcher search. Continue omitting `puc_id` to preserve the verified password-reset account scope across PUC versions.
- When a successful query returns no matching accounts, emit a successful structured `no-match` result with account count `0` and the Chinese message `未查询到匹配的调度账号，请调整查询关键字后重试。`. In the launcher, mark the preview node completed, mark the reset node skipped, show `查询结果为空`, and do not request confirmation or start live mode.
- Show the complete target list and snapshot hash for each account. For `-Query`, require one explicit confirmation covering only that displayed batch because the query discovers accounts the user did not enumerate. For `-AccountsPath`, treat the user's explicit enumeration of the exact environment and account set as confirmation and do not ask again after preview.
- After authorization, launch every account workflow concurrently. Do not make one account wait for another account to finish.
- Within each account workflow, preserve the strict order: timestamp-password update first, then the `newAccountPassword` update only after that account's first call returns `result == 0`.
- A failure for one account must not cancel or delay the other account workflows.
- Do not automatically retry either write stage.
- Report every account separately, including whether it failed before writing, at stage 1, or after stage 1 while restoring `newAccountPassword`.
- After all account workers finish, query the login policy exactly once for the batch and include `firstLoginPasswordValidation` in the final result. Do not query once per account.
- If an account snapshot changed after preview, perform no write for that account. Re-preview it. Reconfirm only when the discovered target set or material reset scope differs from what was authorized; do not reconfirm an unchanged exact-account request. Never run an already successful account again while recovering a partial batch.

This produces concurrency across accounts and a serial dependency only inside each account:

```text
account A: update(timestamp) -> update(newAccountPassword)
account B: update(timestamp) -> update(newAccountPassword)
account C: update(timestamp) -> update(newAccountPassword)
```

Preview all accounts matching a dispatcher-account query and save the snapshot manifest:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAccountPasswordResetBatch.ps1 `
  -Environment <environment> `
  -Query <account-query> `
  -DryRun `
  -ManifestPath <temporary-manifest.json>
```

When the user supplies an explicit account set, write a temporary UTF-8 JSON array containing exactly those account strings and use `-AccountsPath` instead of `-Query`:

```json
["mhw19001", "mhw19002"]
```

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAccountPasswordResetBatch.ps1 `
  -Environment <environment> `
  -AccountsPath <accounts.json> `
  -DryRun `
  -ManifestPath <temporary-manifest.json>
```

The script rejects non-string values, invalid account characters, empty lists, and case-insensitive duplicates. It performs an exact case-insensitive lookup for every requested account and refuses the complete preview if any account is missing or ambiguous. Never create a broad query manifest and edit it by hand.

After showing the complete manifest, execute immediately for an explicitly enumerated account set. For a query-discovered target set, execute after receiving its one explicit confirmation:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAccountPasswordResetBatch.ps1 `
  -Environment <environment> `
  -Live `
  -ConfirmLive `
  -ManifestPath <temporary-manifest.json>
```

The manifest contains only account identifiers and snapshot hashes, never passwords. Delete both the account-list file and manifest after the batch completes. Password-reset requests use the bundled Node transport directly; do not start a local proxy or select a local port.
