#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/latest-stable.sh"

failures=0
case_name=""

fail() {
    printf 'not ok - %s: %s\n' "$case_name" "$*" >&2
    failures=$((failures + 1))
}

case_name="selects the highest stable version across major releases"
actual="$(cat <<'JSON' | "$script"
[
  {"tag_name":"2.3.15","draft":false,"prerelease":false},
  {"tag_name":"3.1.14","draft":false,"prerelease":false},
  {"tag_name":"4.0.7","draft":false,"prerelease":false}
]
[
  {"tag_name":"5.0.0","draft":false,"prerelease":false},
  {"tag_name":"4.0.10","draft":false,"prerelease":false},
  {"tag_name":"4.0.9","draft":false,"prerelease":false},
  {"tag_name":"6.0.0","draft":true,"prerelease":false},
  {"tag_name":"5.1.0-rc.1","draft":false,"prerelease":true},
  {"tag_name":"v7.0.0","draft":false,"prerelease":false},
  {"tag_name":"malformed","draft":false,"prerelease":false}
]
JSON
)" || fail "script failed"
[[ "$actual" == 5.0.0 ]] || fail "expected 5.0.0, got $actual"

case_name="sorts numeric components rather than lexically"
actual="$(cat <<'JSON' | "$script"
[
  {"tag_name":"4.0.9","draft":false,"prerelease":false},
  {"tag_name":"4.0.10","draft":false,"prerelease":false}
]
JSON
)" || fail "script failed"
[[ "$actual" == 4.0.10 ]] || fail "expected 4.0.10, got $actual"

case_name="fails when no stable tags are available"
if output="$(cat <<'JSON' | "$script" 2>&1
[
  {"tag_name":"v5.0.0","draft":false,"prerelease":false},
  {"tag_name":"5.0.0-beta.1","draft":false,"prerelease":true},
  {"tag_name":"malformed","draft":false,"prerelease":false}
]
JSON
)"; then
    fail "expected a non-zero exit status"
fi
grep -qF 'no stable X.Y.Z release tags found' <<<"$output" || fail "missing error message"

case_name="rejects malformed API data"
if output="$(printf '%s\n' '{not-json' | "$script" 2>&1)"; then
    fail "expected a non-zero exit status"
fi
[[ -n "$output" ]] || fail "missing parse error"

if ((failures > 0)); then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
