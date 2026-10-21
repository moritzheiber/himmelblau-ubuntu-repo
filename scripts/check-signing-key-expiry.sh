#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'Usage: %s EXPECTED_FINGERPRINT ACTUAL_FINGERPRINT EXPIRY_EPOCH [NOW_EPOCH]\n' "${0##*/}" >&2
}

if (($# < 3 || $# > 4)); then
    usage
    exit 2
fi

expected="$1"
actual="$2"
expiry="$3"
now="${4:-$(date +%s)}"

if [[ ! "$expected" =~ ^[0-9A-F]{40}$ || ! "$actual" =~ ^[0-9A-F]{40}$ ]]; then
    printf 'error: invalid OpenPGP fingerprint\n' >&2
    exit 1
fi
if [[ "$expected" != "$actual" ]]; then
    printf 'error: imported signing key does not match the pinned fingerprint\n' >&2
    exit 1
fi
if [[ ! "$expiry" =~ ^[0-9]+$ || ! "$now" =~ ^[0-9]+$ ]]; then
    printf 'error: expiry and current time must be integer epochs\n' >&2
    exit 1
fi
if ((expiry == 0)); then
    exit 0
fi
if ((expiry <= now)); then
    printf 'error: APT signing key expired at %s\n' "$(date -u -d "@$expiry" +%F)" >&2
    exit 1
fi

remaining=$((expiry - now))
if ((remaining <= 60 * 24 * 60 * 60)); then
    days=$(((remaining + 86400 - 1) / 86400))
    printf '::warning title=APT signing key expiry::Pinned APT signing key expires in %s day(s), on %s\n' \
        "$days" "$(date -u -d "@$expiry" +%F)"
fi
