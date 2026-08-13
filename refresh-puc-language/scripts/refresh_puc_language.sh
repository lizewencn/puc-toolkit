#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE="${NAMESPACE:-}"
POD="${POD:-}"
LOCALE_PATH="${LOCALE_PATH:-}"
PATTERN="${LOCALE_PATTERN:-locale}"
APPLY=0
YES=0

usage() {
  cat <<'USAGE'
Usage:
  refresh_puc_language.sh [--namespace <ns>] [--pod <pod>] [--path <locale-path>] [--pattern <text>] [--apply] [--yes]

Defaults to dry run. Add --apply to delete the locale directory and delete the nmnginx pod.

Options:
  -n, --namespace <ns>   Kubernetes namespace. If omitted, exact namespace "puc" is used only when present.
  --pod <pod>            nmnginx pod name. If omitted, exactly one running nmnginx-* pod is auto-selected.
  --path <path>          Locale directory path. If omitted, extracted from kubectl describe output.
  --pattern <text>       grep pattern for describe output. Default: locale.
  --apply                Perform rm -rf and kubectl delete pod.
  --yes                  Skip interactive confirmation. Use only after reviewing dry-run output.
  -h, --help             Show this help.
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
    -n|--namespace)
      [ "$#" -ge 2 ] || die "missing value for $1"
      NAMESPACE="$2"
      shift 2
      ;;
    --pod)
      [ "$#" -ge 2 ] || die "missing value for --pod"
      POD="$2"
      shift 2
      ;;
    --path)
      [ "$#" -ge 2 ] || die "missing value for --path"
      LOCALE_PATH="$2"
      shift 2
      ;;
    --pattern)
      [ "$#" -ge 2 ] || die "missing value for --pattern"
      PATTERN="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --yes)
      YES=1
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

command -v "$KUBECTL" >/dev/null 2>&1 || die "kubectl was not found in PATH"

select_namespace() {
  local ns_list
  ns_list="$("$KUBECTL" get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  [ -n "$ns_list" ] || die "failed to list namespaces with kubectl get ns"

  if printf '%s\n' "$ns_list" | grep -Fxq 'puc'; then
    NAMESPACE='puc'
    return
  fi

  info "No exact namespace named 'puc' was found."
  info "Available namespaces:"
  printf '%s\n' "$ns_list" | sed 's/^/  /'
  die "rerun with --namespace <namespace>"
}

select_pod() {
  local pods running count
  pods="$("$KUBECTL" get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null || true)"
  [ -n "$pods" ] || die "failed to list pods in namespace $NAMESPACE"

  running="$(printf '%s\n' "$pods" | awk '$1 ~ /^nmnginx-/ && $2 == "Running" {print $1}')"
  count="$(printf '%s\n' "$running" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "$count" = "1" ]; then
    POD="$(printf '%s\n' "$running" | sed -n '1p')"
    return
  fi

  info "Could not auto-select exactly one running nmnginx-* pod in namespace $NAMESPACE."
  info "Matching pods:"
  printf '%s\n' "$pods" | awk '$1 ~ /^nmnginx-/ {printf "  %s\t%s\n", $1, $2}'
  die "rerun with --pod <pod-name>"
}

extract_locale_path() {
  local describe matches paths count
  describe="$("$KUBECTL" describe pod -n "$NAMESPACE" "$POD")"
  matches="$(printf '%s\n' "$describe" | grep -i -- "$PATTERN" || true)"

  [ -n "$matches" ] || die "no lines matching '$PATTERN' found in kubectl describe output"

  info "Matched locale lines from kubectl describe:"
  printf '%s\n' "$matches" | sed 's/^/  /'

  if [ -n "$LOCALE_PATH" ]; then
    return
  fi

  paths="$(
    printf '%s\n' "$matches" |
      grep -Eoi '/[^[:space:],;")'\'']*locale[^[:space:],;")'\'']*' |
      sed 's/[[:space:],;")'\'']*$//' |
      sort -u
  )"

  count="$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "$count" = "1" ]; then
    LOCALE_PATH="$(printf '%s\n' "$paths" | sed -n '1p')"
    return
  fi

  info "Could not auto-select exactly one locale path."
  if [ -n "$paths" ]; then
    info "Candidate paths:"
    printf '%s\n' "$paths" | sed 's/^/  /'
  fi
  die "rerun with --path <absolute-locale-path>"
}

path_depth() {
  printf '%s\n' "$1" | awk -F/ '{count=0; for (i=1; i<=NF; i++) if ($i != "") count++; print count}'
}

validate_locale_path() {
  local lower depth
  [ -n "$LOCALE_PATH" ] || die "locale path is empty"

  case "$LOCALE_PATH" in
    /*) ;;
    *) die "locale path must be absolute: $LOCALE_PATH" ;;
  esac

  case "$LOCALE_PATH" in
    *$'\n'*|*$'\r'*|*\**|*\?*|*\[*|*\]*)
      die "locale path contains unsafe characters: $LOCALE_PATH"
      ;;
  esac

  lower="$(printf '%s' "$LOCALE_PATH" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *locale*) ;;
    *) die "locale path must contain 'locale': $LOCALE_PATH" ;;
  esac

  case "$LOCALE_PATH" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var)
      die "refusing to delete a root/system directory: $LOCALE_PATH"
      ;;
  esac

  depth="$(path_depth "$LOCALE_PATH")"
  [ "$depth" -ge 3 ] || die "refusing to delete a shallow path: $LOCALE_PATH"
}

confirm_apply() {
  [ "$APPLY" = "1" ] || return
  [ "$YES" = "1" ] && return

  if [ ! -t 0 ]; then
    die "non-interactive apply requires --yes after a reviewed dry run"
  fi

  printf 'Type DELETE to remove "%s" and delete pod "%s": ' "$LOCALE_PATH" "$POD" >&2
  read -r answer
  [ "$answer" = "DELETE" ] || die "confirmation did not match"
}

if [ -z "$NAMESPACE" ]; then
  select_namespace
fi

if [ -z "$POD" ]; then
  select_pod
fi

extract_locale_path
validate_locale_path

info ""
info "Refresh target:"
info "  namespace: $NAMESPACE"
info "  pod:       $POD"
info "  path:      $LOCALE_PATH"
info ""
info "Planned commands:"
info "  rm -rf -- '$LOCALE_PATH'"
info "  $KUBECTL delete pod -n '$NAMESPACE' '$POD'"
info ""

if [ "$APPLY" != "1" ]; then
  info "Dry run only. Rerun with --apply after confirming the target."
  exit 0
fi

confirm_apply

rm -rf -- "$LOCALE_PATH"
"$KUBECTL" delete pod -n "$NAMESPACE" "$POD"
info "Locale directory removed and pod delete requested."
