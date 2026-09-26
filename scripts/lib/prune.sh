#!/usr/bin/env bash
# prune.sh — shared exclusion lists for find/grep, plus the language-scope
# include filters. Reimplemented independently for this tool (not copied
# from appstore-precheck's scan.sh — same idea of skipping vendored/build
# output and scoping by extension, but its own array contents, sized to
# this tool's two-sided scan).

# Directories never worth scanning on either side (vendored deps, build
# output, VCS metadata). Extended by --precheck-ignore path-globs at runtime
# (see suppress.sh: precheck_prune_globs).
PRUNE_DIRS=(node_modules .git dist build coverage .next .build Pods Carthage
            DerivedData .swiftpm xcuserdata .cache out)

# grep --exclude-dir=... args built from PRUNE_DIRS.
grep_prune_args() {
  local d
  for d in "${PRUNE_DIRS[@]}"; do
    printf ' --exclude-dir=%s' "$d"
  done
}

# find ! -path ... args built from PRUNE_DIRS, for use after a `find <root>`.
find_prune_args() {
  local d
  for d in "${PRUNE_DIRS[@]}"; do
    printf ' -not -path */%s/*' "$d"
  done
}

# --include=... args for grep -r, scoped to the initial Node/JS/TS support
# (spec 4-4: other server languages are out of scope for this version).
SERVER_INCLUDE_ARGS=(--include=*.js --include=*.jsx --include=*.ts --include=*.tsx
                      --include=*.mjs --include=*.cjs)

# --include=... args for grep -r over the client side (Swift/Obj-C sources),
# mirroring appstore-precheck's SRC_INC scope for signal B.
CLIENT_INCLUDE_ARGS=(--include=*.swift --include=*.m --include=*.mm --include=*.h)
