#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/build-apt-repository.sh"
work="$(mktemp -d -p "$root" .repository-tests.XXXXXX)"
export GNUPGHOME="$work/gnupg"
cleanup() {
    gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
    gpgconf --homedir "$GNUPGHOME" --remove-socketdir >/dev/null 2>&1 || true
    rm -rf -- "$work"
}
trap cleanup EXIT
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Test <test@example.invalid>' ed25519 sign 1d 2>/dev/null
fingerprint="$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"

tag="4.0.7"
releases="$work/releases"
incoming="$work/incoming"
printf '24.04 noble\n26.04 resolute\n' > "$releases"
mkdir -p "$incoming"

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
    local name="$1" package_version="$2" section="${3-}" priority="${4-}"
    local file="$incoming/${name}_${package_version}_amd64.deb"
    mkdir -p "$work/build/$name/DEBIAN"
    cat > "$work/build/$name/DEBIAN/control" <<EOF
Package: $name
Version: $package_version
Architecture: amd64
Maintainer: Test <test@example.invalid>
Description: Repository build test fixture
EOF
    if [[ -n "$section" ]]; then
        printf 'Section: %s\n' "$section" >> "$work/build/$name/DEBIAN/control"
    fi
    if [[ -n "$priority" ]]; then
        printf 'Priority: %s\n' "$priority" >> "$work/build/$name/DEBIAN/control"
    fi
    dpkg-deb --build --root-owner-group "$work/build/$name" "$file" > /dev/null
    rm -rf -- "$work/build/$name"
}

index_fields() {
    awk '
        BEGIN { RS = ""; FS = "\n" }
        {
            name = version = section = priority = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^Package: /) name = substr($i, 10)
                if ($i ~ /^Version: /) version = substr($i, 10)
                if ($i ~ /^Section: /) section = substr($i, 10)
                if ($i ~ /^Priority: /) priority = substr($i, 11)
            }
            print name, version, section, priority
        }
    ' "$1" | LC_ALL=C sort
}

case_name="rejects an empty package directory"
assert_rejected 'no Debian packages found' "$script" "$releases" "$tag" "$fingerprint" "$incoming" "$work/empty-build"

build_package himmelblau "$tag-ubuntu24.04"
build_package himmelblau "$tag-ubuntu26.04"
build_package nss-himmelblau "$tag-ubuntu26.04" admin extra
build_package section-only-package "$tag-ubuntu26.04" utils

case_name="rejects a configured release without packages"
rm -- "$incoming/himmelblau_${tag}-ubuntu24.04_amd64.deb"
assert_rejected 'no packages for Ubuntu 24.04' "$script" "$releases" "$tag" "$fingerprint" "$incoming" "$work/missing-release"
build_package himmelblau "$tag-ubuntu24.04"

for unexpected in "$tag-ubuntu22.04" "4.0.6-ubuntu26.04" "$tag" "$tag-debian13"; do
    case_name="rejects version $unexpected"
    build_package unexpected "$unexpected"
    assert_rejected "unexpected version $unexpected" \
        "$script" "$releases" "$tag" "$fingerprint" "$incoming" "$work/unexpected"
    rm -- "$incoming"/unexpected_*.deb
done

case_name="rejects a malformed package"
printf 'not a Debian package\n' > "$incoming/broken.deb"
assert_rejected 'dpkg-deb: error:' "$script" "$releases" "$tag" "$fingerprint" "$incoming" "$work/broken"
rm -- "$incoming/broken.deb"

case_name="rejects an invalid release list"
printf 'noble\n' > "$work/invalid-releases"
assert_rejected 'expected "VERSION CODENAME"' "$script" "$work/invalid-releases" "$tag" "$fingerprint" "$incoming" "$work/invalid"

case_name="rejects an unknown signing key"
assert_rejected 'Could not find any key' "$script" "$releases" "$tag" 0000000000000000000000000000000000000000 "$incoming" "$work/unknown-key"

case_name="rejects missing arguments"
assert_rejected 'Usage:' "$script" "$releases" "$tag" "$fingerprint" "$incoming"

base="$work/repository"
case_name="builds one signed distribution per release"
"$script" "$releases" "$tag" "$fingerprint" "$incoming" "$base" || fail "script failed"
for codename in noble resolute; do
    gpg --batch --quiet --verify "$base/dists/$codename/InRelease" 2>/dev/null || fail "invalid $codename InRelease signature"
    grep -qx "Codename: $codename" "$base/dists/$codename/Release" || fail "missing $codename Release"
done
[[ ! -e "$base/staging" ]] || fail "staging directory left behind"

case_name="routes packages to the distribution matching their version"
noble="$(index_fields "$base/dists/noble/main/binary-amd64/Packages")"
[[ "$noble" == "himmelblau $tag-ubuntu24.04 misc optional" ]] || fail "unexpected noble index: $noble"

case_name="fills missing metadata and preserves declared sections and priorities"
resolute="$(index_fields "$base/dists/resolute/main/binary-amd64/Packages")"
[[ "$resolute" == "himmelblau $tag-ubuntu26.04 misc optional"$'\n'"nss-himmelblau $tag-ubuntu26.04 admin extra"$'\n'"section-only-package $tag-ubuntu26.04 utils optional" ]] ||
    fail "unexpected resolute index: $resolute"
[[ -z "$(dpkg-deb -f "$incoming/himmelblau_${tag}-ubuntu26.04_amd64.deb" Section)" ]] ||
    fail "package inclusion changed the original package"

if ((failures > 0)); then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all checks passed\n'
