#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/check-signing-key-expiry.sh"
fingerprint="0123456789ABCDEF0123456789ABCDEF01234567"
now=1800000000
tmpbase="${TMPDIR:-$root/.test-tmp}"
mkdir -p -- "$tmpbase"
work="$(mktemp -d -p "$tmpbase")"
cleanup() {
    rm -rf -- "$work"
    [[ "$tmpbase" != "$root/.test-tmp" ]] || rmdir -- "$tmpbase" 2>/dev/null || true
}
trap cleanup EXIT

failures=0
case_name=""

fail() {
    printf 'not ok - %s: %s\n' "$case_name" "$*" >&2
    failures=$((failures + 1))
}

case_name="warns at the 60-day expiry boundary"
"$script" "$fingerprint" "$fingerprint" "$((now + 60 * 86400))" "$now" >"$work/out" 2>"$work/err" ||
    fail "script failed"
grep -qF '::warning title=APT signing key expiry::' "$work/out" || fail "missing expiry warning"

case_name="does not warn when more than 60 days remain"
"$script" "$fingerprint" "$fingerprint" "$((now + 60 * 86400 + 1))" "$now" >"$work/out" 2>"$work/err" ||
    fail "script failed"
[[ ! -s "$work/out" ]] || fail "unexpected warning"

case_name="does not warn for a non-expiring key"
"$script" "$fingerprint" "$fingerprint" 0 "$now" >"$work/out" 2>"$work/err" || fail "script failed"
[[ ! -s "$work/out" ]] || fail "unexpected warning"

case_name="fails when the imported key does not match the pin"
if "$script" "$fingerprint" "1123456789ABCDEF0123456789ABCDEF01234567" 0 "$now" >"$work/out" 2>"$work/err"; then
    fail "expected a non-zero exit status"
fi
grep -qF 'does not match the pinned fingerprint' "$work/err" || fail "missing fingerprint error"

case_name="fails for an expired key"
if "$script" "$fingerprint" "$fingerprint" "$((now - 1))" "$now" >"$work/out" 2>"$work/err"; then
    fail "expected a non-zero exit status"
fi
grep -qF 'APT signing key expired' "$work/err" || fail "missing expiry error"

case_name="rejects malformed expiry input"
if "$script" "$fingerprint" "$fingerprint" tomorrow "$now" >"$work/out" 2>"$work/err"; then
    fail "expected a non-zero exit status"
fi
grep -qF 'integer epochs' "$work/err" || fail "missing invalid-expiry error"

if ((failures > 0)); then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
