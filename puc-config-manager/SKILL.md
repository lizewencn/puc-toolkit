---
name: puc-config-manager
description: Manage multiple PUC configuration functions through one authenticated API session.
---

# PUC Configuration Manager

Use `PucConfigManager.cmd` without arguments as the single entry point. Read `README.md`, `manager_config.json`, and `modules.json` first. Keep only connection, credentials, TLS, and shared run mode in `manager_config.json`; never pass command-line parameters.

Configure each module's business rules only in that module's `module_config.json`. Use `runMode: plan` for offline generation, `runMode: dry-run` for duplicate checks, and require explicit confirmation before `runMode: live`. The manager logs in once, owns the token, and passes it to all enabled modules.

Do not automate the browser UI. Never accept plaintext passwords. Treat credentials, tokens, HAR files, and reports as sensitive.
