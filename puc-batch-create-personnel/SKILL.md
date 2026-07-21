---
name: puc-batch-create-personnel
description: Configure and execute the PUC personnel-creation module under puc-config-manager, including generated identifiers, duplicate checks, organization assignment, and reports.
---

# PUC Personnel Module

Edit `module_config.json` for all personnel-specific inputs. Do not put server addresses or administrator credentials in this module.

Run through the sibling `puc-config-manager/PucConfigManager.cmd`. Enable `personnel` in the manager's `modules.json`; configure connection and run mode only in the manager's `manager_config.json`.

Use `scripts/Test-PucPersonnelModule.ps1` for verification. Read `references/api.md` before changing `references/adapter.json`.

Require exact duplicate checks for every generated identifier. Do not retry create requests.
