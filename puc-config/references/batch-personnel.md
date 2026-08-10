# Batch personnel child workflow

Use `scripts/Invoke-PucPersonnel.ps1`. Authentication is shared through the token saved in the selected `config.json` environment.

## Inputs

Resolve these per batch instead of persisting them in `config.json`: exact environment, personnel type GUID, optional exact root address-book organization name, and either an alias prefix with sequence/count or one exact personnel alias. An exact personnel alias may include one exact dispatcher account to bind during creation.

The target IP suffix remains part of generated personnel identifiers to preserve the existing deployment convention. Require an explicit personnel type GUID until the API contract provides a safe unique lookup.

## Execute

1. Validate the saved token with the login workflow. Reauthenticate if rejected.
2. Run authenticated dry run with `-DryRun`.
3. For dispatcher binding, require exactly one account-list match and use its alias to build `dispatcher_name` as `<alias>(<account>)`. Do not reject the request from an account-list binding field; let the single create response determine whether the server accepts the binding.
4. Show aliases, identifiers, dispatcher account, duplicate skips, organization, and count.
5. Require explicit confirmation of the environment, count, and dispatcher account when present.
6. Run the same arguments with `-Live -ConfirmLive`.

For one exact alias, send the minimal `conf_add_personnel_info_req`: omit organization, generated identifier, ID number, and mobile fields. Use `Police:1` only when the user selected the standard police personnel type or an existing confirmed workflow already established it. Never retry a personnel create request, including a binding conflict. Stop on the first failed or uncertain response.
