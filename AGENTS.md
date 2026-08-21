# AGENTS.md

## Scope

This file applies to the entire repository.

## Guidelines

- Read the relevant project documentation before making changes.
- Keep changes focused on the requested task.
- Preserve existing code style and repository conventions.
- Run relevant checks or tests after modifying code.
- Do not overwrite unrelated user changes.
- If a subdirectory contains its own `AGENTS.md`, follow the more specific instructions there.

## Skills and Repository Structure

- Avoid using `superpowers:brainstorming` unless it is genuinely necessary for the task.
- Respect `.gitignore` and never bypass it to force-add ignored files or directories.
- Do not force-add the root `docs` directory; it is intentionally ignored.
- Support skill packages as top-level repository entries when required by the task.
- Do not create unnecessary directories or placeholder folder structures.

## Git Conventions

- Use standard Git workflows and follow Conventional Commits for commit messages.
- Write all commit messages in English.
- When synchronizing code causes conflicts between feature changes, understand both sides and preserve the functionality of each side whenever possible; verify the merged behavior after resolving the conflict.
- Never force-push. The use of `git push --force`, `git push -f`, `git push --force-with-lease`, or any equivalent force-push operation is prohibited.
