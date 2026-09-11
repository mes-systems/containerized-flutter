# Containerized Flutter

This repository builds a reusable Linux amd64 Flutter SDK/toolchain image. It
acquires official Flutter release archives before the Docker build, checks the
release metadata and archive digest, and publishes versioned images to GHCR.

## Trust model

The first release uses `supported_version.json` as the maintainer-reviewed
persistent trust root for the currently supported releases. It is an active
support manifest, not an archive of upstream Flutter history. Each entry pins
the Flutter version, stable channel, official archive path, Git revision, and
archive SHA256.

scripts/verify-release.sh downloads the official
releases_linux.json, requires exactly one matching stable Linux x64 release, checks that all
of its release metadata matches the pinned entry, and independently hashes the
already acquired archive. The Dockerfile checks that same digest again before
extracting the SDK, then verifies the extracted Git revision and Flutter tag.

Flutter also publishes SLSA/in-toto bundles next to its archives. Acquisition
best-effort downloads those bundles for diagnostics when available, but their
current LUCI/BCID signing key is not externally usable through a stable public
verification path.
For example, the 3.47.3 bundle is SLSA v0.2 from
`//bcid.corp.google.com/builders/luci`, with no
usable version-controlled Flutter source URI. Its subject SHA256 is useful for
diagnostics only.
Cryptographic SLSA/DSSE validation is therefore deliberately deferred; it is
not emulated or implied by this release. Future hardening belongs between
acquisition and the pinned SHA256 check.

The published container has a separate output trust boundary: the tested
image is pushed to GHCR and receives a GitHub Artifact Attestation bound to its
exact OCI digest.

## Supported releases

Containerized Flutter actively maintains the latest patch release of up to four
active stable Flutter minor release lines. The policy is encoded in
`supported_version.json` as `minor_lines: 4` and
`selection: latest_patch_per_minor`.

A new patch release for an existing minor line replaces its current entry. A
new stable minor line newer than the active window adds its newest release;
historical lines never backfill unused capacity. Once four lines are supported,
the oldest line is retired. Superseded or retired releases are removed from
the active support manifest and are no longer rebuilt when the base image or
packaging changes. Previously published image tags and OCI digests remain
available in GHCR, but there is no ongoing rebuild/support guarantee for those
releases.

<!-- BEGIN GENERATED SUPPORTED FLUTTER RELEASES -->
| Flutter | Channel | Git revision | SDK archive SHA256 |
| --- | --- | --- | --- |
| 3.41.9 | stable | `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694` | `cf2631dde02570733921a530f47a96abe896b5e334682d2743c29530ea88bb2e` |
| 3.44.9 | stable | `6b182d2c7585eba26d4edce0f97630effd256c33` | `a9120fa4a01048bdef438ddc3a2d4b7389662ea98a95db86eeaf10382bc4efcb` |
| 3.47.3 | stable | `e8113bf45620cbeb8aff64947ee4c93e16adb4cf` | `988665565cad9091db1baa54bf6d3868bb40e29719592f3c3a164deefd4208e1` |
<!-- END GENERATED SUPPORTED FLUTTER RELEASES -->

The initial image target is Linux amd64 only.

## Images

Images are published as:

```
ghcr.io/mes-systems/containerized-flutter
```

The canonical human-readable tag is:

`{flutter_version}-ubuntu{ubuntu_version}-{ubuntu_digest_short}`

For example:

```
3.47.3-ubuntu24.04-a61567bd3182
```

The source-revision-qualified build tag adds the first 12 characters of the
repository Git SHA:

`{flutter_version}-ubuntu{ubuntu_version}-{ubuntu_digest_short}-g<repository_sha_short>`

The first tag identifies the Flutter and Ubuntu inputs. The second also
identifies the source revision used for the container build. Neither tag is a
substitute for the final immutable identity. For strict reproducibility, pin
the exact OCI digest:

```
docker pull ghcr.io/mes-systems/containerized-flutter@sha256:<oci-digest>
```

No latest, stable, or bare Flutter-version alias is published.

## Verification

Upstream release verification is run by both pull-request CI and the trusted
main publication workflow. Both workflows use the same repository scripts:

```
scripts/acquire-flutter.sh 3.47.3 stable .artifacts
scripts/verify-release.sh \
  3.47.3 \
  stable \
  e8113bf45620cbeb8aff64947ee4c93e16adb4cf \
  988665565cad9091db1baa54bf6d3868bb40e29719592f3c3a164deefd4208e1 \
  .artifacts/flutter-sdk.tar.xz
```

The attestation file is an optional diagnostic download in this release. Its
absence or contents do not affect release acceptance. A changed archive,
release-manifest mismatch, revision mismatch, or Flutter tag mismatch fails
closed.

To verify provenance for a published image:

```
gh attestation verify \
  oci://ghcr.io/mes-systems/containerized-flutter@sha256:<oci-digest> \
  -R mes-systems/containerized-flutter
```

## Image contents

The image contains Ubuntu 24.04, the Flutter SDK, its Git metadata, and only
the generic Linux prerequisites needed by the SDK:

```
ca-certificates curl git libglu1-mesa unzip xz-utils zip
```

It does not contain Python, Android SDKs, Chrome, Node.js, Java, Gradle,
desktop or mobile toolchains, application source, or application-specific pub
packages. flutter precache and flutter pub get are not run during the
Docker build. The image is a toolchain image, not an application image.

The committed smoke fixture runs flutter pub get and flutter test --no-pub
inside a temporary writable copy at test time. It never writes generated
files into the repository checkout.

## Adding a Flutter release

The daily watcher normally discovers and proposes these changes itself. If it
reports a security anomaly, a maintainer must compare the trusted and upstream
metadata before intentionally changing the trust root. Any intentional update
must use the official release version, stable channel, 40-character Git
revision, official archive path, and 64-character SHA256; do not guess or copy
a digest from an unverified file. Run:

```
scripts/validate-supported-versions.sh supported_version.json
```

The manifest is intentionally limited to the active support window rather
than expanded into a historical release list. A daily watcher discovers valid
stable Linux x64 releases from the official release manifest and proposes
manifest and README updates in one pull request. Acceptance remains
maintainer-reviewed through that PR; the watcher never silently changes the
trust-root metadata for an already supported exact release. The same
release-manifest and local archive checks run in CI and before publication.

## Watcher setup

The watcher requires a repository Environment named `flutter-release-watcher`.
Configure it for the `main` branch/ref with no required reviewer; the workflow
sets `deployment: false` because it is not a deployment workflow. Add only:

- Environment variable: `FLUTTER_WATCHER_APP_ID`
- Environment secret: `FLUTTER_WATCHER_PRIVATE_KEY`

Install the dedicated least-privilege GitHub App with Metadata read, Contents
read/write, Pull requests read/write, and Issues read/write permissions. Do not
use repository-level equivalents or a PAT. The watcher discovers releases,
resets its stable automation branch from current `main`, and proposes a PR; it
does not modify `main` or merge automatically. Ordinary PR CI remains the
acceptance gate.

Dependabot checks the pinned Ubuntu 24.04 Docker digest weekly. When Ubuntu
changes, its short digest changes the public image tags, while previous tags
and OCI digests remain addressable. Dependabot also checks pinned GitHub
Actions revisions weekly.

## CI and maintenance

Documentation-only changes run the lightweight manifest and script validation
but do not rebuild the supported Flutter matrix. The shared change classifier
allows this only when every changed path is explicitly harmless; any unknown or
toolchain-relevant path defaults to full validation. Manual workflow dispatch
can force the full matrix, and a main-branch publication follows the same
classification before pushing or attesting images. A manifest-only publication
builds newly added or replacement Flutter versions only; Dockerfile, base-image,
or packaging changes rebuild the full active matrix. Retired GHCR artifacts are
not deleted. Watcher PRs still pass through this ordinary full-matrix CI gate;
the watcher does not bypass release verification or image tests.
