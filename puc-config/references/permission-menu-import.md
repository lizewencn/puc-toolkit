# Permission menu import

Use `scripts/Invoke-PucPermissionMenuImport.ps1` to upload one user-specified permission menu JSON file. The request command is `puc_upload_custom_system`.

## Required input

Require the user to provide an attached file or one exact file path. Do not select a file from a directory on the user's behalf. Only `.json` files are accepted.

Resolve the destination explicitly:

- `WebPUC` maps to `file_target: 0` and is the default.
- `APP` maps to `file_target: 1`.
- `WebConfs` maps to `file_target: 2`.

First run the local preflight without network access:

```powershell
& <skill>\scripts\Invoke-PucPermissionMenuImport.ps1 `
  -Environment <environment> `
  -FilePath <path> `
  -Target WebPUC `
  -PlanOnly
```

The preflight requires UTF-8 JSON whose top level is a non-empty array. Every menu node must have a non-empty `key`, a non-empty `name`, and `isCheck` equal to `0` or `1`; `child`, when present, is traversed recursively. Keys must be unique across the complete tree.

Show the resolved environment, file path, destination, byte size, SHA-256, and menu-node count. Explain that importing a permission menu can change visible functions and access control, then require explicit confirmation of that environment, file, and destination.

After confirmation, run:

```powershell
& <skill>\scripts\Invoke-PucPermissionMenuImport.ps1 `
  -Environment <environment> `
  -FilePath <path> `
  -Target WebPUC `
  -ConfirmImport
```

## Protocol behavior

The script validates the saved token, then sends one request to `/confs` with `cmd_name: puc_upload_custom_system`, a new `cmd_guid`, the environment's `puc_id` and `realm`, `version: 0`, the selected `file_target`, and the file's decoded text in `file_content`.

Send the validated original text without reformatting or reserializing it. Never print the file content or token. Never retry the upload request. On an empty, failed, or uncertain response, stop and report only the sanitized result code and message.
