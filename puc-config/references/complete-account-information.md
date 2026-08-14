# Complete account information

Use `scripts/Invoke-PucAccountCompletion.ps1` to complete one existing dispatcher account or every existing account whose name starts with a prefix. This workflow does not change passwords.

## Completion baseline

Build one environment-wide baseline from authenticated reads before previewing any account:

- all usable IDs from `system_list_request`;
- all access-point entries from `sap_list_request`, serialized in the frontend `dispatch_sap_list` format;
- the unique root from `short_organization_list_request` for owned and authorized device organization fields;
- the unique root from `personnel_organization_list_req` for owned and authorized address-book organization fields.

Stop when systems are empty, either organization root is not unique, or a required root ID/name is empty. Do not fabricate email, avatar, IMEI, device serial number, device group, or other optional binding data. Leave `system_id` empty because the account creation template does so.

Complete these fields when they differ from the baseline: `org_identifier`, `org_alias`, `org_identifier_list`, `custom_org_identifier_list`, `custom_org_id`, `system_id_list`, and `dispatch_sap_list`. Fill an empty `dispatcher_name` as `<account>_alias`. Change a non-empty display name only when the user explicitly requests generated-alias normalization and `-NormalizeGeneratedAlias` is supplied.

## Targets

Use exactly one target in preview mode:

- `-Account <exact-account>` for one account. Require exactly one case-insensitive exact match.
- `-Query <prefix>` for one or many accounts. Include only names that start with the prefix, case-insensitively, across all pages.

The same workflow handles a one-item batch. Do not fall back to a hand-written loop or temporary audit script.

## Preview and authorization

Preview one account:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAccountCompletion.ps1 `
  -Environment <environment> `
  -Account <account> `
  -DryRun `
  -ManifestPath <temporary-manifest.json>
```

Preview a prefix batch:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAccountCompletion.ps1 `
  -Environment <environment> `
  -Query <account-prefix> `
  -DryRun `
  -ManifestPath <temporary-manifest.json>
```

Use `-NormalizeGeneratedAlias` only after the user requests display names in `<account>_alias` form. The preview performs the authenticated baseline reads once, discovers all targets, invokes the verified single-account update preview for every incomplete account, and atomically writes a manifest containing changes and snapshot hashes but no password cipher or token.

Show the exact environment, target mode, complete account list, baseline summary, per-account field changes, and snapshot hashes. Do not expose full access-point GUID payloads in chat; summarize their count.

- For `-Account`, treat the user's explicit instruction naming that exact environment and account as confirmation. Continue to live execution after a successful preview without asking again.
- For `-Query`, the prefix discovers a target set the user did not enumerate. Require one explicit confirmation covering exactly the displayed manifest.

## Live execution

After authorization under the rule above, execute:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucAccountCompletion.ps1 `
  -Environment <environment> `
  -Live `
  -ConfirmLive `
  -ManifestPath <temporary-manifest.json>
```

Process accounts sequentially in manifest order. For each incomplete account, delegate to `Invoke-PucAccountUpdate.ps1`, which re-queries the account, verifies its preview snapshot, preserves the password cipher with `is_change_pwd: 0`, writes once, and refreshes the exact account. Do not retry. Stop on the first failed or uncertain write and report completed accounts plus the failed account; never rerun already successful accounts during recovery.

Delete the manifest after a successful batch. On failure, retain it only long enough to report and diagnose; re-preview changed or failed accounts before any later write.
