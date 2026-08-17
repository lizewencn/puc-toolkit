# Android Upgrade Package Builder Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build validated local Android upgrade packages from the PUC Toolkit desktop app and add an upload button whose environment gate is complete while the server API remains explicitly unavailable.

**Architecture:** A new top-level PowerShell module owns APK inspection and nested ZIP generation. A thin script in `puc-config/scripts` bridges the existing hidden-process launcher to that module; the launcher adds local-only fields, asynchronous inspection, preview confirmation, package-result state, and the upload-button gate.

**Tech Stack:** Windows PowerShell 5.1, WinForms, .NET ZIP APIs, bundled Android Build Tools 34.0.0 `aapt.exe`.

---

### Task 1: Core contract and tests

**Files:**
- Create: `make-android-upgrade-package/tests/Test-AndroidUpgradePackage.ps1`
- Create: `make-android-upgrade-package/tests/fixtures/fake-aapt.cmd`
- Create: `make-android-upgrade-package/tests/fixtures/sample.apk`

- [ ] Write failing tests for strict `aapt dump badging` parsing, Int64 versionCode, MD5/size, filename sanitization, JSON values, exact nested ZIP entries, overwrite rejection, tamper detection, and temp cleanup.
- [ ] Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File make-android-upgrade-package\tests\Test-AndroidUpgradePackage.ps1` and confirm failure because the module is absent.

### Task 2: Core module and command

**Files:**
- Create: `make-android-upgrade-package/scripts/AndroidUpgradePackage.psm1`
- Create: `make-android-upgrade-package/scripts/Invoke-AndroidUpgradePackage.ps1`
- Create: `make-android-upgrade-package/references/package-format.md`

- [ ] Implement `Get-AndroidApkInfo`, `Get-AndroidUpgradePackageName`, `New-AndroidUpgradePackage`, and `Assert-AndroidUpgradePackage` with strict inputs and cleanup in `finally`.
- [ ] Implement `Inspect`, `Preview`, and `Build` command modes. Preview/Build consume a BOM-free UTF-8 manifest and reinspect the APK to reject changes after selection.
- [ ] Emit one compressed JSON result with `status`, package/version/hash fields, and a nonempty `results` array; failures exit nonzero with a concise Chinese message.
- [ ] Run the core test and confirm all assertions pass.

### Task 3: Bundle and verify aapt

**Files:**
- Create: `make-android-upgrade-package/tools/aapt.exe`
- Create: `make-android-upgrade-package/tools/libwinpthread-1.dll`
- Create: `make-android-upgrade-package/tools/NOTICE.txt`
- Create: `make-android-upgrade-package/tools/source.properties`

- [ ] Copy the four files from `F:\as\AndroidStudio\AndroidStudio\android-sdks\build-tools\34.0.0`.
- [ ] Run `make-android-upgrade-package\tools\aapt.exe version` with Android SDK variables removed and verify exit code 0.
- [ ] Record revision, origin, package schema, MD5 rules, and notice distribution in `references/package-format.md`.

### Task 4: Desktop bridge and UI state

**Files:**
- Create: `puc-config/scripts/Invoke-AndroidUpgradePackage.ps1`
- Modify: `puc-config/scripts/PucConfigLauncher.ps1`
- Modify: `puc-config/scripts/PucResultRenderer.psm1`
- Modify: `puc-config/tests/Test-PucSyntax.ps1`

- [ ] Extend launcher self-tests from 16 to 17 operations and assert `android-upgrade` has APK, description, force radio, and output-folder fields but does not require an environment for Build.
- [ ] Add the bridge with only `Inspect`, `Preview`, `Build`, APK path, and manifest path inputs; resolve the top-level module from the repository root and never accept an arbitrary executable path.
- [ ] Add stable `Apk`, `Multiline`, `Radio`, and `Folder` controls. Inspect the selected APK through a hidden process and show package name, versionName, versionCode, size, and MD5.
- [ ] Build a temporary JSON manifest, run Preview, use the existing inline confirmation controls, then run Build. Delete only launcher-created manifests.
- [ ] Add a dedicated `上传` button beside the action controls. Disable it on startup, operation/input changes, build start, build failure, and package clear; enable it only after a successful Build result supplies an existing validated `finalPath`.
- [ ] On upload click, require a selected environment present in the current environment catalog. Without one, show `请先新增或选择 PUC 环境后再上传。`; with one, show `PUC 升级包上传接口尚未配置，未执行上传。`. Do not start a process or report success.
- [ ] Add renderer labels for inspection, preview, build, final path, version, and MD5 fields.

### Task 5: Verification and documentation

**Files:**
- Modify: `puc-config/references/launcher.md`
- Modify: `README.md`

- [ ] Run the core tests, PowerShell syntax test, launcher `-SelfTest`, and `-UiSelfTest`; require exit code 0 from every command.
- [ ] Verify the upload button state transitions with and without a configured environment and confirm no upload process starts.
- [ ] Generate a package from a real PUC APK, verify its approved filename and nested archive, and repeat against an existing output to confirm no overwrite.
- [ ] Document the new top-level module, local workflow, bundled tool, upload gate, and explicitly unavailable phase-one server transfer.
- [ ] Run `git diff --check` and confirm no generated APK, upgrade ZIP, or temporary manifest is tracked.
