# APP Business Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an isolated APP 业务 top-level tab to PUC Toolkit for APP login, online status, and batch group creation while preserving the existing PUC 配置 workflow.

**Architecture:** Keep the existing PowerShell launcher and PUC configuration controls intact. Add a top-level `TabControl` wrapper with the existing controls moved into a PUC tab, and build APP controls in a separate module/script block. Use a small Python bridge process for UI-safe commands/events, reusing `app_puc_login` and `app_puc_group_batch`; share only the existing environment list and selected environment address.

**Tech Stack:** PowerShell, Windows Forms, Python 3.10+, `app-puc-login`, `app-puc-group-batch`, existing PUC launcher test/self-test conventions.

---

### Task 1: Define the APP bridge contract

**Files:**
- Create: `puc-config/scripts/AppPucBridge.py`
- Create: `puc-config/tests/Test-AppPucBridge.ps1`

- [ ] **Step 1: Write failing bridge tests**

Test the JSON-lines contract without connecting to a server: `login` validates required fields and emits a structured state event; `status` reports disconnected when no client exists; `stop` is idempotent; `batch_create_groups` rejects requests without an authenticated session.

- [ ] **Step 2: Run the bridge tests and verify the expected failures**

Run `pytest app_puc_login/tests -q` for the dependency baseline and `pwsh -File puc-config/tests/Test-AppPucBridge.ps1`; the new contract assertions must fail because the bridge does not exist.

- [ ] **Step 3: Implement the minimal bridge**

Read one JSON object per stdin line and write one JSON event per stdout line. Keep a single `PucLoginClient`, callback events into a thread-safe queue, expose `login`, `stop`, `status`, and `batch_create_groups`, and never write passwords or tokens to output. Resolve the `app_puc_login` and `app_puc_group_batch` packages from the repository during local development.

- [ ] **Step 4: Run bridge tests and package tests**

Run `pwsh -File puc-config/tests/Test-AppPucBridge.ps1` and `python -m pytest app_puc_login/tests -q`; expect all bridge assertions and the existing login tests to pass.

- [ ] **Step 5: Commit the bridge**

Run `git add puc-config/scripts/AppPucBridge.py puc-config/tests/Test-AppPucBridge.ps1` and commit with `feat: add APP business bridge`.

### Task 2: Add isolated APP page controls and environment synchronization

**Files:**
- Modify: `puc-config/scripts/PucConfigLauncher.ps1`
- Create: `puc-config/tests/Test-AppBusinessTab.ps1`

- [ ] **Step 1: Write failing UI self-test assertions**

Assert that the main form has top-level tabs named `PUC 配置` and `APP 业务`, the APP page has an environment combo and `新增环境` button, the APP server value initially follows the selected PUC environment, and the batch button is disabled until online.

- [ ] **Step 2: Run the UI self-test to confirm failure**

Run `pwsh -File puc-config/tests/Test-AppBusinessTab.ps1`; expect failure because the launcher currently has only the existing single workflow.

- [ ] **Step 3: Wrap existing controls without changing their handlers**

Create the top-level tab control before layout construction. Put the current selection, input, action, and result controls under the PUC 配置 tab, preserving existing variable names and event handlers. Add the APP tab using separate variable names and an explicit panel hierarchy so existing PUC sizing and result tabs remain unchanged.

- [ ] **Step 4: Implement shared environment behavior**

Populate the APP environment combo from the same environment collection used by `$environmentBox`; reuse the existing add-environment dialog/button flow; select the current PUC environment on tab initialization. Track an `$appServerFollowsEnvironment` flag: synchronize APP server address on environment changes only while true, and set it false on manual edits. Add a “跟随当前环境” reset action.

- [ ] **Step 5: Run the UI self-test and existing launcher tests**

Run `pwsh -File puc-config/tests/Test-AppBusinessTab.ps1`, `pwsh -File puc-config/tests/Test-PucCore.ps1`, and the launcher self-test command used by the repository; expect the new tab assertions and existing PUC assertions to pass.

- [ ] **Step 6: Commit the isolated UI shell**

Run `git add puc-config/scripts/PucConfigLauncher.ps1 puc-config/tests/Test-AppBusinessTab.ps1` and commit with `feat: add APP business tab shell`.

### Task 3: Connect login lifecycle and online status

**Files:**
- Modify: `puc-config/scripts/PucConfigLauncher.ps1`
- Modify: `puc-config/scripts/AppPucBridge.py`
- Modify: `puc-config/tests/Test-AppBusinessTab.ps1`

- [ ] **Step 1: Add failing state transition tests**

Feed representative bridge events (`connecting`, `login_success`, `reconnecting`, `disconnected`, `error`, `stopped`) into the UI state mapper and assert status text/color, account and APP PUC ID updates, and batch-button enablement.

- [ ] **Step 2: Implement bridge process lifecycle**

Start the bridge only when APP login is requested, send JSON commands asynchronously, drain stdout on a background PowerShell event/timer path, and terminate it on stop/form close. Ensure stale events from a previous login cannot update the current account view.

- [ ] **Step 3: Implement UI state mapping**

Map login events to Chinese status text and a visible status color. Show account and `app_puc_id` only after login success. Enable batch controls only for the current successful session; disable them on reconnecting, disconnected, error, and stopped.

- [ ] **Step 4: Run targeted state tests and regression tests**

Run `pwsh -File puc-config/tests/Test-AppBusinessTab.ps1` and `pwsh -File puc-config/tests/Test-PucCore.ps1`; verify no existing PUC UI test changes are required.

- [ ] **Step 5: Commit login integration**

Commit with `feat: show APP login online status`.

### Task 4: Add batch group UI and result rendering

**Files:**
- Modify: `puc-config/scripts/PucConfigLauncher.ps1`
- Modify: `puc-config/scripts/AppPucBridge.py`
- Create: `puc-config/tests/Test-AppGroupBatch.ps1`

- [ ] **Step 1: Write failing batch UI tests**

Assert member parsing, positive group count validation, disabled execution while offline, progress row updates, and final status counts for renamed, rename-failed, create-failed, and session-unavailable results.

- [ ] **Step 2: Implement bridge batch command**

Convert UI member rows to `AppGroupMemberInput` values, invoke `AppPucGroupBatchService.create_groups`, emit progress events as JSON, and emit one final summary without exposing credentials.

- [ ] **Step 3: Implement APP batch controls**

Add a member grid with account and APP PUC ID columns, group count input, add/remove row controls, start/stop-safe button states, progress label, and result grid. Keep all controls under the APP tab and do not reuse PUC result controls.

- [ ] **Step 4: Run batch and full regression tests**

Run `pwsh -File puc-config/tests/Test-AppGroupBatch.ps1`, `python -m pytest app_puc_login/tests -q`, and all relevant `puc-config/tests/Test-*.ps1`; expect existing PUC configuration behavior to remain unchanged.

- [ ] **Step 5: Commit batch UI**

Commit with `feat: add APP batch group controls`.

### Task 5: Final verification and documentation

**Files:**
- Modify: `README.md`
- Modify: `app_puc_login/README.md` only if installation instructions need correction for Toolkit use

- [ ] **Step 1: Run the complete verification set**

Run the Python tests, APP bridge/UI tests, existing PUC PowerShell tests, and the launcher UI self-test. Record any environment-dependent tests that cannot run without a live PUC server.

- [ ] **Step 2: Perform manual UI checks**

Verify environment dropdown reuse, new-environment propagation, manual server override and reset, online status transitions, batch button gating, and safe form shutdown.

- [ ] **Step 3: Document usage**

Add concise Toolkit documentation describing the APP 业务 tab, environment selection, login lifecycle, and batch group input format. Do not alter existing PUC configuration instructions.

- [ ] **Step 4: Commit documentation and verification fixes**

Commit with `docs: document APP business tab` or a focused fix message as appropriate.

