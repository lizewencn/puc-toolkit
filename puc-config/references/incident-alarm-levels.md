# Configure incident alarm levels

Use `scripts/Invoke-PucIncidentAlarmLevels.ps1` to configure the fixed five police incident alarm levels for one exact environment.

## Preview

```powershell
& <skill>\scripts\Invoke-PucIncidentAlarmLevels.ps1 `
  -Environment <environment> `
  -DryRun
```

Show the environment, all five codes and names, classification, color, ZIP leaf name and SHA-256, tone, planned write count, and `PreviewHash`. Require explicit confirmation of that exact summary before live mode.

The script uses a same-name ZIP from `assets/incident` when present and falls back to `普通.zip`. It validates ZIP structure without extracting files and requires exact built-in tone matches.

An `unchanged` item is skipped while missing items continue. Any `conflict` stops the complete batch before writes; never overwrite an existing level.

## Execute

```powershell
& <skill>\scripts\Invoke-PucIncidentAlarmLevels.ps1 `
  -Environment <environment> `
  -Live `
  -ConfirmLive `
  -ExpectedPreviewHash <hash>
```

Live mode repeats the complete preflight and refuses to write if the state, assets, or preview hash changed. It creates missing items in code order. Each create request is sent once. No retry is allowed.

On failure, stop later writes and report created, unchanged, failed, and not-attempted items as a partial result. After successful writes, query once and require all five items to be unchanged. Never retry creation during verification.
