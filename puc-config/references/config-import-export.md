# Configuration import and export

Use `scripts/Invoke-PucConfigTransfer.ps1`. Authenticate through the saved token for one exact environment.

## Export

Run:

```powershell
& <skill>\scripts\Invoke-PucConfigTransfer.ps1 `
  -Action Export `
  -Environment <environment>
```

The script sends `export_request`, polls `export_progress` every five seconds, and downloads the completed file with the returned Bearer token. It then sends `license_download` and downloads the returned License with its separate Bearer token. It stores both the configuration JSON and License `.enc` under `F:\puc-word\agentSkillLocalConfig\puc-config\configExport\<environment>`. Sanitize only the directory component when necessary; keep the existing generated file-name formats unchanged so prior exports are not overwritten. For example, environment `30_93` exports to `configExport\30_93`.

Treat exported files as sensitive. Report the environment, task ID, both final paths, file sizes, and SHA-256 hashes. Never print either download token or file contents. If the configuration succeeds but License export fails, report the preserved configuration path and the sanitized License failure; do not claim the combined export succeeded.

## Import

Require the user to specify one exact `.json` or `.txt` configuration file or path. Do not choose a file from a directory on the user's behalf.

First run the local preflight without network access:

```powershell
& <skill>\scripts\Invoke-PucConfigTransfer.ps1 `
  -Action Import `
  -Environment <environment> `
  -FilePath <path> `
  -PlanOnly
```

Show the resolved environment, file path, byte size, and SHA-256. Explain that configuration import can replace platform configuration, then require explicit confirmation of that environment and file.

After confirmation, run:

```powershell
& <skill>\scripts\Invoke-PucConfigTransfer.ps1 `
  -Action Import `
  -Environment <environment> `
  -FilePath <path> `
  -ConfirmImport
```

The script Base64-encodes the raw file bytes, sends `import_request` once, and polls `import_progress` every five seconds. Never retry `import_request`. On an empty, failed, or uncertain response, stop and report the sanitized code and message.

## Protocol defaults

Use `product_name: PUC` and `version: 10` unless the target environment requires explicit alternatives; override them with `-ProductName` and `-Version`. Poll for at most 30 minutes by default.
