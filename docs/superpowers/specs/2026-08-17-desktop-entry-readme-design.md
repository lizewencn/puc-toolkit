# README Desktop Entry Documentation Design

## Goal

Add a concise, user-facing section to the repository README that explains how to create and use the Windows desktop entry for the PUC configuration launcher.

## Placement

Insert a new `创建桌面入口` section after `技能包一览` and before `技能包简介`. This keeps the entry point prominent without interrupting the initial repository overview.

## Content

The section will:

- State that the desktop entry is intended for Windows.
- Show the repository-relative installer command: `puc-config\scripts\Invoke-PucScript.cmd Install-PucConfigToolShortcut.ps1`.
- Explain that the command creates or refreshes `PUC Toolkit.lnk` on the current user's desktop.
- Note that rerunning the command refreshes the shortcut after the repository or skill path changes.
- Tell users to double-click `PUC Toolkit` to start the graphical tool without a console window.

## Scope

Only `README.md` will be changed during implementation. Launcher scripts, installation behavior, and other documentation remain unchanged.

## Verification

- Confirm the new heading appears in the agreed location.
- Confirm the documented command matches `puc-config/references/launcher.md`.
- Confirm Markdown links, code fences, and surrounding heading structure remain valid.
- Review the final diff for unrelated changes and encoding damage.
