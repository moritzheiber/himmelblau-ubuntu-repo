#!/usr/bin/env bash
set -euo pipefail

secret_name="APT_GPG_PRIVATE_KEY"
default_name="himmelblau-ubuntu-repo repository signing key"
default_email="github@heiber.im"
default_lifetime="2y"
needs_quoting='[[:space:]"=]'
key_name="${KEY_NAME:-$default_name}"
key_email="${KEY_EMAIL:-$default_email}"
key_lifetime="${KEY_LIFETIME:-$default_lifetime}"

usage() {
    cat <<EOF
Usage: scripts/generate-signing-key.sh

Generates an ed25519 signing key in a throwaway keyring, stores the private key
as the ${secret_name} secret of the GitHub repository, updates the fingerprint
in packaging/apt/fingerprint and README.md, and prints the fingerprint. The
private key exists only in the throwaway keyring and in the secret.

Environment:
  KEY_NAME         user ID name (default: ${default_name})
  KEY_EMAIL        user ID email (default: ${default_email})
  KEY_LIFETIME     gpg expiry such as 2y, 18m, 90d, or 0 for none (default: ${default_lifetime})
  GH_REPO          target repository as OWNER/REPO (default: the repository of this checkout)

Requires gpg and an authenticated gh. Logs go to stderr, the fingerprint to stdout.
EOF
}

log() {
    local level="$1" msg="$2" pair value
    shift 2
    printf 'level=%s msg="%s"' "$level" "$msg" >&2
    for pair in "$@"; do
        value="${pair#*=}"
        if [[ "$value" =~ $needs_quoting ]]; then
            value="${value//\\/\\\\}"
            value="${value//\"/\\\"}"
            pair="${pair%%=*}=\"${value//$'\n'/\\n}\""
        fi
        printf ' %s' "$pair" >&2
    done
    printf '\n' >&2
}

die() {
    log error "$@"
    exit 1
}

case "${1:-}" in
    "") ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

for tool in gpg gh; do
    command -v "$tool" >/dev/null || die "missing dependency" tool="$tool"
done

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fingerprint_file="$root/packaging/apt/fingerprint"
readme_file="$root/README.md"
expected_fingerprint_placeholder="REPLACE_WITH_SIGNING_KEY_FINGERPRINT"
[[ -f "$fingerprint_file" && -f "$readme_file" ]] ||
    die "required repository files are missing" fingerprint_file="$fingerprint_file" readme_file="$readme_file"

previous_fingerprint="$(<"$fingerprint_file")"
if [[ "$previous_fingerprint" != "$expected_fingerprint_placeholder" &&
    ! "$previous_fingerprint" =~ ^[0-9A-F]{40}$ ]]; then
    die "invalid fingerprint in repository pin file" fingerprint_file="$fingerprint_file"
fi
grep -Fq -- "$previous_fingerprint" "$readme_file" ||
    die "README does not contain the pinned fingerprint" fingerprint="$previous_fingerprint"

repo="${GH_REPO:-$(cd "$root" && gh repo view --json nameWithOwner --jq .nameWithOwner)}" ||
    die "cannot resolve the target repository; authenticate gh or set GH_REPO"

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
state_dir=""

# Stops only the agent of this throwaway keyring; agents of other keyrings are left alone.
cleanup() {
    gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
    gpgconf --homedir "$GNUPGHOME" --remove-socketdir >/dev/null 2>&1 || true
    rm -rf -- "$GNUPGHOME"
    [[ -z "$state_dir" ]] || rm -rf -- "$state_dir"
}
trap cleanup EXIT

if ! gpg_output="$(gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "${key_name} <${key_email}>" ed25519 sign "$key_lifetime" 2>&1)"; then
    printf '%s\n' "$gpg_output" >&2
    die "key generation failed" lifetime="$key_lifetime"
fi

listing="$(gpg --batch --trust-model always --with-colons --list-secret-keys)"
fpr="$(awk -F: '$1 == "fpr" && !seen++ { print $10 }' <<<"$listing")"
expiry="$(awk -F: '$1 == "sec" && !seen++ { print $7 }' <<<"$listing")"
[[ "$fpr" =~ ^[0-9A-F]{40}$ ]] || die "unexpected fingerprint" fingerprint="$fpr"
if [[ -n "$expiry" ]]; then
    expires="$(date -u -d "@${expiry}" +%F)"
else
    expires="never"
fi
log info "generated signing key" fingerprint="$fpr" expires="$expires"

state_dir="$(mktemp -d -p "$root" .signing-key-setup.XXXXXX)" ||
    die "cannot prepare fingerprint updates" repository="$root"
new_fingerprint_file="$state_dir/fingerprint"
new_readme_file="$state_dir/README.md"
previous_fingerprint_file="$state_dir/fingerprint.previous"
cp -- "$fingerprint_file" "$previous_fingerprint_file" ||
    die "cannot back up fingerprint pin" fingerprint_file="$fingerprint_file"
printf '%s\n' "$fpr" > "$new_fingerprint_file" ||
    die "cannot prepare fingerprint pin update" fingerprint_file="$fingerprint_file"
sed "s/${previous_fingerprint}/${fpr}/g" "$readme_file" > "$new_readme_file" ||
    die "cannot prepare README fingerprint update" readme_file="$readme_file"
grep -Fq -- "$fpr" "$new_readme_file" ||
    die "prepared README does not contain the new fingerprint" readme_file="$readme_file"

gpg --batch --armor --export-secret-keys "$fpr" |
    gh secret set "$secret_name" --repo "$repo" >/dev/null ||
    die "storing the private key failed" secret="$secret_name" repo="$repo"
log info "stored private key as repository secret" secret="$secret_name" repo="$repo"

if ! mv -- "$new_fingerprint_file" "$fingerprint_file"; then
    die "private key is stored, but the fingerprint pin was not updated; set ${fingerprint_file} to ${fpr}"
fi
if ! mv -- "$new_readme_file" "$readme_file"; then
    if cp -- "$previous_fingerprint_file" "$fingerprint_file"; then
        die "private key is stored, README was not updated, and the fingerprint pin was restored; replace the old README fingerprint with ${fpr}"
    fi
    die "private key is stored, but local updates are partial: set ${fingerprint_file} to ${fpr} and replace the old README fingerprint with ${fpr}"
fi
log info "updated signing key fingerprint" fingerprint="$fpr"

printf '%s\n' "$fpr"
