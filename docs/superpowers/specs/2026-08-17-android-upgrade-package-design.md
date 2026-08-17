# Android upgrade package builder design

## Goal

Add a local Android upgrade package builder to the existing PUC Toolkit desktop application. The first version accepts a local APK only. It must run on Windows computers that do not have Python, Android Studio, or the Android SDK installed.

## Project boundary

Create a new top-level directory named `make-android-upgrade-package`:

```text
make-android-upgrade-package/
|-- scripts/      # APK inspection and package generation
|-- tools/        # Bundled aapt executable and required runtime files
|-- tests/        # Automated tests and fixtures
`-- references/   # Upgrade package format documentation
```

Keep APK inspection and package generation in this directory. Change `puc-config` only to add the desktop UI entry and dispatch into the new module. Do not copy packaging logic into the launcher.

FTP input is explicitly out of scope for the first version. Do not display a disabled or unfinished FTP option.

## Desktop workflow

Add `制作 Android 升级包` to the desktop application's operation catalog.

Package creation does not require a selected PUC environment. Keep the normal environment selector available because a completed package may subsequently be uploaded, but do not block inspection, preview, or local generation when no environment is configured.

The operation collects:

- A local `.apk` file selected with a file picker.
- A required upgrade description entered by the user.
- A `force` choice presented as `否` and `是` radio buttons, defaulting to `否`.
- No output-directory input. Derive the output directory from the selected APK's parent directory.

After APK selection, inspect it automatically and display:

- APK path and filename.
- Android package name.
- `versionName`.
- `versionCode`.
- File size.
- APK MD5.

Disable package generation until the APK has been inspected successfully and all required inputs are complete. Before generation, show a confirmation preview containing the selected APK, parsed version information, description, force choice, and the derived destination beside the APK.

Run generation through the launcher's existing hidden child-workflow mechanism. Show progress, structured success or failure output, and the final package path in the existing result area. Do not expose command windows.

Do not show a completion dialog and do not open File Explorer. After a successful build, supplement the existing `执行摘要` with the final path, filename, package size, APK MD5, and `upgrade.zip` MD5. Show the created file in `执行结果` with status `已制作完成`.

Add a separate `上传` button. Keep it disabled until the current launcher session has successfully created and validated a package. Clicking it must first require a currently selected, configured PUC environment. If no valid environment is available, stop locally with a Chinese instruction to add or select an environment. The PUC upload request itself is outside the first implementation phase until its API contract is supplied; during this phase, a valid-environment click reports explicitly that the upload interface is not configured and must never claim that an upload occurred.

## APK inspection

Bundle `aapt.exe` and every runtime file proven necessary on a clean Windows machine under `make-android-upgrade-package/tools`. Invoke only the bundled copy so behavior does not depend on `PATH`, `ANDROID_HOME`, or `ANDROID_SDK_ROOT`.

Use `aapt dump badging <apk>` and parse the package record for:

- Package name.
- `versionCode`.
- `versionName`.

Treat missing fields, a nonzero process exit, malformed output, a missing bundled executable, or a non-APK input as a blocking error. Include actionable diagnostics without leaking unrelated environment data.

Document the bundled Android Build Tools version and its origin in the format reference. Include the applicable upstream license or notice required for redistribution.

## Package format

Create the following structure:

```text
升级包_<versionName>_<versionCode>.zip
|-- upgrade.zip
|   |-- <original-apk-filename>.apk
|   `-- version.json
`-- MD5.txt
```

Sanitize characters that are invalid in Windows filenames in `versionName` and `versionCode` by replacing them with `_`. Preserve the original values inside `version.json`.

Write `version.json` as UTF-8 JSON with these fields:

```json
{
  "version_code": 4300016,
  "version_name": "4.3.00.016",
  "md5": "<apk-md5>",
  "force": false,
  "description": "<user-entered-description>",
  "terminal": "android",
  "apksize": 12345678
}
```

Preserve the parsed type of `version_code` when it is a decimal integer. Reject a value that cannot be represented reliably rather than silently changing it.

`MD5.txt` contains the lowercase 32-character MD5 digest of the completed `upgrade.zip`, followed by a newline. The internal filenames `upgrade.zip`, `version.json`, and `MD5.txt` remain fixed.

## File safety

Build in a uniquely named temporary directory outside the source APK directory. Always clean launcher-created temporary files after success or failure.

Never modify or delete the selected APK. Never silently overwrite an existing final package. If the destination filename already exists, stop and ask the user to select another directory or remove/rename the existing artifact.

Write the final archive to a temporary filename in the selected destination, validate it, and then rename it to the final filename so an interrupted run does not leave an apparently complete package.

## Validation and errors

After generation:

1. Reopen the inner and outer ZIP archives.
2. Verify the exact expected entry names and reject missing or unexpected entries.
3. Parse `version.json` and compare every generated value with the inspected APK and user inputs.
4. Recalculate the APK MD5 and size from the archived APK.
5. Recalculate the `upgrade.zip` MD5 and compare it with `MD5.txt`.

Return a structured result containing status, final path, version values, APK MD5, upgrade ZIP MD5, and output size. On failure, return a nonzero exit code and a concise Chinese error message. Do not leave a final package behind after failed validation.

## Testing

Add automated coverage for:

- Successful parsing of a representative APK fixture.
- Missing or invalid APK input.
- Missing bundled `aapt` runtime.
- Correct `version.json` values and UTF-8 description handling.
- `force` true and false.
- Exact inner and outer ZIP structure.
- APK and `upgrade.zip` MD5 verification.
- Final filename generation and invalid-character replacement.
- Existing destination file protection.
- Temporary-directory cleanup after success and failure.
- Launcher catalog, required fields, radio-button defaults, dispatch arguments, and structured result rendering.

Run the existing launcher self-tests and UI self-tests in addition to the new module tests.

## Acceptance criteria

The feature is complete when a user can open PUC Toolkit from the desktop, select `制作 Android 升级包`, choose a valid local APK, review automatically parsed version information, enter a description, select the force option and output directory, confirm the preview, and receive a validated `升级包_<versionName>_<versionCode>.zip` without requiring Python or an installed Android SDK.

The first implementation phase also completes the upload-button state machine and environment precondition. Actual server transfer remains blocked until the PUC upload API request and response contract is provided.
