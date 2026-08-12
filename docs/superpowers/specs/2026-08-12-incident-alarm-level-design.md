# Incident Alarm Level Configuration Design

## Goal

Extend `puc-config` so a request to configure incident alarm levels prepares and creates one fixed five-level configuration in one exact PUC environment.

## Fixed Configuration

| Code | Name | Color | Preferred ZIP | Fallback ZIP | Tone |
|---|---|---|---|---|---|
| `00` | `星标` | `#E56659` | `星标.zip` | `普通.zip` | `CriticalAlarm.wav` |
| `01` | `黄标` | `#eba54d` | `黄标.zip` | `普通.zip` | `MediumAlarm.wav` |
| `02` | `普通` | `#eba54d` | `普通.zip` | `普通.zip` | `MediumAlarm.wav` |
| `03` | `预警` | `#73cb6d` | `预警.zip` | `普通.zip` | `CommonlyAlarm.wav` |
| `04` | `指令` | `#73cb6d` | `指令.zip` | `普通.zip` | `CommonlyAlarm.wav` |

Generate each description as `<name>警情等级说明`. Resolve ZIP files relative to `puc-config/assets/incident`. Use the preferred same-name ZIP when it exists; otherwise use `普通.zip`. Refuse to proceed if the selected file does not exist, is empty, is not a valid ZIP, or contains an unsafe path.

## Verified API Contract

Use the authenticated `POST /confs` endpoint.

Read available tones with `query_alert_tone`. Read existing levels with `taskmgr_query_police_incident_alarm_level`, using `page_number`, `page_size`, and `is_icon_list`. Treat top-level `result: 0` with a null `alarm_level_list` as an empty successful list.

Create a level with `multipart/form-data` and these parts:

- `icon_zip_file`: selected ZIP bytes
- `cmd_guid`: a new GUID per request
- `cmd_name`: `taskmgr_add_police_incident_alarm_level`
- `puc_id`, `realm`, `user_id`: selected environment and administrator values
- `level_code`, `level_name`, `level_desc`, `icon_color`
- `icon_zip_name`: selected ZIP file name
- `tone_id`: exact returned `file_name`

Success requires HTTP success and top-level `result: 0`. The observed acknowledgement is `taskmgr_add_police_incident_alarm_level_ack`, but success must remain governed by `result`.

## Skill Surface

Add `scripts/Invoke-PucIncidentAlarmLevels.ps1` with:

```powershell
-Environment <name> -DryRun
-Environment <name> -Live -ConfirmLive -ExpectedPreviewHash <hash>
```

Also support `-PlanOnly` and optional `-ConfigRoot`, matching existing skill conventions. The fixed five-level mapping is internal and not exposed as arbitrary user parameters.

Add `references/incident-alarm-levels.md` and route requests such as "配置警情等级" or "新增警情等级" from `SKILL.md` to that reference plus `references/login.md`.

## Preflight

Authenticate with the shared saved-token workflow. Before any write:

1. Validate all five fixed definitions and resolve all five ZIP selections.
2. Validate ZIP structure without extracting it. Reject absolute paths, parent traversal, directories-only archives, and unsupported or empty file content.
3. Query every available tone page and require each configured tone name to match exactly once.
4. Query every existing alarm-level page. Bound pagination by returned page metadata and reject inconsistent pagination.
5. Compare codes and names case-sensitively against the fixed configuration.

Classify each desired item:

- `unchanged`: both code and name resolve to the same existing record and its name, code, normalized color, ZIP name, and tone file name equal the target. Skip it and continue.
- `missing`: neither its code nor name exists. Prepare one create request.
- `conflict`: its code or name exists but does not describe the same target record and values. Stop the complete batch before writing anything. Never update or overwrite it.

The dry run returns the environment, all five items, resolved ZIP paths and SHA-256 hashes, tone names, classifications, write count, and a deterministic preview hash. Do not expose tokens, full server records, icon contents, or request bodies.

## Confirmation And Writes

Require the user to confirm the displayed environment, five-item summary, and preview hash. Live mode repeats the complete authenticated preflight and refuses to write unless the new hash equals `ExpectedPreviewHash`.

Create missing levels in code order `00` through `04`. Send each create request exactly once. On a failed or uncertain response, stop immediately; do not attempt later items and do not retry the failed item. Report already-created, skipped, failed, and not-attempted items separately.

After all writes succeed, query the complete level list once. Require every desired item to be present and unchanged according to the same comparison rules. If verification is incomplete, report the write results and verification failure without retrying creation.

## Multipart And Encoding

Use .NET `HttpClient` and `MultipartFormDataContent` for Windows PowerShell compatibility. Add the selected token only as the request header. Encode text parts as UTF-8 and preserve non-ASCII file names through a standards-compliant content disposition. Stream or read each ZIP only for its single request and dispose all streams and HTTP content deterministically.

Do not route multipart requests through `ConvertTo-PucJsonBytes`; that helper applies only to JSON bodies. Continue to pass decoded JSON responses through `ConvertFrom-PucResponseEncoding`.

## Tests

Add offline PowerShell tests or a test harness with a local fake HTTP endpoint. Cover:

- the exact five fixed definitions and tone mapping
- preferred ZIP selection and `普通.zip` fallback
- invalid, empty, and unsafe ZIP rejection
- null successful lists normalized to empty
- unchanged items skipped while missing items continue
- duplicate code, duplicate name, and mismatched values stop before writes
- exact tone lookup and missing or duplicate tone rejection
- deterministic preview hash and live snapshot mismatch rejection
- multipart part names, UTF-8 values, file name, and ZIP bytes
- one request per missing item, ordered writes, stop-on-first-failure, and no retry
- post-write verification and sanitized output

Do not use the supplied HAR as a committed fixture because it contains environment authentication material. Build sanitized synthetic fixtures instead.
