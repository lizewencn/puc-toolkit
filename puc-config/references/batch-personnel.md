# Batch personnel child workflow

Use `scripts/Invoke-PucPersonnel.ps1`. Authentication is shared through the token saved in the selected `config.json` environment.

## Inputs

Resolve these per batch instead of persisting them in `config.json`: exact environment, personnel number type, optional police-type GUID, optional exact root address-book organization name, and either an alias prefix with sequence/count or one exact personnel alias. Use the deployed frontend enum `102` for `人员`, `103` for `车`, and `104` for `应急车`. An exact personnel alias may include one exact dispatcher account to bind during creation.

For each personnel record, capture one Unix timestamp in milliseconds and derive all three credential fields from that same value: use the last 8 digits for `officerId`, the complete timestamp for `idNumber`, and the first 11 digits for `mobile`. Ensure consecutive records cross a 100-millisecond boundary so generated mobile values remain unique. Apply this rule to both exact aliases and prefix batches. The target IP suffix remains part of generated aliases only. Do not require a police-type GUID: the deployed frontend exposes it only as an optional field when number type `102` is selected.

## Execute

1. Validate the saved token with the login workflow. Reauthenticate if rejected.
2. Run authenticated dry run with `-DryRun`.
3. In the graphical launcher, search dispatcher accounts with `account_list_request`, `querykey`, and `is_fuzzy_qry: 1`; display `<alias>(<account>)` and require one selected result. During execution, require exactly one account-list match and use its alias to build `dispatcher_name` as `<alias>(<account>)`. Do not reject the request from an account-list binding field; let the single create response determine whether the server accepts the binding.
4. Show aliases, identifiers, dispatcher account, duplicate skips, organization, and count.
5. Treat the user's explicit instruction containing the exact environment, deterministic alias or generated range, personnel type, and dispatcher account when present as confirmation. After a successful dry run, continue without another confirmation prompt.
6. Run the same arguments with `-Live -ConfirmLive`. Treat `-ConfirmLive` as a script execution guard, not a reason to ask again.

The graphical launcher must list the planned personnel stages in `执行摘要` as numbered nodes. Keep `执行结果` sourced from the final `results` array. Prefix each stage in `详细输出` with the same node number, and emit each PUC interface response as a structured `api-response` record after applying credential-field redaction.

For one exact alias, omit organization fields but include the timestamp-derived officer ID, ID number, and mobile fields in `conf_add_personnel_info_req`. Use `Police:1` only when the user selected the standard police personnel type or an existing confirmed workflow already established it. Never retry a personnel create request, including a binding conflict. Stop on the first failed or uncertain response.
