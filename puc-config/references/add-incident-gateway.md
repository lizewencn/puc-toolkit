# Add the incident gateway

Use `scripts/Invoke-PucIncidentGateway.ps1` to add the fixed `3rdwx` Wuxi police-incident gateway to one exact environment.

## Preflight

Run the authenticated dry run first:

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucIncidentGateway.ps1 `
  -Environment <environment> `
  -DryRun
```

`-ServicePort` is optional, accepts `1` through `65535`, and defaults to `17060`. For a custom port, add `-ServicePort <port>` to both dry-run and live commands. Use that same value in all three related fields: `system_url` is `http://<environment-ip>:<port>`, `local_tcp_port` is the numeric port, and `audio_file_url` is `http://<environment-ip>:<port>/api/bps/alarm/getZfzy`.

The script performs these checks without writing:

1. Query every page of `sap_list_request`. If any `sap_base_list` item has `sap_alias` equal to `3rdwx` (case-insensitive after trimming), return `status: already-exists`, tell the user the gateway already exists, and stop.
2. Query `system_list_request` and require exactly one item whose `system_id` is numerically or textually equal to `298`. The alias is irrelevant. With no match, stop with `新增所属系统列表中不存在 298 警情相关类型`. With multiple matches, stop as ambiguous. Preserve the matched record's original `system_id` JSON type and use that exact returned value in both the top-level `system_id` and `sap_list[].system_id`; do not reconstruct it as the string `"298"`. Use the current authenticated environment's PUC ID in both locations, matching the frontend add flow.
3. GET `/nmpuc/gateway/getConfig` with the saved token. In the SAP rule whose value is `97`, require the base `gateway_type` option whose value is `18` and whose label identifies Wuxi police incidents. With no match, stop with `新增网关类型列表中不存在警情相关类型`.
4. Derive the dynamic environment IP from the selected environment's `baseUrl` host. It must be an IP address. Use it for every field represented by `10.161.30.93` in the fixed template; retain the original URL schemes, ports, paths, and other fixed values.

Show the exact environment, derived IP, selected service port, alias, system ID, gateway type, fixed endpoint values, redacted request preview, and `snapshotHash`. Password and secret fields must remain redacted. Include the selected service port in the snapshot so changing it after preflight invalidates live execution. The user's explicit request to add this one fixed gateway in one exact environment is business confirmation; after a successful preflight, proceed without asking again.

## Execute

```powershell
<skill>\scripts\Invoke-PucScript.cmd Invoke-PucIncidentGateway.ps1 `
  -Environment <environment> `
  -Live `
  -ConfirmLive `
  -ExpectedSnapshotHash <hash>
```

When dry-run used a custom `-ServicePort`, live mode must receive the same `-ServicePort`; otherwise snapshot validation fails before the write.

Live mode repeats all lookups and refuses to write if the snapshot changed. It generates new outer SAP, inner SAP, and inner record GUIDs, then sends `add_sap` exactly once. Never retry this create request.

After a successful create response, query `sap_list_request` once more and require exactly one `3rdwx` record with SAP type `97`, system `298`, gateway type `18`, the selected environment IP and service port, and the expected nested endpoint values. If verification is missing or inconsistent, report the uncertain result and do not retry or create another gateway.
