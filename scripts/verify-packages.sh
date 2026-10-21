#!/usr/bin/env bash
set -euo pipefail

if (($# < 2 || $# > 3)); then
    printf 'Usage: %s EXPECTED_VERSION PACKAGE_DIRECTORY [APT_PACKAGES_INDEX]\n' "${0##*/}" >&2
    exit 2
fi

expected_version="$1"
shopt -s nullglob
packages=("$2"/*.deb)
if ((${#packages[@]} == 0)); then
    printf 'error: no Debian packages found in %s\n' "$2" >&2
    exit 1
fi

records=()
for package in "${packages[@]}"; do
    name="$(dpkg-deb -f "$package" Package)"
    version="$(dpkg-deb -f "$package" Version)"
    architecture="$(dpkg-deb -f "$package" Architecture)"
    if [[ "$version" != "$expected_version" ]]; then
        printf 'error: unexpected version %s in %s (expected %s)\n' "$version" "$package" "$expected_version" >&2
        exit 1
    fi
    if [[ "$architecture" != amd64 ]]; then
        printf 'error: unexpected architecture %s in %s (expected amd64)\n' "$architecture" "$package" >&2
        exit 1
    fi
    records+=("$name $version $architecture")
done

if (($# == 3)); then
    expected="$(printf '%s\n' "${records[@]}" | LC_ALL=C sort)"
    actual="$(awk '
        BEGIN { RS = ""; FS = "\n" }
        {
            name = version = architecture = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^Package: /) name = substr($i, 10)
                if ($i ~ /^Version: /) version = substr($i, 10)
                if ($i ~ /^Architecture: /) architecture = substr($i, 15)
            }
            print name, version, architecture
        }
    ' "$3" | LC_ALL=C sort)"
    if ! diff -u --label 'release packages' --label 'APT index' \
        <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"); then
        printf 'error: APT index does not match the complete release package set\n' >&2
        exit 1
    fi
fi

printf 'Verified %s package(s)\n' "${#packages[@]}"
