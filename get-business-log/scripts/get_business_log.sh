#!/usr/bin/env bash
set -euo pipefail

LOG_DIR_NAME=""
ACCOUNT=""
START_TIME=""
END_TIME=""
BASE_DIR="${BASE_DIR:-/opt/logserver/log}"
BUSINESS_SUBDIR="${BUSINESS_SUBDIR:-business_0}"
REMOTE_OUTPUT_DIR="${REMOTE_OUTPUT_DIR:-/tmp/get-business-log}"
INCLUDE_GZ=0
INCLUDE_ZST=0

usage() {
  cat <<'USAGE'
Usage:
  get_business_log.sh --log-dir <name> --account <account> --start "YYYY-MM-DD HH:mm:ss" --end "YYYY-MM-DD HH:mm:ss" [options]

Options:
  --log-dir <name>           Directory used in /opt/logserver/log/<name>/business_0.
  --target-ip <name>         Backward-compatible alias for --log-dir.
  --log-ip <name>            Backward-compatible alias for --log-dir.
  --account <account>        Account text to match literally.
  --start <time>             Inclusive start time.
  --end <time>               Inclusive end time.
  --base-dir <path>          Log root. Default: /opt/logserver/log.
  --business-subdir <name>   Business log directory name. Default: business_0.
  --remote-output-dir <path> Remote temp output root. Default: /tmp/get-business-log.
  --include-gz               Also scan .gz log files with gzip -cd.
  --include-zst              Also scan .zst log files with zstdcat.
  --include-compressed       Also scan .gz and .zst log files.
  -h, --help                 Show this help.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --log-dir|--target-ip|--log-ip)
      [ "$#" -ge 2 ] || die "missing value for $1"
      LOG_DIR_NAME="$2"
      shift 2
      ;;
    --account)
      [ "$#" -ge 2 ] || die "missing value for --account"
      ACCOUNT="$2"
      shift 2
      ;;
    --start)
      [ "$#" -ge 2 ] || die "missing value for --start"
      START_TIME="$2"
      shift 2
      ;;
    --end)
      [ "$#" -ge 2 ] || die "missing value for --end"
      END_TIME="$2"
      shift 2
      ;;
    --base-dir)
      [ "$#" -ge 2 ] || die "missing value for --base-dir"
      BASE_DIR="$2"
      shift 2
      ;;
    --business-subdir)
      [ "$#" -ge 2 ] || die "missing value for --business-subdir"
      BUSINESS_SUBDIR="$2"
      shift 2
      ;;
    --remote-output-dir)
      [ "$#" -ge 2 ] || die "missing value for --remote-output-dir"
      REMOTE_OUTPUT_DIR="$2"
      shift 2
      ;;
    --include-gz)
      INCLUDE_GZ=1
      shift
      ;;
    --include-zst)
      INCLUDE_ZST=1
      shift
      ;;
    --include-compressed)
      INCLUDE_GZ=1
      INCLUDE_ZST=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$LOG_DIR_NAME" ] || die "--log-dir is required"
[ -n "$ACCOUNT" ] || die "--account is required"
[ -n "$START_TIME" ] || die "--start is required"
[ -n "$END_TIME" ] || die "--end is required"

case "$LOG_DIR_NAME" in
  *..*|*/*|*\\*|"") die "unsafe log directory name: $LOG_DIR_NAME" ;;
esac

case "$BUSINESS_SUBDIR" in
  *..*|*/*|*\\*|"") die "unsafe business subdir: $BUSINESS_SUBDIR" ;;
esac

case "$BASE_DIR" in
  /*) ;;
  *) die "--base-dir must be absolute: $BASE_DIR" ;;
esac

case "$REMOTE_OUTPUT_DIR" in
  /*) ;;
  *) die "--remote-output-dir must be absolute: $REMOTE_OUTPUT_DIR" ;;
esac

command -v awk >/dev/null 2>&1 || die "awk was not found in PATH"
command -v find >/dev/null 2>&1 || die "find was not found in PATH"
command -v tar >/dev/null 2>&1 || die "tar was not found in PATH"

if [ "$INCLUDE_GZ" = "1" ]; then
  command -v gzip >/dev/null 2>&1 || die "gzip was not found in PATH, required by --include-gz"
fi

if [ "$INCLUDE_ZST" = "1" ]; then
  command -v zstdcat >/dev/null 2>&1 || die "zstdcat was not found in PATH, required by --include-zst"
fi

normalize_time() {
  local value="$1"
  local normalized

  normalized="$(date -d "$value" '+%F %T' 2>/dev/null || true)"
  if [ -n "$normalized" ]; then
    printf '%s\n' "$normalized"
    return
  fi

  case "$value" in
    ????-??-??" "??:??:??|????/??/??" "??:??:??|????-??-??T??:??:??|????/??/??T??:??:??)
      printf '%s\n' "$value" | sed 's#/#-#g; s#T# #'
      ;;
    *)
      die "unsupported time format: $value"
      ;;
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

START_NORM="$(normalize_time "$START_TIME")"
END_NORM="$(normalize_time "$END_TIME")"
[ "$START_NORM" \< "$END_NORM" ] || [ "$START_NORM" = "$END_NORM" ] || die "start time must be before or equal to end time"

LOG_DIR="${BASE_DIR%/}/${LOG_DIR_NAME}/${BUSINESS_SUBDIR}"
[ -d "$LOG_DIR" ] || die "log directory not found: $LOG_DIR"

RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
WORK_DIR="${REMOTE_OUTPUT_DIR%/}/${LOG_DIR_NAME}_business_log_${RUN_ID}"
MATCHED_LOG="$WORK_DIR/matched.log"
SUMMARY_FILE="$WORK_DIR/summary.txt"
MANIFEST_FILE="$WORK_DIR/manifest.json"
SCAN_LIST="$WORK_DIR/scanned_files.txt"

mkdir -p "$WORK_DIR"
: > "$MATCHED_LOG"
: > "$SCAN_LIST"

files_scanned=0

scan_file() {
  local file="$1"
  local relative="${file#$LOG_DIR/}"

  files_scanned=$((files_scanned + 1))
  printf '%s\n' "$relative" >> "$SCAN_LIST"

  case "$file" in
    *.gz)
      [ "$INCLUDE_GZ" = "1" ] || return
      gzip -cd -- "$file" 2>/dev/null | awk -v account="$ACCOUNT" -v start="$START_NORM" -v end="$END_NORM" -v source="$relative" '
        function normalized_ts(value) {
          gsub(/\//, "-", value)
          gsub(/T/, " ", value)
          return substr(value, 1, 19)
        }
        function extracted_ts(line, value) {
          if (match(line, /[0-9]{4}[-\/][0-9]{2}[-\/][0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
            value = substr(line, RSTART, RLENGTH)
            return normalized_ts(value)
          }
          return ""
        }
        index($0, account) > 0 {
          ts = extracted_ts($0)
          if (ts >= start && ts <= end) {
            print "[" source "] " $0
          }
        }
      ' >> "$MATCHED_LOG"
      ;;
    *.zst)
      [ "$INCLUDE_ZST" = "1" ] || return
      zstdcat -- "$file" 2>/dev/null | awk -v account="$ACCOUNT" -v start="$START_NORM" -v end="$END_NORM" -v source="$relative" '
        function normalized_ts(value) {
          gsub(/\//, "-", value)
          gsub(/T/, " ", value)
          return substr(value, 1, 19)
        }
        function extracted_ts(line, value) {
          if (match(line, /[0-9]{4}[-\/][0-9]{2}[-\/][0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
            value = substr(line, RSTART, RLENGTH)
            return normalized_ts(value)
          }
          return ""
        }
        index($0, account) > 0 {
          ts = extracted_ts($0)
          if (ts >= start && ts <= end) {
            print "[" source "] " $0
          }
        }
      ' >> "$MATCHED_LOG"
      ;;
    *)
      awk -v account="$ACCOUNT" -v start="$START_NORM" -v end="$END_NORM" -v source="$relative" '
        function normalized_ts(value) {
          gsub(/\//, "-", value)
          gsub(/T/, " ", value)
          return substr(value, 1, 19)
        }
        function extracted_ts(line, value) {
          if (match(line, /[0-9]{4}[-\/][0-9]{2}[-\/][0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
            value = substr(line, RSTART, RLENGTH)
            return normalized_ts(value)
          }
          return ""
        }
        index($0, account) > 0 {
          ts = extracted_ts($0)
          if (ts >= start && ts <= end) {
            print "[" source "] " $0
          }
        }
      ' "$file" >> "$MATCHED_LOG" 2>/dev/null || true
      ;;
  esac
}

while IFS= read -r -d '' file; do
  case "$file" in
    *.gz)
      [ "$INCLUDE_GZ" = "1" ] && scan_file "$file"
      ;;
    *.zst)
      [ "$INCLUDE_ZST" = "1" ] && scan_file "$file"
      ;;
    *)
      scan_file "$file"
      ;;
  esac
done < <(find "$LOG_DIR" -type f -print0 | sort -z)

match_lines="$(wc -l < "$MATCHED_LOG" | tr -d ' ')"
archive_name="${LOG_DIR_NAME}_business_log_${RUN_ID}.tar.gz"
archive_path="${REMOTE_OUTPUT_DIR%/}/${archive_name}"

cat > "$SUMMARY_FILE" <<EOF_SUMMARY
Business log collection summary
Log service directory: $LOG_DIR_NAME
Log directory: $LOG_DIR
Account: $ACCOUNT
Start: $START_NORM
End: $END_NORM
Include gzip: $INCLUDE_GZ
Include zstd: $INCLUDE_ZST
Files scanned: $files_scanned
Matched lines: $match_lines
Generated at: $(date '+%F %T')
EOF_SUMMARY

cat > "$MANIFEST_FILE" <<EOF_MANIFEST
{
  "logDir": "$(json_escape "$LOG_DIR_NAME")",
  "logDirectory": "$(json_escape "$LOG_DIR")",
  "account": "$(json_escape "$ACCOUNT")",
  "start": "$(json_escape "$START_NORM")",
  "end": "$(json_escape "$END_NORM")",
  "includeGz": $INCLUDE_GZ,
  "includeZst": $INCLUDE_ZST,
  "filesScanned": $files_scanned,
  "matchedLines": $match_lines,
  "matchedLog": "matched.log",
  "summary": "summary.txt"
}
EOF_MANIFEST

tar -C "$REMOTE_OUTPUT_DIR" -czf "$archive_path" "$(basename "$WORK_DIR")"

info "Business log collection complete."
info "LOG_DIR_NAME=$LOG_DIR_NAME"
info "LOG_DIR=$LOG_DIR"
info "WORK_DIR=$WORK_DIR"
info "MATCHED_LINES=$match_lines"
info "ARCHIVE_PATH=$archive_path"
