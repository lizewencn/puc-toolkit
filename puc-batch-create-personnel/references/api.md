# PUC Personnel API Adapter

`adapter.json` defines login, organization lookup, personnel search, and personnel creation operations for the PUC command API. It contains no deployment address; `puc-config-manager` injects the configured server URL at runtime.

Personnel-specific inputs belong in `../module_config.json`. Do not add server IP, port, administrator credentials, or token values to this module.

Use `../scripts/Test-PucPersonnelModule.ps1` after changing the adapter or module configuration.
