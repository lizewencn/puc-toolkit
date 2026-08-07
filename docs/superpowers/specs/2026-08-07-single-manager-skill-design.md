# Single Manager Skill Design

## Goal

Publish and install PUC configuration management as one discoverable Codex Skill named `puc-config-manager`. Account and personnel creation remain independently configurable modules, but no longer appear as sibling Skills.

## Selected Architecture

Use one Skill with internal modules:

```text
puc-config-manager/
|-- SKILL.md
|-- agents/
|-- PucConfigManager.cmd
|-- manager_config.example.json
|-- modules.json
|-- scripts/
|-- modules/
|   |-- accounts/
|   |   |-- module_config.example.json
|   |   |-- references/
|   |   `-- scripts/
|   `-- personnel/
|       |-- module_config.example.json
|       |-- references/
|       `-- scripts/
`-- reports/                  # local and ignored
```

Only the root `puc-config-manager/SKILL.md` and `agents/openai.yaml` provide Skill discovery metadata. Internal modules contain executable scripts, API references, adapters, examples, and tests, but no nested `SKILL.md` or agent metadata.

This layout is preferred over three sibling Skills because authentication, token ownership, run mode, ordering, and reports are manager concerns. The modules remain isolated by their manifest entries and local configuration files, so future functions can be added without enlarging the public Skill surface.

## Configuration Ownership

The installed local files are:

- `puc-config-manager/manager_config.json`: connection, administrator credentials, TLS policy, realm, and shared run mode.
- `puc-config-manager/modules/accounts/module_config.json`: account generation and authorization rules.
- `puc-config-manager/modules/personnel/module_config.json`: personnel generation and organization rules.

The repository contains only corresponding `*.example.json` files. Real local configuration, reports, HAR captures, tokens, and credentials remain ignored and must not be committed.

The public command remains parameterless. `PucConfigManager.cmd` loads the manager configuration, logs in once for authenticated modes, discovers shared runtime context, and invokes enabled modules in `modules.json` order.

## Installation And Migration

`Install-PucToolkit.ps1` installs only the `puc-config-manager` directory. It preserves any configuration already present at the new internal paths.

For the first installation of the consolidated layout, the installer checks the former sibling installation paths. If an old account or personnel `module_config.json` exists and the new destination does not, the installer copies that file into the new internal module path. If neither exists, it creates the local file from the sanitized example.

The installer does not delete `puc-batch-create-accounts` or `puc-batch-create-personnel`. It reports them as legacy directories so the user can remove them after validating the consolidated installation. This avoids destructive handling of sensitive local configuration.

## Manifest And Runtime Paths

`puc-config-manager/modules.json` changes all module paths from sibling-relative locations to manager-relative locations under `modules/accounts` and `modules/personnel`. Report paths remain under the manager's ignored `reports` directory.

Module scripts continue receiving runtime values through temporary generated JSON and environment variables. No module gains administrator credentials or independent login behavior.

## Compatibility

The API adapters, module scripts, configuration schemas, duplicate checks, and request behavior do not change as part of this refactor. Existing local module configuration content remains valid after migration because only its filesystem location changes.

The legacy sibling directories are no longer updated by the installer and are not referenced by the new manager manifest. Repository consumers must rerun the installer after pulling the structural change.

## Error Handling

Installation stops on copy or JSON path errors. It never overwrites an existing local configuration with an example or legacy copy. If both a new and a legacy configuration exist, the new location wins and the installer reports that it preserved it.

At runtime, existing manager validation remains authoritative: invalid shared configuration, no enabled modules, authentication failure, missing module files, or module errors stop execution with the current error behavior.

## Verification

Verification covers:

1. Repository layout contains one top-level Skill and no nested module Skill metadata.
2. Every path declared by `modules.json` resolves inside `puc-config-manager`.
3. Account and personnel module tests pass from their new locations.
4. A temporary installation preserves new-path configurations, migrates legacy configurations when needed, and creates examples only when no local configuration exists.
5. PowerShell files parse successfully and JSON files deserialize successfully.
6. `Test-RepositorySafety.ps1` passes with the new paths and still rejects sensitive local files.

## Scope

This change restructures packaging and installation only. It does not add workflow visualization, new PUC operations, automatic legacy-directory deletion, API contract changes, or live server requests.
