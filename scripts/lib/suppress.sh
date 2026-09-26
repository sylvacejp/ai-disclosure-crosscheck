#!/usr/bin/env bash
# suppress.sh — .precheck-ignore support, same grammar as appstore-precheck
# (spec section 3-4: "同じ書式を流用する。ゼロから設計しない"), reimplemented
# independently for this tool's single-rule scope. Bash 3.2 compatible.
#
# Grammar (one entry per line, # starts a trailing comment):
#   <rule-id>                 suppress that rule everywhere
#   <rule-id> <path-glob>     suppress that rule only under the matching path
#   <path-glob>               exclude the matching path from scanning entirely

_SUPP_RULES=""       # rule-ids suppressed everywhere, one per line
_SUPP_RULE_PATH=""   # "rule<TAB>glob" per line
_SUPP_PATHS=""       # path globs excluded from scanning, one per line

RULE_ID="cross-repo-ai-consent-mismatch"

_is_known_rule() { [[ "$1" == "$RULE_ID" ]]; }

# load_precheck_ignore [root]
load_precheck_ignore() {
  local root="${1:-.}" file line t1 t2
  file="$root/.precheck-ignore"
  _SUPP_RULES=""; _SUPP_RULE_PATH=""; _SUPP_PATHS=""
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | awk '{$1=$1;print}')"
    [[ -z "$line" ]] && continue
    t1="$(printf '%s' "$line" | awk '{print $1}')"
    t2="$(printf '%s' "$line" | awk '{print $2}')"
    if _is_known_rule "$t1"; then
      if [[ -n "$t2" ]]; then
        _SUPP_RULE_PATH="${_SUPP_RULE_PATH}${t1}	${t2%/}
"
      else
        _SUPP_RULES="${_SUPP_RULES}${t1}
"
      fi
    else
      _SUPP_PATHS="${_SUPP_PATHS}${t1%/}
"
    fi
  done < "$file"
}

# is_suppressed <rule> <file> -> 0 if suppressed, else 1.
is_suppressed() {
  local rule="$1" file="${2:-}" r g
  if [[ -n "$rule" ]] && printf '%s\n' "$_SUPP_RULES" | grep -qxF "$rule"; then
    return 0
  fi
  if [[ -n "$rule" && -n "$file" && -n "$_SUPP_RULE_PATH" ]]; then
    while IFS='	' read -r r g; do
      [[ -z "$r" ]] && continue
      if [[ "$r" == "$rule" ]]; then
        case "$file" in
          "$g"|*/"$g"|"$g"/*|*/"$g"/*) return 0 ;;
        esac
      fi
    done <<INNER
$_SUPP_RULE_PATH
INNER
  fi
  return 1
}

# path_is_excluded <path> -> 0 if a bare path-glob entry excludes it.
path_is_excluded() {
  local path="$1" g
  [[ -z "$_SUPP_PATHS" ]] && return 1
  while IFS= read -r g; do
    [[ -z "$g" ]] && continue
    case "$path" in
      "$g"|*/"$g"|"$g"/*|*/"$g"/*) return 0 ;;
    esac
  done <<INNER
$_SUPP_PATHS
INNER
  return 1
}
