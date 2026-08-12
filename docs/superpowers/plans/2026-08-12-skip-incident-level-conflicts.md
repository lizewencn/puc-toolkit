# Skip Incident Alarm Level Conflicts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Skip alarm-level items whose code or name already exists and continue creating every later non-conflicting item.

**Architecture:** Keep identity classification in `PucIncidentAlarmLevels.psm1` and orchestration in `Invoke-PucIncidentAlarmLevels.ps1`. Preflight conflicts become reportable skips; an authoritative create-time duplicate becomes the same skip result, while transport, malformed, and other API failures retain stop-on-first-failure behavior. Final verification checks only records created during this run.

**Tech Stack:** Windows PowerShell 5.1, .NET `HttpClient`, Python local HTTP fixture, repository PowerShell test harness.

---

### Task 1: Define Identity Conflicts

**Files:**
- Modify: `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`
- Modify: `puc-config/scripts/PucIncidentAlarmLevels.psm1`

- [ ] **Step 1: Write the failing preview tests**

Change `Test-Preview` to assert that an exact existing record, a matching code only, and a matching name only are all `conflict`, while unrelated targets remain `missing` and contribute to `PlannedWrites`.

- [ ] **Step 2: Run the preview test and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File puc-config/tests/Test-PucIncidentAlarmLevels.ps1 -Case Preview`

Expected: FAIL because the exact existing record is currently classified `unchanged`.

- [ ] **Step 3: Implement the minimal classifier**

In `New-PucIncidentAlarmLevelPreview`, classify a target as `conflict` whenever `$codeMatches.Count -gt 0 -or $nameMatches.Count -gt 0`, with reason `existing-code-or-name`; otherwise classify it as `missing`. Preserve `HasConflict`, `PlannedWrites`, and deterministic preview hashing.

- [ ] **Step 4: Run the preview test and verify GREEN**

Run the Step 2 command. Expected: `PASS Preview`.

### Task 2: Continue After Preflight And Create-Time Conflicts

**Files:**
- Modify: `puc-config/tests/incident_fake_server.py`
- Modify: `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`
- Modify: `puc-config/scripts/Invoke-PucIncidentAlarmLevels.ps1`

- [ ] **Step 1: Write failing live-flow tests**

Extend the fake server with scenarios that seed an existing conflicting level and return an authoritative duplicate result for one create. Assert both items become `conflict-skipped`, later missing codes are still created in order, and `writesUsed` counts only `created` results. Retain a separate non-conflict failure scenario that marks later items `not-attempted`.

- [ ] **Step 2: Run live-flow tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File puc-config/tests/Test-PucIncidentAlarmLevels.ps1 -Case LiveFlow`

Expected: FAIL because live mode currently aborts before all writes when `HasConflict` is true and treats every nonzero create result as fatal.

- [ ] **Step 3: Implement authoritative conflict parsing**

Return a structured create outcome from the multipart response parser. Treat only the documented duplicate result/message fixture as `conflict-skipped`; keep HTTP errors, empty or invalid responses, missing `result`, and unrelated nonzero results as exceptions.

- [ ] **Step 4: Implement continued orchestration**

Remove the batch-wide `HasConflict` rejection. Emit `conflict-skipped` immediately for preflight conflicts, create only `missing` items, continue after authoritative create-time conflicts, and stop after every other failure.

- [ ] **Step 5: Restrict final verification**

Query levels once after writes and verify each `created` result against the target code, name, normalized color, ZIP name, and tone. Do not require preflight or create-time conflicts to match target values.

- [ ] **Step 6: Run live-flow tests and verify GREEN**

Run the Step 2 command. Expected: `PASS LiveFlow`.

### Task 3: Update Workflow Contract And Verify

**Files:**
- Modify: `puc-config/references/incident-alarm-levels.md`
- Modify: `puc-config/tests/Test-PucIncidentAlarmLevels.ps1`

- [ ] **Step 1: Write the failing routing/contract assertion**

Require the reference to state that equal code or equal name is a conflict, conflicts are skipped, subsequent missing items continue, authoritative create-time duplicates continue, and other failures stop without retry.

- [ ] **Step 2: Run the contract test and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File puc-config/tests/Test-PucIncidentAlarmLevels.ps1 -Case SkillRouting`

Expected: FAIL because the reference currently says conflicts stop the complete batch.

- [ ] **Step 3: Update the reference**

Replace the obsolete `unchanged` and batch-stop language with the confirmed conflict identity and result statuses: `created`, `conflict-skipped`, `failed`, and `not-attempted`.

- [ ] **Step 4: Run all incident tests**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File puc-config/tests/Test-PucIncidentAlarmLevels.ps1 -Case All`

Expected: all six cases print `PASS` and exit `0`.

- [ ] **Step 5: Check patch integrity**

Run: `git diff --check`

Expected: exit `0` with no whitespace errors. Review `git diff -- puc-config/scripts/PucIncidentAlarmLevels.psm1 puc-config/scripts/Invoke-PucIncidentAlarmLevels.ps1 puc-config/tests/Test-PucIncidentAlarmLevels.ps1 puc-config/tests/incident_fake_server.py puc-config/references/incident-alarm-levels.md` and confirm no unrelated files changed.
