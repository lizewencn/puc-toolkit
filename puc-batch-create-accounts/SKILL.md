---
name: puc-batch-create-accounts
description: Configure and execute the PUC account-creation module under puc-config-manager, including naming rules, encrypted account password, duplicate checks, authorization, and reports.
---

# PUC Account Module

Edit `module_config.json` for all account-specific inputs. Do not put server addresses or administrator credentials in this module.

Run through the sibling `puc-config-manager/PucConfigManager.cmd`. Enable `accounts` in the manager's `modules.json`; configure connection and run mode only in the manager's `manager_config.json`.

Use `scripts/Test-PucAccountModule.ps1` for verification. Read `references/config-schema.md` before changing fields and `references/api.md` before changing `references/adapter.json`.

Require exact duplicate checks and a 32-character hexadecimal new-account ciphertext. Treat reports as sensitive.
