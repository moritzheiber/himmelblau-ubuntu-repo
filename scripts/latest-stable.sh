#!/usr/bin/env bash
set -euo pipefail

tags="$(jq -sr '
    [ .[][] | select(.draft == false and .prerelease == false)
      | .tag_name | select(type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) ]
    | .[]
')"
latest="$(printf '%s\n' "$tags" | sort -Vu | tail -n 1)"

if [[ -z "$latest" ]]; then
    printf 'error: no stable X.Y.Z release tags found\n' >&2
    exit 1
fi

printf '%s\n' "$latest"
