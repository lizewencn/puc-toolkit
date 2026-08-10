# Update account information

Use `scripts/Invoke-PucAccountUpdate.ps1`. This workflow follows the account edit behavior in the PUC frontend, not the password-reset behavior.

## Inputs and modes

Resolve one exact environment and dispatcher account. Require changes as either a JSON object in `-ChangesJson` or a `.json` file in `-ChangesPath`; use exactly one source.

Run an offline validation first:

```powershell
& <skill>\scripts\Invoke-PucAccountUpdate.ps1 `
  -Environment <environment> `
  -Account <dispatcher-account> `
  -ChangesPath <changes.json> `
  -PlanOnly
```

Then run the authenticated preview. It queries `account_list_request`, requires exactly one exact account match, rejects accounts the frontend marks non-editable, builds the same fixed `update_account` field set as the frontend, and returns a snapshot hash without exposing the stored password cipher.

```powershell
& <skill>\scripts\Invoke-PucAccountUpdate.ps1 `
  -Environment <environment> `
  -Account <dispatcher-account> `
  -ChangesPath <changes.json> `
  -DryRun
```

Show the environment, exact account, requested field changes, and snapshot hash. Require explicit confirmation of those values. Then run the live update with the returned hash:

```powershell
& <skill>\scripts\Invoke-PucAccountUpdate.ps1 `
  -Environment <environment> `
  -Account <dispatcher-account> `
  -ChangesPath <changes.json> `
  -Live `
  -ConfirmLive `
  -ExpectedSnapshotHash <dry-run-hash>
```

The live mode re-queries the account and refuses to write if its editable snapshot changed after preview.

## Editable fields

Allow only fields used by the frontend account edit form: `dispatcher_no`, `dispatcher_name`, `org_identifier`, `org_alias`, `system_id`, `role`, `role_guid`, `org_identifier_list`, `custom_org_identifier_list`, `custom_org_id`, `dispatch_sap_list`, `imei_list`, `device_sn`, `device_group_list`, `system_id_list`, `sort_id`, `dispatcher_priority`, `device_type`, `dispatcher_type`, `avatar_url`, `avatar_md5sum`, and `is_del_avatar`.

Require `role` and `role_guid` together. Require `org_identifier` and `org_alias` together. Normalize `imei_list` to a string array. Serialize an object supplied as `dispatch_sap_list` because the API expects JSON text in that field.

The frontend saves `mfa_switch` and `email` with a separate `mfa_dispatcher_info_config_update` request. Accept those two change fields and send that request only when either is explicitly requested. Report partial success if `update_account` succeeds and the MFA request fails; never retry either write.

Reject identity, password, and server-state fields, including `dispatcher_account`, `guid`, `puc_id`, `realm`, `dispatcher_pwd`, `is_change_pwd`, timestamps, version fields, online/lock/account/approval state, `judge_sync_edit`, and `disabled`. Password reset is a distinct frontend workflow and does not belong in this child skill.

## Protocol consistency

Query with `account_list_request`, the current administrator as `user_id`, page size 30, `lock_query: 0`, and the same role/state filter defaults as the frontend. Paginate safely and select only an exact `dispatcher_account` match.

For `update_account`, preserve the fresh record's password cipher and send `is_change_pwd: 0`. Preserve the record's `puc_id` when present because the frontend supports an upper-level PUC editing a lower-level account. Treat top-level `result: 0` as success, refresh the exact account afterward, and never print the token, stored password cipher, or full server record.
