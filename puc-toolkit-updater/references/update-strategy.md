# Update strategy

The updater owns repository-level version checks and package replacement. A valid installable package is a safe top-level directory containing `SKILL.md` or a `scripts` directory.

The foreground stage checks the repository commit through `git ls-remote` without consuming the GitHub REST API rate limit. It falls back to the GitHub API only when the Git query is unavailable, downloads from GitHub's codeload host, validates every package, and copies the complete package set plus a standalone worker to `%LOCALAPPDATA%\puc-config\updates\<task-id>`. It returns a manifest and worker path without changing installed packages.

The PUC Toolkit GUI automatically starts the staged worker and closes itself. The worker waits for that exact GUI PID to exit, then backs up and replaces every package as one transaction, including `puc-config` and `puc-toolkit-updater`. It writes `update-state.json` only after all package validation succeeds. Any failure removes new targets, restores all backups, writes `update-result.json`, and relaunches the restored GUI. It never terminates other processes.

The relaunched GUI consumes `update-result.json` once and displays the final success or failure in `执行摘要`.
