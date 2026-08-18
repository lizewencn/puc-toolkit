# Configure incident alarm levels

Use `scripts/Invoke-PucIncidentAlarmLevels.ps1` to configure the fixed five police incident alarm levels for one exact environment.

## Preview

```powershell
& <skill>\scripts\Invoke-PucIncidentAlarmLevels.ps1 `
  -Environment <environment> `
  -DryRun
```

Show the environment, all five codes and names, classification, color, ZIP leaf name and SHA-256, tone, planned write count, and `PreviewHash`. Treat the user's explicit instruction to configure the fixed five levels in that exact environment as confirmation. After a successful preview, continue to live mode without asking again.

The script requires the same-name ZIP for every level in `assets/incident`: `普通.zip`, `星标.zip`, `黄标.zip`, `预警.zip`, and `指令.zip`. It never substitutes another level's package. It validates ZIP structure without extracting files and requires exact built-in tone matches.

An item conflicts when an existing record has the same level code or the same level name. This includes an exact code-and-name match, regardless of its other values. Report it as `conflict-skipped`, never overwrite it, and continue creating later missing items.

## Execute

```powershell
& <skill>\scripts\Invoke-PucIncidentAlarmLevels.ps1 `
  -Environment <environment> `
  -Live `
  -ConfirmLive `
  -ExpectedPreviewHash <hash>
```

Live mode repeats the complete preflight and refuses to write if the state, assets, or preview hash changed. It creates missing items in code order. Each create request is sent once. No retry is allowed.

If a create response authoritatively reports that the level code or name already exists, report that item as `conflict-skipped` and continue with later missing items. On any other failed or uncertain response, stop later writes and report `created`, `conflict-skipped`, `failed`, and `not-attempted` items as a partial result. Query once after writes and verify only items created by this run. No retry is allowed during creation or verification.
