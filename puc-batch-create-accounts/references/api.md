# PUC Account API Adapter

`adapter.json` defines login, account search, authorization lookups, and account creation operations for the PUC command API. It contains no deployment address; `puc-config-manager` injects the configured server URL at runtime.

Account-specific inputs belong in `../module_config.json`. Do not add server IP, port, administrator credentials, or token values to this module.

Use `../scripts/Test-PucAccountModule.ps1` after changing the adapter or module configuration.
