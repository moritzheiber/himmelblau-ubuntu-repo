#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/ubuntu-releases.sh"
work="$(mktemp -d -p "$root" .release-tests.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
releases="$work/releases"
assets="$work/assets"

failures=0
case_name=""

fail() {
    printf 'not ok - %s: %s\n' "$case_name" "$*" >&2
    failures=$((failures + 1))
}

assert_rejected() {
    local message="$1" output
    shift
    if output="$("$@" 2>&1)"; then
        fail "expected a non-zero exit status"
    fi
    grep -qF "$message" <<<"$output" || fail "missing error: $message"
}

assert_output() {
    local expected="$1" actual
    shift
    actual="$("$@")" || fail "script failed"
    [[ "$actual" == "$expected" ]] || fail "expected $expected, got $actual"
}

all='[{"version":"24.04","codename":"noble"},{"version":"26.04","codename":"resolute"}]'
printf '24.04 noble\n\n26.04 resolute' > "$releases"

case_name="lists every release in file order, ignoring blank lines and a missing final newline"
assert_output "$all" "$script" "$releases"

case_name="accepts the repository release list"
"$script" "$root/packaging/apt/releases" > /dev/null || fail "script failed"

case_name="lists releases without packages in the release assets"
printf '%s\n' himmelblau_4.0.7-ubuntu26.04_amd64.deb o365_4.0.7-ubuntu26.04_amd64.deb > "$assets"
assert_output '[{"version":"24.04","codename":"noble"}]' "$script" "$releases" "$assets"

case_name="lists no releases when every release has packages"
printf '%s\n' himmelblau_4.0.7-ubuntu24.04_amd64.deb >> "$assets"
assert_output '[]' "$script" "$releases" "$assets"

case_name="matches the complete asset suffix"
printf '%s\n' himmelblau_4.0.7-ubuntu24.04_amd64.deb.sig himmelblau_4.0.7-ubuntu24x04_amd64.deb > "$assets"
assert_output "$all" "$script" "$releases" "$assets"

case_name="lists every release for an empty asset list"
: > "$assets"
assert_output "$all" "$script" "$releases" "$assets"

case_name="rejects a malformed line"
printf '24.04 noble\n26.04\n' > "$work/malformed"
assert_rejected 'malformed:2: expected "VERSION CODENAME"' "$script" "$work/malformed"

case_name="rejects a duplicate version"
printf '24.04 noble\n24.04 resolute\n' > "$work/duplicate"
assert_rejected 'duplicate release 24.04 resolute' "$script" "$work/duplicate"

case_name="rejects a duplicate codename"
printf '24.04 noble\n26.04 noble\n' > "$work/duplicate"
assert_rejected 'duplicate release 26.04 noble' "$script" "$work/duplicate"

case_name="rejects an empty release list"
printf '\n' > "$work/empty"
assert_rejected 'lists no releases' "$script" "$work/empty"

case_name="rejects a missing release list"
assert_rejected 'No such file' "$script" "$work/missing"

case_name="rejects a missing asset list"
assert_rejected 'No such file' "$script" "$releases" "$work/missing"

case_name="rejects missing arguments"
assert_rejected 'Usage:' "$script"

if ((failures > 0)); then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
