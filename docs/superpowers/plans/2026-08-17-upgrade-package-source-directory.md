# Upgrade Package Source Directory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove output-directory selection, write the package beside the APK, and display `已制作完成` in the existing result UI without a dialog.

**Architecture:** Derive `outputDirectory` from the inspected APK path in the command layer so GUI and direct calls share one rule. Remove the folder field and manifest input from the launcher; keep structured Build output as the sole UI completion notification.

**Tech Stack:** Windows PowerShell 5.1, WinForms, existing PowerShell self-tests.

---

### Task 1: Change the command contract

**Files:**
- Modify: `make-android-upgrade-package/tests/Test-AndroidUpgradePackage.ps1`
- Modify: `make-android-upgrade-package/scripts/Invoke-AndroidUpgradePackage.ps1`

- [ ] Add a failing test whose Preview/Build manifest omits `outputDirectory` and assert the final package parent equals `Split-Path $apkPath -Parent`.
- [ ] Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File make-android-upgrade-package\tests\Test-AndroidUpgradePackage.ps1`; expect failure reporting missing `outputDirectory`.
- [ ] Remove `outputDirectory` from required manifest properties and derive it with `Split-Path -Parent $info.Path` for Preview and Build.
- [ ] Emit result-row status `build-complete` from Build.
- [ ] Re-run the core test; expect all assertions to pass.

### Task 2: Remove the desktop output field

**Files:**
- Modify: `puc-config/scripts/PucConfigLauncher.ps1`
- Modify: `puc-config/scripts/PucResultRenderer.psm1`

- [ ] Change launcher self-tests to require only `apkPath`, `description`, and `force` for `android-upgrade`.
- [ ] Run launcher `-SelfTest`; expect failure while `outputDirectory` still exists.
- [ ] Remove the `outputDirectory` field, validation, state value, and manifest property.
- [ ] Map `build-complete` to `已制作完成`; retain final path, filename, size, and both MD5 values in the summary.
- [ ] Run launcher `-SelfTest` and `-UiSelfTest`; expect exit code 0.

### Task 3: Verify and deliver

**Files:**
- Modify: `README.md`
- Modify: `puc-config/references/launcher.md`

- [ ] Document that packages are written beside the source APK and completion appears only in the result UI.
- [ ] Run core tests, syntax tests, launcher self-tests, UI self-tests, and `git diff --check`.
- [ ] Commit with the repository template and merge the isolated branch into `main` after verification.
