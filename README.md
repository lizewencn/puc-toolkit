# PUC Config Toolkit

Private collaborative repository for PUC configuration-management skills. The manager authenticates once, owns the token, and supplies it to enabled account and personnel modules.

## Install

```powershell
.\Install-PucToolkit.ps1
```

The installer copies the three skills to `$CODEX_HOME\skills` (or `$HOME\.codex\skills`) and creates local configuration files from examples only when they do not already exist.

Edit these local files after installation:

- `puc-config-manager\manager_config.json`: server, port, realm, administrator ciphertext, TLS, and run mode.
- `puc-batch-create-accounts\module_config.json`: account creation rules.
- `puc-batch-create-personnel\module_config.json`: personnel creation rules.

These files are ignored by Git. Never rename a local configuration to an example filename.

## Run

```cmd
%USERPROFILE%\.codex\skills\puc-config-manager\PucConfigManager.cmd
```

The command accepts no parameters. Use `runMode: plan` first, `dry-run` for authenticated duplicate checks, and `live` only after explicit approval.

## Safety

Run before every commit:

```powershell
.\Test-RepositorySafety.ps1
```

Do not commit local configurations, reports, HAR captures, tokens, captcha images, or real ciphertext. Private repository visibility does not make credentials safe to commit.
