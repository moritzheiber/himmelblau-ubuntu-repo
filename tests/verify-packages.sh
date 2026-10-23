#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/verify-packages.sh"
include="$root/scripts/include-packages.sh"
work="$(mktemp -d -p "$root" .package-tests.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
version="4.0.7-ubuntu26.04"
incoming="$work/incoming"
base="$work/reprepro"
index="$base/dists/resolute/main/binary-amd64/Packages"
mkdir -p "$incoming" "$base/conf"
grep -v '^SignWith:' "$root/packaging/apt/distributions" > "$base/conf/distributions"

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

build_package() {
    local name="$1" architecture="${2:-amd64}" package_version="${3:-$version}"
    local section="${4-}" priority="${5-optional}"
    mkdir -p "$work/build/$name/DEBIAN"
    cat > "$work/build/$name/DEBIAN/control" <<EOF
Package: $name
Version: $package_version
Architecture: $architecture
Maintainer: Test <test@example.invalid>
Description: Package publication test fixture
EOF
    if [[ -n "$section" ]]; then
        printf 'Section: %s\n' "$section" >> "$work/build/$name/DEBIAN/control"
    fi
    if [[ -n "$priority" ]]; then
        printf 'Priority: %s\n' "$priority" >> "$work/build/$name/DEBIAN/control"
    fi
    dpkg-deb --build --root-owner-group "$work/build/$name" "$incoming/$name.deb" > /dev/null
}

case_name="rejects an empty build"
assert_rejected 'no Debian packages found' "$script" "$version" "$incoming"

build_package himmelblau
build_package nss-himmelblau
build_package himmelblau-future-package

case_name="accepts every package without a name allowlist or filename architecture suffix"
"$script" "$version" "$incoming" || fail "script failed"

case_name="rejects an unexpected version in any package"
build_package himmelblau-future-package amd64 4.0.6-ubuntu26.04
assert_rejected 'unexpected version' "$script" "$version" "$incoming"
build_package himmelblau-future-package

for architecture in arm64 all; do
    case_name="rejects $architecture packages rather than silently skipping them"
    build_package himmelblau-future-package "$architecture"
    assert_rejected 'unexpected architecture' "$script" "$version" "$incoming"
done
build_package himmelblau-future-package

case_name="rejects a malformed package"
printf 'not a Debian package\n' > "$incoming/broken.deb"
assert_rejected 'dpkg-deb: error:' "$script" "$version" "$incoming"

case_name="rejects malformed input during package inclusion"
assert_rejected 'dpkg-deb: error:' "$include" "$base" "$incoming/broken.deb" "$incoming/himmelblau.deb"
rm -- "$incoming/broken.deb"

case_name="rejects package inclusion with no package arguments"
assert_rejected 'Usage:' "$include" "$base"

case_name="reports a reprepro configuration failure"
assert_rejected 'distributions' "$include" "$work/missing-repo" "$incoming/himmelblau.deb"

build_package nss-himmelblau amd64 "$version" admin extra
build_package himmelblau-future-package amd64 "$version" "" ""
build_package section-only-package amd64 "$version" utils ""

"$include" "$base" "$incoming/himmelblau.deb" "$incoming/nss-himmelblau.deb"

case_name="rejects an index missing a built package"
assert_rejected 'APT index does not match' "$script" "$version" "$incoming" "$index"

"$include" "$base" "$incoming/himmelblau-future-package.deb" "$incoming/section-only-package.deb"

case_name="accepts the complete exported APT index"
"$script" "$version" "$incoming" "$index" || fail "script failed"

case_name="fills missing metadata and preserves declared sections and priorities"
metadata="$(awk '
    BEGIN { RS = ""; FS = "\n" }
    {
        name = section = priority = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^Package: /) name = substr($i, 10)
            if ($i ~ /^Section: /) section = substr($i, 10)
            if ($i ~ /^Priority: /) priority = substr($i, 11)
        }
        print name, section, priority
    }
' "$index" | LC_ALL=C sort)"
[[ "$metadata" == $'himmelblau misc optional\nhimmelblau-future-package misc optional\nnss-himmelblau admin extra\nsection-only-package utils optional' ]] ||
    fail "unexpected APT metadata: $metadata"
[[ -z "$(dpkg-deb -f "$incoming/himmelblau.deb" Section)" ]] ||
    fail "package inclusion changed the original package"

case_name="rejects an extra indexed package"
build_package unrelated-package
"$include" "$base" "$incoming/unrelated-package.deb"
mv -- "$incoming/unrelated-package.deb" "$work/"
assert_rejected 'APT index does not match' "$script" "$version" "$incoming" "$index"
reprepro -b "$base" remove resolute unrelated-package

case_name="rejects an indexed package with a different version"
cp -- "$incoming/nss-himmelblau.deb" "$work/nss-himmelblau.deb"
build_package nss-himmelblau amd64 4.0.8-ubuntu26.04
"$include" "$base" "$incoming/nss-himmelblau.deb"
mv -- "$work/nss-himmelblau.deb" "$incoming/nss-himmelblau.deb"
assert_rejected 'APT index does not match' "$script" "$version" "$incoming" "$index"

case_name="rejects a missing index"
assert_rejected 'Packages' "$script" "$version" "$incoming" "$work/missing/Packages"

if ((failures > 0)); then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
