# License import and export

Use `scripts/Invoke-PucLicense.ps1` for a standalone License export or import. Authenticate through the saved token for one exact environment.

## Export

Run:

```powershell
& <skill>\scripts\Invoke-PucLicense.ps1 `
  -Action Export `
  -Environment <environment>
```

The script sends `license_download` with the environment realm, requires `result: 0`, and downloads the returned `/frs/licensedownload/` file using the returned Bearer token. It stores the non-empty `.enc` file under `F:\puc-word\agentSkillLocalConfig\puc-config\configExport\<environment>` using the existing unique file-name format. For example, environment `30_93` exports to `configExport\30_93`. When `OutputDirectory` is provided, treat it as the export root and still append the environment directory.

Normal configuration export also performs this License export automatically. Report both output paths, byte sizes, and SHA-256 hashes. Never print the download token or License contents.

## Import

Require the user to provide one exact `.enc` License file or path. Do not choose a file from a directory on the user's behalf. Match the frontend's filename rule: allow only ASCII letters, digits, hyphens, and periods.

First run the local preflight:

```powershell
& <skill>\scripts\Invoke-PucLicense.ps1 `
  -Action Import `
  -Environment <environment> `
  -FilePath <license.enc> `
  -PlanOnly
```

Then run the authenticated preview. It queries `puc_get_license_info_list`, treating result `51800017` as the frontend's normal "License not uploaded" state. When the current type is `Business` or `Temp`, it follows the frontend replacement flow and sends the file to `puc_analyze_license` to identify the incoming type without applying it.

```powershell
& <skill>\scripts\Invoke-PucLicense.ps1 `
  -Action Import `
  -Environment <environment> `
  -FilePath <license.enc> `
  -DryRun
```

Show the environment, exact path, byte size, SHA-256, current type, incoming type when analyzed, whether replacement is required, and preview hash. Explain that importing a License can replace the platform's active authorization, then require explicit confirmation of the environment and file.

After confirmation, use the preview hash:

```powershell
& <skill>\scripts\Invoke-PucLicense.ps1 `
  -Action Import `
  -Environment <environment> `
  -FilePath <license.enc> `
  -Live `
  -ConfirmImport `
  -ExpectedPreviewHash <dry-run-hash>
```

Live mode repeats the status query and analysis, refuses to continue if the file or License state changed, then sends exactly one `multipart/form-data` request to `/confs` with `cmd_name: puc_pull_license_info` and the binary `file`. Never retry the import. On an empty, failed, or uncertain response, stop and report only the sanitized result code and message.
