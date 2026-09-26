#!/usr/bin/env bash
# scan.sh — ai-disclosure-crosscheck core scanner.
#
# Implements the 3-signal cross-check defined in
# biz-dev/initiatives/n14-cross-repo-ai-disclosure-linter-spec-2026-09.md
# section 2: signal A (server-side AI provider call), signal B (client-side
# UI disclosure of the provider name) and signal C (public policy document
# disclosure), reconciled through the PASS/WARN/FAIL matrix in section 2-3.
#
# Requirements: bash, grep, find only (spec 3-5) — no jq/python3/node
# dependency for the core scan. bin/cli.js is a thin npx wrapper around this
# script; it is not required to run it directly.
#
# Usage:
#   scan.sh --client-dir <path> --server-dir <path> [--policy-file <path>]
#           [--format text|json] [--fail-on warn|fail] [--config <path>]
#
# Exit codes: 0 ok, 1 verdict at or past --fail-on, 64 bad usage,
# 70 environment error (same convention as appstore-precheck, spec 3-3).

set -u

# Guard against an inherited shell function shadowing the real grep/find
# binaries (can happen when this script is sourced from an interactive shell
# environment that exports such functions). Bypassing that keeps the scan's
# regex behavior tied to the real GNU/BSD grep/find on PATH, not whatever a
# caller's shell profile has aliased them to.
grep() { command grep "$@"; }
find() { command find "$@"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prune.sh
. "$SCRIPT_DIR/lib/prune.sh"
# shellcheck source=lib/findings.sh
. "$SCRIPT_DIR/lib/findings.sh"
# shellcheck source=lib/suppress.sh
. "$SCRIPT_DIR/lib/suppress.sh"

TOOL_NAME="ai-disclosure-crosscheck"
: "${AI_DISCLOSURE_CROSSCHECK_VERSION:=0.1.0}"
PROVIDERS_FILE="$SCRIPT_DIR/lib/providers.conf"

CLIENT_DIR=""
SERVER_DIR=""
POLICY_FILE=""
POLICY_GIVEN="false"
FORMAT="text"
FAIL_ON="fail"
CONFIG_PATH=""

usage() {
  cat <<'EOF'
ai-disclosure-crosscheck — cross-repo AI disclosure linter (client x server x policy)

Usage:
  scan.sh --client-dir <path> --server-dir <path> [--policy-file <path>]
          [--format text|json] [--fail-on warn|fail] [--config <path>]

Options:
  --client-dir <path>   Client/UI source directory (required, or via --config)
  --server-dir <path>   Server source directory with the AI API call (required, or via --config)
  --policy-file <path>  Public privacy-policy document (HTML/Markdown), optional
  --format <fmt>        text (default) or json
  --fail-on <level>     warn or fail (default: fail) — exit 1 at or past this severity
  --config <path>       Path to a .ai-disclosure-crosscheck.json config (default:
                         ./.ai-disclosure-crosscheck.json if present)
  -h, --help            Show this help and exit
  -v, --version         Print the version and exit

Exit codes: 0 ok, 1 verdict at or past --fail-on, 64 bad usage, 70 environment error.
EOF
}

fail_usage() { printf 'scan.sh: %s\n' "$1" >&2; exit 64; }
fail_env()   { printf 'scan.sh: %s\n' "$1" >&2; exit 70; }

# _json_get_string <file> <key> -> value of a flat top-level "key": "value" pair,
# or empty. Deliberately naive (no nested objects) to avoid a jq dependency
# (spec 3-5); sufficient for the 3 flat path fields this config supports.
_json_get_string() {
  local file="$1" key="$2"
  grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
    | head -1 | sed -E 's/.*:[[:space:]]*"//; s/"$//'
}

load_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 0
  local v
  v="$(_json_get_string "$cfg" clientDir)"; [[ -n "$v" ]] && : "${CLIENT_DIR:=$v}"
  v="$(_json_get_string "$cfg" serverDir)"; [[ -n "$v" ]] && : "${SERVER_DIR:=$v}"
  v="$(_json_get_string "$cfg" policyFile)"; [[ -n "$v" ]] && : "${POLICY_FILE:=$v}"
}

# --- argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-dir)
      [[ $# -ge 2 ]] || fail_usage "--client-dir needs a path"
      CLIENT_DIR="$2"; shift 2 ;;
    --server-dir)
      [[ $# -ge 2 ]] || fail_usage "--server-dir needs a path"
      SERVER_DIR="$2"; shift 2 ;;
    --policy-file)
      [[ $# -ge 2 ]] || fail_usage "--policy-file needs a path"
      POLICY_FILE="$2"; POLICY_GIVEN="true"; shift 2 ;;
    --format)
      [[ $# -ge 2 ]] || fail_usage "--format needs a value (text|json)"
      FORMAT="$2"; shift 2 ;;
    --fail-on)
      [[ $# -ge 2 ]] || fail_usage "--fail-on needs a value (warn|fail)"
      FAIL_ON="$2"; shift 2 ;;
    --config)
      [[ $# -ge 2 ]] || fail_usage "--config needs a path"
      CONFIG_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -v|--version) printf '%s\n' "$AI_DISCLOSURE_CROSSCHECK_VERSION"; exit 0 ;;
    *) fail_usage "unknown option: $1 (try --help)" ;;
  esac
done

[[ "$FORMAT" == text || "$FORMAT" == json ]] || fail_usage "--format must be text or json"
[[ "$FAIL_ON" == warn || "$FAIL_ON" == fail ]] || fail_usage "--fail-on must be warn or fail"

# CLI-supplied CLIENT_DIR/SERVER_DIR/POLICY_FILE win over config; config only
# fills in what the CLI left empty (spec 3-1: config exists so CI does not
# need to repeat the same 3 paths every run).
if [[ -n "$CONFIG_PATH" ]]; then
  [[ -f "$CONFIG_PATH" ]] || fail_usage "--config file not found: $CONFIG_PATH"
  load_config "$CONFIG_PATH"
elif [[ -f ".ai-disclosure-crosscheck.json" ]]; then
  load_config ".ai-disclosure-crosscheck.json"
fi

[[ -n "$CLIENT_DIR" ]] || fail_usage "--client-dir is required (directly or via config)"
[[ -n "$SERVER_DIR" ]] || fail_usage "--server-dir is required (directly or via config)"
[[ -d "$CLIENT_DIR" ]] || fail_usage "--client-dir is not a directory: $CLIENT_DIR"
[[ -d "$SERVER_DIR" ]] || fail_usage "--server-dir is not a directory: $SERVER_DIR"
if [[ -n "$POLICY_FILE" ]]; then
  [[ -f "$POLICY_FILE" ]] || fail_usage "--policy-file is not a file: $POLICY_FILE"
fi
[[ -f "$PROVIDERS_FILE" ]] || fail_env "providers.conf is missing from the package"

FINDINGS_TMP="$(mktemp 2>/dev/null)" || fail_env "could not create a temp file for findings"
trap 'rm -f "$FINDINGS_TMP"' EXIT

load_precheck_ignore "."

# --- signal A: server-side AI provider call detection ------------------------
AI_PROVIDER=""
AI_SIG_FILE=""
while IFS=$'\t' read -r ai_pat ai_name; do
  [[ -z "$ai_pat" || "$ai_pat" == \#* ]] && continue
  # shellcheck disable=SC2086
  hit="$(grep -rlE "$ai_pat" "$SERVER_DIR" $(grep_prune_args) "${SERVER_INCLUDE_ARGS[@]}" 2>/dev/null | head -1)"
  if [[ -n "$hit" ]]; then
    AI_PROVIDER="$ai_name"
    AI_SIG_FILE="$hit"
    break
  fi
done < "$PROVIDERS_FILE"

emit_no_signal_note() {
  [[ "$FORMAT" == text ]] && printf 'INFO: no AI provider call pattern detected under --server-dir; rule "%s" did not fire (spec table row 1 — same behavior as appstore-precheck when ai_provider is empty).\n' "$RULE_ID"
}

if [[ -z "$AI_PROVIDER" ]]; then
  emit_no_signal_note
  if [[ "$FORMAT" == json ]]; then
    render_json "$TOOL_NAME" "$AI_DISCLOSURE_CROSSCHECK_VERSION"
  fi
  exit 0
fi

# --- signal B: client-side UI disclosure detection ---------------------------
CLIENT_EVIDENCE=""
# shellcheck disable=SC2086
b_hit="$(grep -rniE "\"[^\"]*${AI_PROVIDER}[^\"]*\"" "$CLIENT_DIR" $(grep_prune_args) "${CLIENT_INCLUDE_ARGS[@]}" 2>/dev/null \
  | grep -v '://' | head -1)"
if [[ -n "$b_hit" ]]; then
  CLIENT_EVIDENCE="${b_hit%%:*}:$(printf '%s' "$b_hit" | cut -d: -f2)"
else
  # shellcheck disable=SC2086
  xc_hit="$(grep -rliE "$AI_PROVIDER" --include=*.xcstrings $(grep_prune_args) "$CLIENT_DIR" 2>/dev/null | head -1)"
  [[ -n "$xc_hit" ]] && CLIENT_EVIDENCE="${xc_hit}:1"
fi

# --- signal C: policy document disclosure detection --------------------------
POLICY_EVIDENCE=""
if [[ -n "$POLICY_FILE" ]]; then
  # 1) Segment the document into block/sentence-scoped lines: break at
  #    block-level closing tags and <br>, strip remaining tags, then split on
  #    the Japanese sentence terminator so "same block" in the spec (2-2,
  #    signal C: "同一文・同一<li>/<p>等のブロック内") maps to one grep line.
  # 2) A hit needs the AI-keyword pattern (case-sensitive; "AI" is bounded by
  #    non-letter chars on both sides so it doesn't match inside ordinary
  #    English words like "email" or "detail") AND the provider name
  #    (case-insensitive) on the SAME resulting line.
  segmented="$(sed -E 's#</(p|li|div|section|td|tr|blockquote|h1|h2|h3|h4|h5|h6)>#\n#g; s#<br[^>]*>#\n#g' "$POLICY_FILE" \
    | sed -E 's/<[^>]+>//g' \
    | sed 's/。/。\n/g' \
    | sed '/^[[:space:]]*$/d')"
  ai_kw_hit="$(printf '%s\n' "$segmented" | grep -nE '(^|[^A-Za-z])AI([^A-Za-z]|$)|人工知能|機械学習')"
  if [[ -n "$ai_kw_hit" ]]; then
    c_hit="$(printf '%s\n' "$ai_kw_hit" | grep -iE "$AI_PROVIDER" | head -1)"
    if [[ -n "$c_hit" ]]; then
      c_line="${c_hit%%:*}"
      POLICY_EVIDENCE="${POLICY_FILE}:${c_line}"
    fi
  fi
fi

# --- matrix judgement (spec section 2-3) --------------------------------------
GUIDELINE="5.1.1 / 5.1.2(i)"
SEVERITY=""
MESSAGE=""

if [[ -n "$CLIENT_EVIDENCE" ]]; then
  SEVERITY="pass"
  MESSAGE="${AI_PROVIDER} endpoint/SDK present in --server-dir ($AI_SIG_FILE) and the provider is named in a client-facing string under --client-dir; consent screen naming is present for this signal's scope."
elif [[ -n "$POLICY_EVIDENCE" ]]; then
  SEVERITY="warn"
  MESSAGE="${AI_PROVIDER} endpoint/SDK present in --server-dir ($AI_SIG_FILE); the public policy document discloses ${AI_PROVIDER}, but no client-facing string under --client-dir names the provider. Apple 5.1.1/5.1.2(i) 2026 review practice may treat policy-only disclosure as insufficient without an in-app consent screen naming the provider."
elif [[ "$POLICY_GIVEN" == "true" ]]; then
  SEVERITY="fail"
  MESSAGE="${AI_PROVIDER} endpoint/SDK present in --server-dir ($AI_SIG_FILE); neither --client-dir (user-facing strings/xcstrings) nor --policy-file discloses the provider name. No consent surface names ${AI_PROVIDER} before data is sent."
else
  SEVERITY="warn"
  MESSAGE="${AI_PROVIDER} endpoint/SDK present in --server-dir ($AI_SIG_FILE); no client-facing disclosure was found under --client-dir, and --policy-file was not supplied so the public policy could not be checked. Re-run with --policy-file to get a definitive PASS/FAIL."
fi

SUPPRESSED="false"
if is_suppressed "$RULE_ID" "$AI_SIG_FILE"; then
  SUPPRESSED="true"
fi

_record "$SEVERITY" "$RULE_ID" "$GUIDELINE" "$MESSAGE" "$SUPPRESSED" \
  "${AI_SIG_FILE}" "${CLIENT_EVIDENCE}" "${POLICY_EVIDENCE}" "${AI_PROVIDER}"

# --- output -------------------------------------------------------------------
if [[ "$FORMAT" == json ]]; then
  render_json "$TOOL_NAME" "$AI_DISCLOSURE_CROSSCHECK_VERSION"
else
  tag="$(printf '%s' "$SEVERITY" | tr '[:lower:]' '[:upper:]')"
  if [[ "$SUPPRESSED" == "true" ]]; then
    printf '%s: %s — %s (suppressed via .precheck-ignore)\n' "$tag" "$RULE_ID" "$MESSAGE"
  else
    printf '%s: %s — %s\n' "$tag" "$RULE_ID" "$MESSAGE"
  fi
  [[ -n "$CLIENT_EVIDENCE" ]] && printf '      client evidence: %s\n' "$CLIENT_EVIDENCE"
  [[ -n "$POLICY_EVIDENCE" ]] && printf '      policy evidence: %s\n' "$POLICY_EVIDENCE"
  printf '      server evidence: %s\n' "$AI_SIG_FILE"
  printf 'SUMMARY: fail=%d warn=%d pass=%d suppressed=%d\n' \
    "$([[ $SEVERITY == fail && $SUPPRESSED == false ]] && echo 1 || echo 0)" \
    "$([[ $SEVERITY == warn && $SUPPRESSED == false ]] && echo 1 || echo 0)" \
    "$([[ $SEVERITY == pass && $SUPPRESSED == false ]] && echo 1 || echo 0)" \
    "$([[ $SUPPRESSED == true ]] && echo 1 || echo 0)"
fi

# --- exit code (spec 3-3) -----------------------------------------------------
[[ "$SUPPRESSED" == "true" ]] && exit 0
if [[ "$FAIL_ON" == warn ]]; then
  [[ "$SEVERITY" == warn || "$SEVERITY" == fail ]] && exit 1
else
  [[ "$SEVERITY" == fail ]] && exit 1
fi
exit 0
