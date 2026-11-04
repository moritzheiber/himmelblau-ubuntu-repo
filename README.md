# Himmelblau APT repository

This unofficial repository provides the latest stable Himmelblau packages for amd64 on Ubuntu 24.04 (noble) and Ubuntu 26.04 (resolute). Packages are built from upstream stable tags and published under the upstream version with the upstream release suffix, for example `4.0.7-ubuntu24.04`.

## Install

Add the signing key and the APT source for your Ubuntu release, then install:

```console
curl -fsSL https://moritzheiber.github.io/himmelblau-ubuntu-repo/himmelblau.gpg | sudo tee /etc/apt/keyrings/himmelblau.gpg > /dev/null
sudo curl -fsSL "https://moritzheiber.github.io/himmelblau-ubuntu-repo/himmelblau-$(. /etc/os-release && echo "$VERSION_CODENAME").sources" -o /etc/apt/sources.list.d/himmelblau.sources
sudo apt update
sudo apt install himmelblau
```

The archive signing key fingerprint is `B563445F0C1712C32DDB87632EA11CE5BE133BAE`. Verify it with `gpg --show-keys /etc/apt/keyrings/himmelblau.gpg`.

GitHub releases contain the package files. Each release and the APT repository page link to the source archive for that upstream tag.

## Packages

Every `.deb` produced by the upstream Ubuntu builds is included in the GitHub release and the APT repository. For upstream `4.0.7`, these are:

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

Additional packages can be installed individually, for example `sudo apt install himmelblau-sso`. Each distribution's package set matches the files produced by upstream's build for that Ubuntu release.

## Maintainers

`packaging/apt/releases` lists the supported Ubuntu releases, one `VERSION CODENAME` pair per line. Each release maps to the upstream Make target `ubuntuVERSION` and the APT distribution `CODENAME`.

The daily Release workflow checks for the highest stable upstream `X.Y.Z` tag and builds packages for every listed release in parallel with the upstream Make targets. For a new tag, it creates a GitHub release with all packages. When the latest GitHub release has no packages for a listed release, the workflow builds them and adds them to that release. Every built package must match the release version, Ubuntu suffix and amd64 architecture.

The APT workflow publishes one signed distribution per listed release and one `himmelblau-CODENAME.sources` file per distribution. Each package goes to the distribution matching its version suffix. Before deployment, it checks that each distribution's package index contains every package for that release with the expected name, version, and architecture. The APT archive contains packages from the latest release. Source archives remain available from their upstream tags.

The APT index preserves each package's section and priority, using `misc` and `optional` for missing values.

The build workflow caches `upstream/target/ubuntuVERSION` per release between builds. Cache keys include the Ubuntu release, architecture, upstream build recipe, lockfile, and release tag. Cargo checks restored output during each build. GitHub evicts caches after seven days without use.

### Signing key

Generate the repository's ed25519 key, store its private half as the `APT_GPG_PRIVATE_KEY` repository secret, and update the local fingerprint pin and this README:

```console
scripts/generate-signing-key.sh
```

The script requires an authenticated `gh` with permission to set repository secrets. It updates the local pin and README only after GitHub confirms that the private key was stored, and prints the fingerprint. Review and commit the updated files. The default key identity uses `github@heiber.im` and expires after two years; set `KEY_EMAIL`, `KEY_NAME`, or `KEY_LIFETIME` to override them.

The APT workflow derives the public key from the secret and publishes it with the archive. The workflows compare the imported secret with the fingerprint in `packaging/apt/fingerprint`. The daily workflow warns when the key has 60 days or less before expiry and stops APT publication after it expires. After a key rotation, users need to fetch the new signing key.

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
