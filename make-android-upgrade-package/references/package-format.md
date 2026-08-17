# Android upgrade package format

The module creates `升级包_<versionName>_<versionCode>.zip`. Its outer entries are exactly `upgrade.zip` and `MD5.txt`; `upgrade.zip` contains the original APK filename and `version.json`. `MD5.txt` is the lowercase MD5 of `upgrade.zip` followed by LF.

The final archive is always written to the selected APK's parent directory. Callers do not choose a separate output directory.

`version.json` contains `version_code`, `version_name`, APK `md5`, `force`, `description`, fixed terminal `android`, and `apksize`. It is UTF-8 without BOM.

APK metadata is read with the bundled Android Asset Packaging Tool from Android Build Tools 34.0.0. The checked-in tool files originate from `F:\as\AndroidStudio\AndroidStudio\android-sdks\build-tools\34.0.0`. Distributions must keep `NOTICE.txt` beside the executable.
