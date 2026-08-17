# Graphical launcher

Use `scripts/Start-PucConfigTool.vbs` for a no-console, one-click WinForms entry point. Keep the GUI as a thin dispatcher over `Invoke-PucScript.cmd`; never duplicate PUC HTTP, authentication, encryption, lookup, or write logic in the launcher.

Create or refresh the current user's desktop shortcut only when the user explicitly requests a desktop entry point. Obtain filesystem approval before writing to the desktop, then run:

```powershell
scripts\Invoke-PucScript.cmd Install-PucConfigToolShortcut.ps1
```

The installer is idempotent and resolves the installed skill path at runtime. It creates `PUC Toolkit.lnk` on the current user's desktop with `wscript.exe` targeting `Start-PucConfigTool.vbs`, and uses `assets/puc-config.ico` as its icon, so opening it does not show a PowerShell or Command Prompt window. It migrates the legacy `PUC Configuration Tool.lnk` name when the new shortcut does not exist. Rerun it after the skill is moved or reinstalled at a different path. Do not create the shortcut silently as part of skill installation.

Keep conversational use unchanged: when a user requests a concrete PUC operation in chat, dispatch the underlying workflow directly and do not open the main launcher window. Show only the existing captcha dialog when authentication requires it. Open the main launcher only from the desktop entry point or when the user explicitly asks to open it.

The launcher uses Chinese display text and a content-sized, top-to-bottom layout: environment and operation, operation-specific parameters, execution controls, status, and a bounded result pane. Operations with no parameters must not show an empty parameter section.

Use a stable, non-auto-sized rectangular hit target for every button. Show a hand cursor across the complete enabled button, provide distinct hover and pressed background states, and render disabled buttons with clearly muted foreground and background colors. Apply the same interaction treatment to main actions, secondary actions, file selectors, and dialog actions without duplicating their business click handlers.

Display each environment by the complete lowercase host derived from its `baseUrl`. Normalize legacy abbreviated names on load and stop on complete-host collisions. Provide an `新增环境` button next to the selector. Its dialog collects only a standard IPv4 value for the service address and visibly fixes the protocol and port to `https://` and `:16890`; compose the stored base URL as `https://<ip>:16890`. It also collects realm, administrator account, self-signed TLS selection, and an optional existing environment whose local password settings should be reused. When `不复用` is selected, show administrator-password and new-account/reset-default-password inputs; require both passwords, default the new-account/reset password to `888`, and select `显示密码` by default. Unchecking it masks both inputs. Hide the password inputs when a template is selected. Derive the new key from the IP.

Whenever an environment is selected or the environment list is refreshed, resolve its deployed PUC version with a hidden, read-only GET to `<baseUrl>/env.js` through the bundled Node transport. Accept either a plain JSON object or the deployed `export default { ... }` form, extract the object without evaluating JavaScript, and display `PUC_CONFIG_VERSION` next to the service address. Always place the red warning `不同版本号上表现可能存在差异` beside the version because the bundled workflows are not guaranteed to support every deployed PUC version. Keep version lookup independent from business execution, discard stale responses after the selection changes, and show a compact Chinese failure state without a modal dialog when the request or parsing fails. Do not send credentials or require authentication for `env.js`.

Keep newly entered passwords only in the WinForms process. Call `Initialize-PucEnvironmentConfig` directly so secrets never enter child-process arguments, stdin/stdout, environment variables, temporary files, result text, or reports. Use `Write-PucJson` through that helper for the atomic configuration update, return only password-configured booleans, then clear the launcher object's password references.

The operation catalog supports:

- Dispatcher account creation with an environment, prefix, and optional count. Let the account workflow derive the next sequence from the fresh account list.
- Exact and batch dispatcher password reset. Run authenticated previews first, use temporary manifests for batches, and require confirmation only for query-discovered account sets.
- Exact or query-based account-information completion, and JSON-file-driven account updates.
- Prefix-based batch personnel creation and exact-alias personnel creation as separate forms so irrelevant sequence fields are not displayed.
- First-login password validation and duplicate-login forced-logout status, enable, and disable. Query first; write only when the selected state differs.
- Configuration and License import/export, permission-menu import, and incident alarm-level configuration. Preserve file preflight, preview-hash, replacement-confirmation, and verification requirements from each child workflow.

Run every child process hidden and capture stdout and stderr in the result pane. Let `PucLoginWorker.ps1` show the existing topmost captcha dialog when authentication is required. Apart from the local environment-initialization password inputs, never collect credentials. Never place administrator passwords, new-account passwords, tokens, password ciphers, captcha IDs, or captcha values in result or status text.

Render workflow output as three Chinese tabs. `执行摘要` is the default tab and gives its full available height to the colored status header and concise operation/environment/stage/timing fields. `执行结果` gives its full available height to the account-level or item-level grid. While confirmation is pending, automatically select `执行结果` so the complete preview remains immediately visible; after a later stage finishes, replace the grid with the most recent stage that contains detail rows instead of merging preview and live rows. `详细输出` retains the complete multi-stage diagnostic history for troubleshooting. Make the main window resizable and maximizable, and let every tab grow with it. The renderer's synthetic `group` value identifies the source array; hide that column when every visible row has the same source, and label it `分类` only when mixed sources require the distinction. Parse JSON output structurally when possible and redact sensitive property names before any view is populated; use `[已隐藏]` for password, token, cookie, authorization, secret, captcha, and cipher values. Never rely on truncation as redaction.

Every workflow that produces account-level or item-level outcomes must emit a single-line JSON record containing a non-empty `results` array for those rows, together with its aggregate status and counts. Do not use `Format-Table` or other presentation-formatted text as the launcher's result data source; formatted text belongs only in `详细输出`.

In result grids, give the dispatcher-account column a minimum width suitable for scanning full account names. Keep numeric counts, write counts, percentages, result codes, and stage result codes compact at a width intended for two-digit values; let descriptive columns consume the remaining width.

Classify final states explicitly as `成功`, `部分成功`, `结果不确定`, or `失败`. A nonzero exit is not automatically a simple failure: partial-failure payloads and operations that saved configuration before a later License failure are `部分成功`; messages that state no retry was attempted or require manual reconciliation are `结果不确定`. Preserve the underlying workflow's no-retry rule and explain the next safe action in the summary rather than automatically retrying a write. Confirmation previews and running stages use neutral/progress presentation and must keep the full target list available in the result area.

Treat clicking `Execute` with a selected exact environment and complete operation inputs as the user's explicit business instruction. Preserve every child workflow's own `DryRun`, `Live`, `ConfirmLive`, snapshot, no-retry, and partial-failure guards. Block closing the launcher while a workflow is running so a live write is not made uncertain by terminating its process.

For replacement imports and query-discovered target sets, render the preview in the result pane and pause with inline `确认执行` and `取消` buttons in the main action bar before starting the live step. Never use a modal confirmation dialog because it obscures the preview the user must inspect. Keep the result grid and detailed output available and scrollable while confirmation is pending. Delete launcher-created manifests after the workflow finishes or fails. Never delete user-selected input files.

When account lookup returns `ACCOUNT_LOOKUP_DECISION_REQUIRED`, enter the same inline confirmation state before rerunning with `-ContinueWhenMoreThan30Accounts`. Cancel without another request when the user declines.

Run a local launcher check without opening the GUI:

```powershell
scripts\Invoke-PucScript.cmd PucConfigLauncher.ps1 -SelfTest
```

Run the WinForms control-rendering check without showing the window:

```powershell
scripts\Invoke-PucScript.cmd PucConfigLauncher.ps1 -UiSelfTest
```
