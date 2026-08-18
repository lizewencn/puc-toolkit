# Incident Alarm Level Mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the confirmed `00`-`04` incident-level mapping and require a dedicated same-name ZIP for every level.

**Architecture:** Keep the fixed definitions and asset resolution in `PucIncidentAlarmLevels.psm1`. Change resolution from preferred-plus-fallback to strict same-name lookup, then cover the contract with PowerShell tests and update the operator reference. Include the user-provided `预警.zip` and `指令.zip` as bundled assets.

**Tech Stack:** PowerShell 5.1, Python fake HTTP server, ZIP/SVG assets, Git

---

### Task 1: Lock the mapping and strict asset contract in tests

**Files:**
- Modify: `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`

- [ ] **Step 1: Change the definition expectations to the confirmed order**

Replace the `$expected` rows in `Test-Definitions` with:

```powershell
$expected = @(
    @('00',$normal,'#73cb6d','MediumAlarm.wav'),
    @('01',$star,'#E56659','CriticalAlarm.wav'),
    @('02',$yellow,'#eba54d','MediumAlarm.wav'),
    @('03',$warning,'#73cb6d','CommonlyAlarm.wav'),
    @('04',$instruction,'#73cb6d','CommonlyAlarm.wav')
)
```

- [ ] **Step 2: Require all five same-name ZIPs in the assertions and generated fixtures**

Assert `普通.zip`, `星标.zip`, `黄标.zip`, `预警.zip`, and `指令.zip` in code order. Extend `Initialize-TestIncidentAssets` to generate all five names. Add a temporary-directory assertion that omitting `预警.zip` throws `Incident ZIP does not exist for level '03'` even when `普通.zip` exists.

```powershell
Assert-Equal $resolved[0].ZipFileName ($normal + '.zip') 'Normal ZIP'
Assert-Equal $resolved[1].ZipFileName ($star + '.zip') 'Star ZIP'
Assert-Equal $resolved[2].ZipFileName ($yellow + '.zip') 'Yellow ZIP'
Assert-Equal $resolved[3].ZipFileName ($warning + '.zip') 'Warning ZIP'
Assert-Equal $resolved[4].ZipFileName ($instruction + '.zip') 'Instruction ZIP'
```

- [ ] **Step 3: Run the focused test and verify it fails for the old implementation**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File puc-config/tests/Test-PucIncidentAlarmLevels.ps1 -Case Definitions
```

Expected: failure showing code `00` is still `星标` or that a missing same-name ZIP incorrectly falls back to `普通.zip`.

### Task 2: Implement the confirmed definitions and strict ZIP resolution

**Files:**
- Modify: `puc-config/scripts/PucIncidentAlarmLevels.psm1`

- [ ] **Step 1: Reorder the fixed definitions without changing label semantics**

Return these objects from `Get-PucIncidentAlarmLevelDefinitions`:

```powershell
return @(
    [pscustomobject]@{Code='00';Name=$normal;Description=$normal+$suffix;Color='#73cb6d';Tone='MediumAlarm.wav'},
    [pscustomobject]@{Code='01';Name=$star;Description=$star+$suffix;Color='#E56659';Tone='CriticalAlarm.wav'},
    [pscustomobject]@{Code='02';Name=$yellow;Description=$yellow+$suffix;Color='#eba54d';Tone='MediumAlarm.wav'},
    [pscustomobject]@{Code='03';Name=$warning;Description=$warning+$suffix;Color='#73cb6d';Tone='CommonlyAlarm.wav'},
    [pscustomobject]@{Code='04';Name=$instruction;Description=$instruction+$suffix;Color='#73cb6d';Tone='CommonlyAlarm.wav'}
)
```

- [ ] **Step 2: Remove fallback selection from asset resolution**

Inside `Resolve-PucIncidentAlarmLevelAssets`, resolve only `$item.Name + '.zip'` and throw when that exact file is absent:

```powershell
$selected = Join-Path $resolvedDirectory ($item.Name + '.zip')
if (-not (Test-Path -LiteralPath $selected -PathType Leaf)) {
    throw "Incident ZIP does not exist for level '$($item.Code)'."
}
```

- [ ] **Step 3: Run the focused definition test**

Run the command from Task 1 Step 3.

Expected: `PASS Definitions`.

- [ ] **Step 4: Commit the tested implementation slice**

Stage only the module and test, then commit using the repository's required Chinese commit template fields.

### Task 3: Bundle assets and align operator documentation

**Files:**
- Add: `puc-config/assets/incident/预警.zip`
- Add: `puc-config/assets/incident/指令.zip`
- Modify: `puc-config/references/incident-alarm-levels.md`

- [ ] **Step 1: Update the reference to state strict same-name resolution**

Replace the fallback sentence with:

```markdown
The script requires the same-name ZIP for every level in `assets/incident`: `普通.zip`, `星标.zip`, `黄标.zip`, `预警.zip`, and `指令.zip`. It never substitutes another level's package. It validates ZIP structure without extracting files and requires exact built-in tone matches.
```

- [ ] **Step 2: Validate both new ZIP packages through the production validator**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File puc-config/tests/Test-PucIncidentAlarmLevels.ps1 -Case ZipValidation
```

Expected: `PASS ZipValidation`; the complete suite in Task 4 validates the bundled directory through `Resolve-PucIncidentAlarmLevelAssets` and `Test-PucIncidentZip`.

- [ ] **Step 3: Commit the assets and documentation**

Stage the two named ZIP files and the reference only, then commit using the repository's required Chinese commit template fields.

### Task 4: Verify the complete workflow

**Files:**
- Verify: `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`
- Verify: `puc-config/tests/incident_fake_server.py`

- [ ] **Step 1: Run the module tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File puc-config/tests/Test-PucIncidentAlarmLevels.ps1 -Case Module
```

Expected: `PASS Definitions`, `PASS ZipValidation`, and `PASS Preview`.

- [ ] **Step 2: Run the full incident workflow suite**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File puc-config/tests/Test-PucIncidentAlarmLevels.ps1 -Case All
```

Expected: all six cases pass: `Definitions`, `ZipValidation`, `Preview`, `Command`, `LiveFlow`, and `SkillRouting`.

- [ ] **Step 3: Inspect repository state and history**

```powershell
git status --short
git log -3 --oneline
```

Expected: no uncommitted files from this change; recent history contains the design, implementation, and asset/documentation commits.
