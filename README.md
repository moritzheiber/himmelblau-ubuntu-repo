# Himmelblau APT repository

This unofficial repository provides the latest stable Himmelblau packages for Ubuntu 26.04 (resolute), amd64. Packages are built from upstream stable tags and published under the upstream version.

## Install

Add the signing key and APT source, then install:

```console
curl -fsSL https://moritzheiber.github.io/himmelblau-ubuntu-repo/himmelblau.gpg | sudo tee /etc/apt/keyrings/himmelblau.gpg > /dev/null
sudo curl -fsSL https://moritzheiber.github.io/himmelblau-ubuntu-repo/himmelblau.sources -o /etc/apt/sources.list.d/himmelblau.sources
sudo apt update
sudo apt install himmelblau
```

The archive signing key fingerprint is `B563445F0C1712C32DDB87632EA11CE5BE133BAE`. Verify it with `gpg --show-keys /etc/apt/keyrings/himmelblau.gpg`.

GitHub releases contain the package files. The corresponding source archive is linked from each release and from the APT repository page.

## Packages

Every `.deb` produced by the upstream Ubuntu 26.04 build is included in the GitHub release and the APT repository. For upstream `4.0.7`, these are:

- `himmelblau`
- `nss-himmelblau`
- `pam-himmelblau`
- `himmelblau-apparmor`
- `himmelblau-broker`
- `himmelblau-sso`
- `himmelblau-sso-policies`
- `himmelblau-sshd-config`
- `himmelblau-qr-greeter`
- `himmelblau-orchestrator`
- `o365`

Additional packages can be installed individually, for example `sudo apt install himmelblau-sso`. The package set follows upstream rather than a fixed allowlist.

## Maintainers

The daily Release workflow checks for the highest stable upstream `X.Y.Z` tag, builds the Ubuntu 26.04 packages with the upstream Make target, and creates a GitHub release when a newer version is available. Every built package must match the release version and amd64 architecture. The APT workflow verifies that the generated package index matches the complete release package set by name, version, and architecture before deployment. Each deploy replaces the repository contents with only that release's packages. Source archives remain available from the corresponding upstream tags.

### Signing key

Generate the repository's ed25519 key, store its private half as the `APT_GPG_PRIVATE_KEY` repository secret, and update the local fingerprint pin and this README:

```console
scripts/generate-signing-key.sh
```

The script requires an authenticated `gh` with permission to set repository secrets. It updates the local pin and README only after GitHub confirms that the private key was stored, and prints the fingerprint. Review and commit the updated files. The default key identity uses `github@heiber.im` and expires after two years; set `KEY_EMAIL`, `KEY_NAME`, or `KEY_LIFETIME` to override them.

The APT workflow derives and publishes the public key from the secret; no public key file is stored in the repository. The workflows compare the imported secret with `packaging/apt/fingerprint`. The daily workflow warns when the key is within 60 days of expiry and stops APT publication after it expires. Users must fetch the new signing key after a key rotation.

Enable GitHub Pages with the GitHub Actions source:

```console
gh api --method POST repos/moritzheiber/himmelblau-ubuntu-repo/pages -f build_type=workflow
```

After pushing the repository setup, manually run the Release workflow once to publish the current upstream stable version:

```console
gh workflow run release.yml
```

If a release succeeds but APT publication fails, manually rerun the APT repository workflow after resolving the failure.

To rotate the key, run the generator again, update the fingerprint in this README, commit and push both changes, then manually run the APT repository workflow to publish the new key immediately:

```console
gh workflow run apt-repo.yml
```
