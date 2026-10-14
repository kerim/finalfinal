#!/bin/bash
#
# unit-quarantine-args.sh — print one `-skip-testing:<id>` argument per line
# for every test listed in scripts/unit-quarantine.txt. Prints nothing when
# the list is empty or missing.
#
# Ids contain a space ("final finalTests/..."), so read the output line by
# line into an array rather than word-splitting it:
#
#   SKIP_ARGS=()
#   while IFS= read -r arg; do SKIP_ARGS+=("$arg"); done \
#     < <(bash scripts/unit-quarantine-args.sh)
#   xcodebuild test ... ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"}

LIST="$(cd "$(dirname "$0")" && pwd)/unit-quarantine.txt"
[ -f "$LIST" ] || exit 0

while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  case "$line" in ''|'#'*) continue ;; esac
  printf -- '-skip-testing:%s\n' "$line"
done < "$LIST"
