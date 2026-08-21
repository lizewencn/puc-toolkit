---
name: puc-toolkit-updater
description: Update all installable packages from the puc-toolkit GitHub repository through a staged, transactional replacement after the PUC Toolkit GUI exits. Use for repository package update checks, staged installs, rollback, or updater troubleshooting.
---

# PUC Toolkit Updater

Treat the repository commit as the version of every package. Read `references/update-strategy.md` before changing or running the update workflow.

Use `scripts/Invoke-PucToolkitUpdate.ps1` to check or stage an update. The staging process must not modify installed packages. The GUI launches the staged `PucToolkitUpdateWorker.ps1`, closes itself, and lets that worker replace packages transactionally before relaunching the GUI.

Never scan for or force-close unrelated processes. If a package remains locked after the initiating GUI exits, roll back, record the failure, and relaunch the previous GUI.
