# Incident Alarm Level Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe, preview-confirmed workflow that configures five fixed incident alarm levels with bundled ZIP assets and inferred built-in tones.

**Architecture:** Isolate fixed definitions, ZIP validation, classification, and preview hashing in a testable module. Keep authentication, paginated JSON reads, multipart writes, stop-on-first-failure behavior, and verification in one command script with a test-only endpoint override. Route the feature through one reference document and synchronize the installed skill only after repository tests pass.

**Tech Stack:** Windows PowerShell 5.1, `System.IO.Compression`, .NET `HttpClient`, JSON `/confs` requests, `MultipartFormDataContent`, Git.

---

## File Map

- Create `puc-config/scripts/PucIncidentAlarmLevels.psm1`: definitions, assets, ZIP validation, classification, preview hash.
- Create `puc-config/scripts/Invoke-PucIncidentAlarmLevels.ps1`: modes, auth, reads, multipart writes, verification.
- Create `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`: dependency-free offline and fake-server tests.
- Create `puc-config/references/incident-alarm-levels.md`: user workflow and confirmation contract.
- Modify `puc-config/SKILL.md`, `puc-config/agents/openai.yaml`, and `README.md`: discovery and routing.
- Synchronize the tested tree to `C:\Users\211245470\.codex\skills\puc-config` without touching local configuration.

### Task 1: Fixed Definitions And Asset Resolution

**Files:**
- Create: `puc-config/scripts/PucIncidentAlarmLevels.psm1`
- Create: `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`

- [ ] Write a failing `Definitions` case asserting the exact ordered mapping:

```powershell
@(
  @{code='00';name='星标';color='#E56659';zip='星标.zip';tone='CriticalAlarm.wav'},
  @{code='01';name='黄标';color='#eba54d';zip='黄标.zip';tone='MediumAlarm.wav'},
  @{code='02';name='普通';color='#eba54d';zip='普通.zip';tone='MediumAlarm.wav'},
  @{code='03';name='预警';color='#73cb6d';zip='普通.zip';tone='CommonlyAlarm.wav'},
  @{code='04';name='指令';color='#73cb6d';zip='普通.zip';tone='CommonlyAlarm.wav'}
)
```

Assert descriptions are `<name>警情等级说明`, same-name ZIP wins, and missing same-name ZIP falls back to `普通.zip`.

- [ ] Run and verify RED:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\puc-config\tests\Test-PucIncidentAlarmLevels.ps1 -Case Definitions
```

Expected: failure because the module/functions do not exist.

- [ ] Export `Get-PucIncidentAlarmLevelDefinitions` and `Resolve-PucIncidentAlarmLevelAssets`; require an absolute asset directory and do not accept arbitrary mappings.
- [ ] Re-run; expect `PASS Definitions` and exit code `0`.
- [ ] Commit:

```powershell
git add puc-config/scripts/PucIncidentAlarmLevels.psm1 puc-config/tests/Test-PucIncidentAlarmLevels.ps1
git commit -m "feat: define fixed incident alarm levels"
```

### Task 2: ZIP Safety

**Files:**
- Modify: `puc-config/scripts/PucIncidentAlarmLevels.psm1`
- Modify: `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`

- [ ] Add a failing `ZipValidation` case using temporary valid, empty, invalid, absolute-path, and `../` traversal ZIP fixtures.
- [ ] Require at least one non-empty `.svg` file; reject directories-only archives, non-SVG files, rooted paths, drive prefixes, and traversal.
- [ ] Run and verify RED because `Test-PucIncidentZip` is missing.
- [ ] Implement validation with `ZipFile::OpenRead` and no extraction. Return only resolved path, leaf name, length, SHA-256, and entry count; dispose archives in `finally`.
- [ ] Run `Definitions` and `ZipValidation`; expect both pass.
- [ ] Commit:

```powershell
git add puc-config/scripts/PucIncidentAlarmLevels.psm1 puc-config/tests/Test-PucIncidentAlarmLevels.ps1
git commit -m "feat: validate incident icon archives"
```

### Task 3: Classification And Preview Hash

**Files:**
- Modify: `puc-config/scripts/PucIncidentAlarmLevels.psm1`
- Modify: `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`

- [ ] Add a failing `Preview` case covering null successful lists, missing items, exact unchanged items, code/name conflicts, duplicate records, missing/duplicate tones, and deterministic hashes.
- [ ] Compare code and name case-sensitively. An unchanged record must match code, name, normalized uppercase color, selected ZIP leaf name, and `toneInfo.file_name`.
- [ ] Run and verify RED because `New-PucIncidentAlarmLevelPreview` is missing.
- [ ] Implement a canonical ordered JSON projection containing environment, five target fields, ZIP SHA-256, tone, and classification. Exclude absolute paths, tokens, server IDs, icon content, and GUIDs.
- [ ] Return `Items`, `PlannedWrites`, `HasConflict`, and uppercase SHA-256 `PreviewHash`.
- [ ] Run `-Case Module`; expect all pure module cases pass.
- [ ] Commit:

```powershell
git add puc-config/scripts/PucIncidentAlarmLevels.psm1 puc-config/tests/Test-PucIncidentAlarmLevels.ps1
git commit -m "feat: preview incident alarm level changes"
```

### Task 4: Modes, Authentication, And Paginated Reads

**Files:**
- Create: `puc-config/scripts/Invoke-PucIncidentAlarmLevels.ps1`
- Modify: `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`

- [ ] Add a failing `CommandReads` case. Validate exactly one of `PlanOnly`, `DryRun`, or `Live`; live requires `ConfirmLive` and `ExpectedPreviewHash`.
- [ ] Build a local `HttpListener` fixture serving paginated `query_alert_tone` and `taskmgr_query_police_incident_alarm_level`, including `result: 0` with a null list.
- [ ] Run and verify RED because the command is missing.
- [ ] Implement parameters:

```powershell
param(
  [Parameter(Mandatory)][string]$Environment,
  [switch]$PlanOnly, [switch]$DryRun, [switch]$Live,
  [switch]$ConfirmLive, [string]$ExpectedPreviewHash,
  [string]$ConfigRoot, [string]$EndpointOverride
)
```

- [ ] Permit `EndpointOverride` only when `PUC_CONFIG_TEST_MODE=1`. Normal mode resolves `/confs` from the environment and validates the saved token through `Invoke-PucAuth.ps1`.
- [ ] Send JSON with `ConvertTo-PucJsonBytes`, decode with `ConvertFrom-PucResponseEncoding`, require top-level `result: 0`, normalize null lists, and cap pagination at 1000 pages.
- [ ] Run `CommandReads` and `Module`; expect both pass.
- [ ] Commit:

```powershell
git add puc-config/scripts/Invoke-PucIncidentAlarmLevels.ps1 puc-config/tests/Test-PucIncidentAlarmLevels.ps1
git commit -m "feat: add incident alarm level preflight"
```

### Task 5: Multipart Writes And Verification

**Files:**
- Modify: `puc-config/scripts/Invoke-PucIncidentAlarmLevels.ps1`
- Modify: `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`

- [ ] Add failing `LiveFlow` tests asserting snapshot mismatch and conflicts cause zero writes; unchanged items skip; missing items write in `00`-`04` order.
- [ ] Assert each multipart request contains exactly `icon_zip_file`, `cmd_guid`, `cmd_name`, `puc_id`, `realm`, `user_id`, `level_code`, `level_name`, `level_desc`, `icon_color`, `icon_zip_name`, and `tone_id`.
- [ ] Assert Chinese UTF-8 text, filename, ZIP bytes, and tones arrive intact. Assert second-write failure gives prior `created`, current `failed`, later `not-attempted`, and no retry.
- [ ] Run and verify RED because multipart/live behavior is absent.
- [ ] Implement one `HttpClient`; create and dispose fresh `MultipartFormDataContent` per missing item. Use UTF-8 `StringContent`, ZIP `StreamContent`, `application/x-zip-compressed`, and standards-compliant Unicode content disposition.
- [ ] On failed or uncertain response, stop immediately and emit sanitized partial results without token, body, icon bytes, or GUIDs.
- [ ] After all writes return `result: 0`, perform one full read and require all five classifications to be `unchanged`; never retry writes during verification.
- [ ] Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\puc-config\tests\Test-PucIncidentAlarmLevels.ps1 -Case All
```

Expected: all cases pass and no sensitive markers appear.

- [ ] Commit:

```powershell
git add puc-config/scripts/Invoke-PucIncidentAlarmLevels.ps1 puc-config/tests/Test-PucIncidentAlarmLevels.ps1
git commit -m "feat: configure incident alarm levels"
```

### Task 6: Skill Routing And Documentation

**Files:**
- Create: `puc-config/references/incident-alarm-levels.md`
- Modify: `puc-config/SKILL.md`
- Modify: `puc-config/agents/openai.yaml`
- Modify: `README.md`
- Modify: `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`

- [ ] Add a failing `SkillRouting` case requiring the new reference route, login route, DryRun/live commands, five-item display, confirmation hash, conflict stop, unchanged skip, no retry, and partial-result instructions.
- [ ] Run and verify RED because the route/reference is missing.
- [ ] Document exact commands:

```powershell
& <skill>\scripts\Invoke-PucIncidentAlarmLevels.ps1 -Environment <environment> -DryRun
& <skill>\scripts\Invoke-PucIncidentAlarmLevels.ps1 -Environment <environment> -Live -ConfirmLive -ExpectedPreviewHash <hash>
```

- [ ] Require display of environment, five classifications, ZIP leaf names and hashes, tones, planned writes, and preview hash before confirmation.
- [ ] Update `SKILL.md` description/route, UI metadata, and README capability without embedding secrets or HAR data.
- [ ] Run `SkillRouting` and `All`; expect all pass.
- [ ] Commit:

```powershell
git add puc-config/SKILL.md puc-config/references/incident-alarm-levels.md puc-config/agents/openai.yaml README.md puc-config/tests/Test-PucIncidentAlarmLevels.ps1
git commit -m "docs: route incident alarm level configuration"
```

### Task 7: Validation And Installed-Skill Sync

**Files:**
- Verify: `puc-config/**`
- Update installation: `C:\Users\211245470\.codex\skills\puc-config`

- [ ] Run syntax, tests, and whitespace checks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[void][ScriptBlock]::Create((Get-Content -Raw '.\puc-config\scripts\PucIncidentAlarmLevels.psm1')); [void][ScriptBlock]::Create((Get-Content -Raw '.\puc-config\scripts\Invoke-PucIncidentAlarmLevels.ps1'))"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\puc-config\tests\Test-PucIncidentAlarmLevels.ps1 -Case All
git diff --check
```

- [ ] Run `quick_validate.py` if PyYAML exists. Otherwise explicitly validate UTF-8 frontmatter, `name: puc-config`, non-empty description, and `agents/openai.yaml`, and report the missing dependency.
- [ ] Run `git status --short` and a sensitive-data scan. Ensure no HAR, token, runtime config, or plaintext credential is staged. Preserve the user's existing four configuration-root edits.
- [ ] Back up the installed skill, copy the tested repository `puc-config` tree over it, and leave `F:\puc-word\agentSkillLocalConfig\puc-config` untouched.
- [ ] Compare all relative file paths and SHA-256 hashes between source and installation; require zero differences. Run installed `-PlanOnly` and require five definitions and three bundled ZIP files with no network use.
- [ ] Report commits, tests, validation fallback if needed, installation hash comparison, and retained working-tree changes. Do not commit installed files outside the repository.
