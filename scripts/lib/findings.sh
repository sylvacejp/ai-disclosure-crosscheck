#!/usr/bin/env bash
# findings.sh — structured-findings buffer for scan.sh, no jq dependency
# (spec section 3-5: bash/grep/find only, no added runtime dependency).
# Sourced by scan.sh. Bash 3.2 compatible: no associative arrays.
#
# One record per emitted finding, stored as a pipe-delimited line in
# $FINDINGS_TMP (a temp file scan.sh creates and removes on exit):
#   severity|rule_id|guideline|message|suppressed|ev_a|ev_b|ev_c|provider
# ev_a/ev_b/ev_c are "file<COLON>line" or empty. Pipe/newline are escaped in
# message text before writing so the delimited format stays parseable.

: "${FINDINGS_TMP:=}"
: "${_SUPPRESSED_COUNT:=0}"

_esc_field() {
  # Escape the field delimiter and newlines so a message can never break the
  # pipe-delimited record shape.
  printf '%s' "$1" | tr '\n' ' ' | sed 's/|/\\|/g'
}

# _record <severity> <rule_id> <guideline> <message> <suppressed:true|false> \
#         <ev_a> <ev_b> <ev_c> <provider>
_record() {
  local sev="$1" rule="$2" guideline="$3" msg="$4" sup="$5" eva="$6" evb="$7" evc="$8" prov="$9"
  [[ -n "$FINDINGS_TMP" ]] || return 0
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$sev" "$rule" "$guideline" "$(_esc_field "$msg")" "$sup" "$eva" "$evb" "$evc" "$prov" \
    >> "$FINDINGS_TMP"
  [[ "$sup" == "true" ]] && _SUPPRESSED_COUNT=$((_SUPPRESSED_COUNT + 1))
}

# _json_escape <string> -> JSON string escaping (quote/backslash/control chars).
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  # Use printf/sed to turn literal newlines/tabs into escapes; message fields
  # are already newline-free (see _esc_field), this also covers file paths.
  s="$(printf '%s' "$s" | sed ':a;N;$!ba;s/\n/\\n/g;s/\t/\\t/g')"
  printf '%s' "$s"
}

# _evidence_json <"file:line"|""> -> {"file":"...","line":N} or null
_evidence_json() {
  local ev="$1" file line
  if [[ -z "$ev" ]]; then
    printf 'null'
    return
  fi
  file="${ev%:*}"
  line="${ev##*:}"
  if [[ "$line" =~ ^[0-9]+$ ]]; then
    printf '{"file":"%s","line":%s}' "$(_json_escape "$file")" "$line"
  else
    printf '{"file":"%s","line":null}' "$(_json_escape "$file")"
  fi
}

# render_json <tool_name> <version> -> the JSON envelope on stdout.
render_json() {
  local tool="$1" version="$2" buf="${FINDINGS_TMP:-}"
  local fail=0 warn=0 pass=0 suppressed=0 verdict="PASS" first=1
  local sev rule guideline msg sup eva evb evc prov

  printf '{"tool":"%s","version":"%s","findings":[' "$tool" "$version"
  if [[ -s "$buf" ]]; then
    while IFS='|' read -r sev rule guideline msg sup eva evb evc prov; do
      [[ -z "$sev" ]] && continue
      if [[ "$sup" != "true" ]]; then
        case "$sev" in
          fail) fail=$((fail + 1)) ;;
          warn) warn=$((warn + 1)) ;;
          pass) pass=$((pass + 1)) ;;
        esac
      else
        suppressed=$((suppressed + 1))
      fi
      [[ $first -eq 0 ]] && printf ','
      first=0
      printf '{"rule_id":"%s","severity":"%s","guideline":"%s","message":"%s","provider":%s,"evidence":{"server_ai_call":%s,"client_ui_disclosure":%s,"policy_disclosure":%s},"suppressed":%s}' \
        "$(_json_escape "$rule")" "$sev" "$(_json_escape "$guideline")" "$(_json_escape "$msg")" \
        "$([[ -n "$prov" ]] && printf '"%s"' "$(_json_escape "$prov")" || printf 'null')" \
        "$(_evidence_json "$eva")" "$(_evidence_json "$evb")" "$(_evidence_json "$evc")" \
        "$sup"
    done < "$buf"
  fi
  printf ']'

  if (( fail > 0 )); then verdict="FAIL"; elif (( warn > 0 )); then verdict="WARN"; fi
  printf ',"verdict":"%s","summary":{"fail":%d,"warn":%d,"pass":%d,"suppressed":%d}}\n' \
    "$verdict" "$fail" "$warn" "$pass" "$suppressed"
}
