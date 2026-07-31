# PUC Account API Adapter

`adapter.json` defines login, account search, authorization lookups, and account creation operations for the PUC command API. It contains no deployment address; `puc-config-manager` injects the configured server URL at runtime.

Account-specific inputs belong in `../module_config.json`. Do not add server IP, port, administrator credentials, or token values to this module.

Discover the deployment PUC ID with `common_cfg_request` before login. The manager owns this value with the token and injects it into every enabled module; never hard-code a server-specific PUC ID.

Include both the discovered PUC ID and realm in `role_request`; current deployments may return an empty role list when realm is omitted.

Generate a new account GUID for every create request; never reuse a GUID captured from HAR.

Use `../scripts/Test-PucAccountModule.ps1` after changing the adapter or module configuration.

Empty system, access-point, device-organization, and address-book-organization lists are valid when the deployment has none of those resources. Send the corresponding empty authorization values. When a list is non-empty, still require the configured root organization and reject entries whose configured ID field is missing or blank.

Treat the configured highest-role name as a preference. If matching roles exist, select the unique match with the most enabled permissions. Otherwise, select the unique returned role with the most enabled permissions across the deployment. Send the selected role's actual name and ID, and reject a tie. Do not filter by `enable_flag`; deployments differ in its semantics while still exposing those roles as selectable in the web UI.
