@echo off
if /i "%FAKE_AAPT_MODE%"=="fail" (
  echo ERROR: dump failed 1>&2
  exit /b 2
)
if /i "%FAKE_AAPT_REQUIRE_TEMP%"=="1" (
  echo %~3 | findstr /i /c:"puc-aapt-" >nul || (
    echo ERROR: expected ASCII temporary APK path 1>&2
    exit /b 4
  )
)
if /i not "%~1 %~2"=="dump badging" exit /b 3
echo package: name='com.smartone.puc' versionCode='4300016' versionName='4.3.00.016' platformBuildVersionName='14' platformBuildVersionCode='34'
echo application-label:'PUC'
exit /b 0
