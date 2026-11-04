#!/usr/bin/env bash
set -euo pipefail

if (($# < 1 || $# > 2)); then
    printf 'Usage: %s RELEASES_FILE [RELEASE_ASSET_NAMES_FILE]\n' "${0##*/}" >&2
    exit 2
fi

releases_file="$1"
assets_file="${2-}"
assets=""
if [[ -n "$assets_file" ]]; then
    assets="$(<"$assets_file")"
fi

declare -A seen_versions=() seen_codenames=()
entries=()
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ -n "$line" ]] || continue
    if [[ ! "$line" =~ ^([0-9]{2}\.[0-9]{2})\ ([a-z]+)$ ]]; then
        printf 'error: %s:%s: expected "VERSION CODENAME", got "%s"\n' "$releases_file" "$line_number" "$line" >&2
        exit 1
    fi
    version="${BASH_REMATCH[1]}"
    codename="${BASH_REMATCH[2]}"
    if [[ -n "${seen_versions[$version]-}" || -n "${seen_codenames[$codename]-}" ]]; then
        printf 'error: %s:%s: duplicate release %s %s\n' "$releases_file" "$line_number" "$version" "$codename" >&2
        exit 1
    fi
    seen_versions[$version]=1
    seen_codenames[$codename]=1
    if [[ -n "$assets_file" ]] && grep -q -- "-ubuntu${version//./\\.}_amd64\\.deb\$" <<<"$assets"; then
        continue
    fi
    entries+=("$version" "$codename")
done < "$releases_file"

if ((${#seen_versions[@]} == 0)); then
    printf 'error: %s lists no releases\n' "$releases_file" >&2
    exit 1
fi

jq -cn '$ARGS.positional | [range(0; length; 2) as $i | {version: .[$i], codename: .[$i + 1]}]' \
    --args "${entries[@]}"
