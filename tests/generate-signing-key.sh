#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_script="$root/scripts/generate-signing-key.sh"

tmpbase="${TMPDIR:-$root/.test-tmp}"
mkdir -p -- "$tmpbase"
work="$(mktemp -d -p "$tmpbase")"
fixture_root="$work/project"
script="$fixture_root/scripts/generate-signing-key.sh"
bin="$work/bin"
tmp="$work/tmp"
record="$work/record"
verify="$work/verify"
bystander="$work/bystander"

cleanup() {
    stop_agent "$verify"
    stop_agent "$bystander"
    rm -rf -- "$work"
    [[ "$tmpbase" != "$root/.test-tmp" ]] || rmdir -- "$tmpbase" 2>/dev/null || true
}

stop_agent() {
    gpgconf --homedir "$1" --kill all >/dev/null 2>&1 || true
    gpgconf --homedir "$1" --remove-socketdir >/dev/null 2>&1 || true
}
trap cleanup EXIT

reset_fixture() {
    rm -rf -- "$fixture_root"
    mkdir -p "$fixture_root/scripts" "$fixture_root/packaging/apt"
    cp -- "$source_script" "$script"
    cp -- "$root/README.md" "$fixture_root/README.md"
    cp -- "$root/packaging/apt/fingerprint" "$fixture_root/packaging/apt/fingerprint"
}

failures=0
case_name=""
status=0
listing=""

fail() {
    echo "not ok - ${case_name}: $*" >&2
    failures=$((failures + 1))
}

# The script under test must only ever talk to this stub, never to GitHub.
mkdir -p "$bin" "$work/only-gh" "$work/only-gpg"
cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
    "repo view")
        [[ "${STUB_GH_FAIL:-}" != repo ]] || { echo "gh: no GitHub remote found" >&2; exit 1; }
        echo "stub-owner/stub-repo"
        ;;
    "secret set")
        printf '%s\n' "${GNUPGHOME:-}" >"$STUB_GH_RECORD/gnupghome"
        gpgconf --list-dirs socketdir >"$STUB_GH_RECORD/socketdir"
        cat >"$STUB_GH_RECORD/input"
        [[ "${STUB_GH_FAIL:-}" != secret ]] || { echo "gh: HTTP 403" >&2; exit 1; }
        printf '%s\n' "$@" >"$STUB_GH_RECORD/args"
        mv "$STUB_GH_RECORD/input" "$STUB_GH_RECORD/secret"
        ;;
    *)
        echo "unexpected gh call: $*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$bin/gh"
cp "$bin/gh" "$work/only-gh/gh"
ln -s "$(command -v gpg)" "$work/only-gpg/gpg"
[[ "$(PATH="$bin:$PATH" command -v gh)" == "$bin/gh" ]] || {
    echo "stub gh is not first on PATH; refusing to run" >&2
    exit 1
}

# run [VAR=value ...] [-- script args]: runs the script with a clean environment.
run() {
    local -a assignments=() args=()
    local preserve_fixture=false
    while (($# > 0)); do
        if [[ "$1" == --keep-fixture ]]; then
            preserve_fixture=true
            shift
            continue
        fi
        if [[ "$1" == -- ]]; then
            shift
            args=("$@")
            break
        fi
        assignments+=("$1")
        shift
    done
    rm -rf -- "$tmp" "$record"
    mkdir -p "$tmp" "$record"
    [[ "$preserve_fixture" == true ]] || reset_fixture
    status=0
    env -u GH_REPO -u KEY_NAME -u KEY_EMAIL -u KEY_LIFETIME \
        TMPDIR="$tmp" STUB_GH_RECORD="$record" PATH="$bin:$PATH" \
        GH_TOKEN=stub-never-valid GITHUB_TOKEN=stub-never-valid \
        "${assignments[@]}" "$BASH" "$script" "${args[@]}" \
        >"$work/stdout" 2>"$work/stderr" || status=$?
}

import_stored_key() {
    stop_agent "$verify"
    rm -rf -- "$verify"
    mkdir -m 700 "$verify"
    GNUPGHOME="$verify" gpg --batch --quiet --import "$record/secret" 2>/dev/null
    listing="$(GNUPGHOME="$verify" gpg --batch --with-colons --list-secret-keys)"
}

field() {
    awk -F: -v record="$1" -v column="$2" '$1 == record && !seen++ { print $column }' <<<"$listing"
}

assert_no_private_key_output() {
    ! grep -q 'PRIVATE KEY' "$work/stdout" "$work/stderr" || fail "private key was printed"
}

agent_running() {
    pgrep -f -- "--homedir $1" >/dev/null
}

assert_keyring_cleaned_up() {
    local home socketdir
    if [[ -s "$record/gnupghome" ]]; then
        home="$(<"$record/gnupghome")"
        [[ "$home" == "$tmp"/* ]] || fail "keyring was not created under TMPDIR: $home"
        [[ ! -e "$home" ]] || fail "keyring was left behind: $home"
        for _ in {1..30}; do agent_running "$home" || break; sleep 0.1; done
        ! agent_running "$home" || fail "the agent of the throwaway keyring is still running"
        socketdir="$(<"$record/socketdir")"
        [[ "$socketdir" != */d.* || ! -e "$socketdir" ]] || fail "agent socket directory was left behind: $socketdir"
    fi
    [[ -z "$(find "$tmp" -mindepth 1 -print -quit)" ]] || fail "temporary files were left behind"
}

# assert_failed MESSAGE: non-zero exit, nothing stored or printed, error logged.
assert_failed() {
    [[ $status -ne 0 ]] || fail "expected a non-zero exit status"
    [[ ! -s "$work/stdout" ]] || fail "stdout must stay empty on failure"
    [[ ! -e "$record/secret" ]] || fail "a secret was stored"
    grep -qF -- "$1" "$work/stderr" || fail "stderr lacks: $1"
    assert_no_private_key_output
    assert_keyring_cleaned_up
}

case_name="stores a key with the requested identity and lifetime"
run KEY_NAME="Test Key" KEY_EMAIL="test@example.invalid" KEY_LIFETIME=30d
[[ $status -eq 0 ]] || fail "exit status $status"
fingerprint="$(<"$work/stdout")"
[[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] || fail "stdout is not a fingerprint: $fingerprint"
[[ "$(<"$record/args")" == $'secret\nset\nAPT_GPG_PRIVATE_KEY\n--repo\nstub-owner/stub-repo' ]] ||
    fail "unexpected gh arguments"
import_stored_key || fail "stored secret is not an importable key"
[[ "$(field fpr 10)" == "$fingerprint" ]] || fail "stored key does not match the printed fingerprint"
[[ "$(field uid 10)" == "Test Key <test@example.invalid>" ]] || fail "unexpected user ID: $(field uid 10)"
[[ "$(field sec 4)" == 22 ]] || fail "key is not ed25519"
caps="$(field sec 12)"
[[ "$caps" == *s* && "$caps" != *e* ]] || fail "key is not signing-only: $caps"
[[ $(($(field sec 7) - $(field sec 6))) -eq $((30 * 86400)) ]] || fail "key lifetime is not 30 days"
grep -qF "fingerprint=$fingerprint" "$work/stderr" || fail "fingerprint was not logged"
[[ "$(<"$fixture_root/packaging/apt/fingerprint")" == "$fingerprint" ]] ||
    fail "fingerprint pin was not updated"
grep -Fq -- "\`$fingerprint\`" "$fixture_root/README.md" ||
    fail "README fingerprint was not updated"
! grep -Fq 'REPLACE_WITH_SIGNING_KEY_FINGERPRINT' "$fixture_root/README.md" ||
    fail "README placeholder was not replaced"
! grep -qv '^level=' "$work/stderr" || fail "stderr contains lines that are not log records"
assert_no_private_key_output
assert_keyring_cleaned_up

case_name="updates an existing pin and README fingerprint during key rotation"
reset_fixture
old_fingerprint="1123456789ABCDEF0123456789ABCDEF01234567"
printf '%s\n' "$old_fingerprint" > "$fixture_root/packaging/apt/fingerprint"
awk -v placeholder=REPLACE_WITH_SIGNING_KEY_FINGERPRINT -v fingerprint="$old_fingerprint" \
    '{ gsub(placeholder, fingerprint); print }' "$fixture_root/README.md" > "$work/README.md"
mv -- "$work/README.md" "$fixture_root/README.md"
run --keep-fixture KEY_NAME="Rotated Key" KEY_EMAIL="rotation@example.invalid"
[[ $status -eq 0 ]] || fail "exit status $status"
fingerprint="$(<"$work/stdout")"
[[ "$fingerprint" =~ ^[0-9A-F]{40}$ && "$fingerprint" != "$old_fingerprint" ]] ||
    fail "unexpected rotated fingerprint: $fingerprint"
[[ "$(<"$fixture_root/packaging/apt/fingerprint")" == "$fingerprint" ]] ||
    fail "fingerprint pin was not rotated"
grep -Fq -- "\`$fingerprint\`" "$fixture_root/README.md" ||
    fail "README fingerprint was not rotated"
! grep -Fq -- "$old_fingerprint" "$fixture_root/README.md" ||
    fail "README still contains the old fingerprint"
import_stored_key || fail "stored rotated key is not importable"
[[ "$(field fpr 10)" == "$fingerprint" ]] || fail "stored secret does not match the rotated fingerprint"
assert_no_private_key_output
assert_keyring_cleaned_up

case_name="leaves agents of other keyrings running"
agent_pid() {
    GNUPGHOME="$bystander" gpg-connect-agent "$@" 'getinfo pid' /bye 2>/dev/null |
        awk '$1 == "D" { print $2 }' || true
}
mkdir -m 700 "$bystander"
bystander_pid="$(agent_pid)"
[[ "$bystander_pid" =~ ^[0-9]+$ ]] || fail "could not start the bystander agent"
run
[[ $status -eq 0 ]] || fail "exit status $status"
[[ "$(agent_pid --no-autostart)" == "$bystander_pid" ]] || fail "an agent of another keyring was stopped"

case_name="KEY_LIFETIME=0 creates a key that does not expire"
run KEY_LIFETIME=0
[[ $status -eq 0 ]] || fail "exit status $status"
import_stored_key || fail "stored secret is not an importable key"
[[ -z "$(field sec 7)" ]] || fail "key has an expiry"
grep -qF 'expires=never' "$work/stderr" || fail "missing expires=never"

case_name="GH_REPO selects the repository without detection"
run GH_REPO=other-owner/other-repo STUB_GH_FAIL=repo
[[ $status -eq 0 ]] || fail "exit status $status"
[[ "$(<"$record/args")" == *$'--repo\nother-owner/other-repo' ]] || fail "secret went to the wrong repository"

case_name="rejects an invalid lifetime"
run KEY_LIFETIME=bogus
assert_failed 'msg="key generation failed"'

case_name="fails when the secret cannot be stored"
run STUB_GH_FAIL=secret
assert_failed 'msg="storing the private key failed"'
[[ -s "$record/gnupghome" ]] || fail "failure did not occur at the upload step"
[[ "$(<"$fixture_root/packaging/apt/fingerprint")" == REPLACE_WITH_SIGNING_KEY_FINGERPRINT ]] ||
    fail "fingerprint pin changed although secret storage failed"
grep -Fq 'REPLACE_WITH_SIGNING_KEY_FINGERPRINT' "$fixture_root/README.md" ||
    fail "README changed although secret storage failed"

case_name="fails when the repository cannot be resolved"
run STUB_GH_FAIL=repo
assert_failed 'msg="cannot resolve the target repository'

case_name="rejects a README without the current fingerprint before generating a key"
rm -rf -- "$tmp" "$record"
mkdir -p "$tmp" "$record"
reset_fixture
printf '%s\n' 1123456789ABCDEF0123456789ABCDEF01234567 > "$fixture_root/packaging/apt/fingerprint"
if env -u KEY_NAME -u KEY_EMAIL -u KEY_LIFETIME PATH="$bin:$PATH" GH_REPO=other-owner/other-repo \
    STUB_GH_RECORD="$record" TMPDIR="$tmp" "$BASH" "$script" >"$work/stdout" 2>"$work/stderr"; then
    fail "expected a non-zero exit status"
fi
grep -qF 'README does not contain the pinned fingerprint' "$work/stderr" ||
    fail "missing README preflight error"
[[ ! -e "$record/secret" ]] || fail "a secret was stored despite README preflight failure"

case_name="fails without gpg"
run PATH="$work/only-gh"
assert_failed 'msg="missing dependency" tool=gpg'

case_name="fails without gh"
run PATH="$work/only-gpg"
assert_failed 'msg="missing dependency" tool=gh'

case_name="rejects unexpected arguments"
run -- --bogus
assert_failed 'Usage:'
[[ $status -eq 2 ]] || fail "exit status $status, expected 2"

if ((failures > 0)); then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
