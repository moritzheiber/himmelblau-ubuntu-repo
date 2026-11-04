#!/usr/bin/env bash
set -euo pipefail

if (($# != 5)); then
    printf 'Usage: %s RELEASES_FILE UPSTREAM_TAG FINGERPRINT PACKAGE_DIRECTORY REPOSITORY_DIRECTORY\n' "${0##*/}" >&2
    exit 2
fi

scripts="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
releases_file="$1"
tag="$2"
fingerprint="$3"
package_directory="$4"
base="$5"
staging="$base/staging"

releases="$("$scripts/ubuntu-releases.sh" "$releases_file")"
declare -A codenames=()
while read -r version codename; do
    codenames[$version]="$codename"
done < <(jq -r '.[] | "\(.version) \(.codename)"' <<<"$releases")

shopt -s nullglob
packages=("$package_directory"/*.deb)
if ((${#packages[@]} == 0)); then
    printf 'error: no Debian packages found in %s\n' "$package_directory" >&2
    exit 1
fi

mkdir -p "$base/conf"
: > "$base/conf/distributions"
for version in $(printf '%s\n' "${!codenames[@]}" | sort -V); do
    codename="${codenames[$version]}"
    cat >> "$base/conf/distributions" <<EOF
Origin: Himmelblau
Label: Himmelblau
Codename: $codename
Suite: $codename
Architectures: amd64
Components: main
Description: Unofficial Himmelblau APT repository for Ubuntu $version ($codename)
SignWith: $fingerprint

EOF
    mkdir -p "$staging/$version"
done

for package in "${packages[@]}"; do
    package_version="$(dpkg-deb -f "$package" Version)"
    release="${package_version#"${tag}-ubuntu"}"
    if [[ "$release" == "$package_version" || -z "${codenames[$release]-}" ]]; then
        printf 'error: unexpected version %s in %s (expected %s-ubuntuVERSION for a release in %s)\n' \
            "$package_version" "$package" "$tag" "$releases_file" >&2
        exit 1
    fi
    cp -- "$package" "$staging/$release/"
done

for version in "${!codenames[@]}"; do
    staged=("$staging/$version"/*.deb)
    if ((${#staged[@]} == 0)); then
        printf 'error: no packages for Ubuntu %s in %s\n' "$version" "$package_directory" >&2
        exit 1
    fi
done

for version in "${!codenames[@]}"; do
    codename="${codenames[$version]}"
    for package in "$staging/$version"/*.deb; do
        section="$(dpkg-deb -f "$package" Section)"
        priority="$(dpkg-deb -f "$package" Priority)"
        options=()
        [[ -n "$section" ]] || options+=(-S misc)
        [[ -n "$priority" ]] || options+=(-P optional)
        reprepro -b "$base" "${options[@]}" includedeb "$codename" "$package"
    done
    "$scripts/verify-packages.sh" "${tag}-ubuntu${version}" "$staging/$version" \
        "$base/dists/$codename/main/binary-amd64/Packages"
done

rm -rf -- "$staging"
