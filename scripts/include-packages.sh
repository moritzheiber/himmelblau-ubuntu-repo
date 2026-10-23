#!/usr/bin/env bash
set -euo pipefail

if (($# < 2)); then
    printf 'Usage: %s REPOSITORY_DIRECTORY PACKAGE...\n' "${0##*/}" >&2
    exit 2
fi

base="$1"
shift

for package in "$@"; do
    section="$(dpkg-deb -f "$package" Section)"
    priority="$(dpkg-deb -f "$package" Priority)"
    options=()
    [[ -n "$section" ]] || options+=(-S misc)
    [[ -n "$priority" ]] || options+=(-P optional)
    reprepro -b "$base" "${options[@]}" includedeb resolute "$package"
done
