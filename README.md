# Containerized Flutter

<p>
  <img src="https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/Linux%20amd64-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Linux amd64">
  <img src="https://img.shields.io/badge/GHCR-181717?style=for-the-badge&logo=github&logoColor=white" alt="GHCR">
</p>

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

The published container has two complementary output trust boundaries:

BuildKit provenance:
describes how the OCI image was built. The workflows use this contract:

- SLSA provenance format: v1
- BuildKit provenance mode: max
- SBOM format: SPDX

GitHub Artifact Attestation:
authenticates that the exact published digest came from the trusted mes-systems/containerized-flutter GitHub workflow. It is created only after
the local build, local attestation checks, smoke test, build-qualified push,
and remote provenance/SBOM verification succeed.

## Base image trust

Base images are maintainer-reviewed build inputs. Every supported base is
listed in `supported_bases.json` and pinned to one immutable SHA256 reference;
the manifest is the only base-image trust source. The Dockerfile does not
choose a distribution or provide a fallback: both stages consume the validated
`BASE_IMAGE` supplied by CI or publication.

The current support list contains Ubuntu 24.04, Ubuntu 26.04, Debian 13, and
Debian 13 Slim. The Ubuntu bases are supported in parallel as separate
immutable release lines.

<!-- BEGIN GENERATED SUPPORTED BASES -->
| Base ID | Family | Version | Variant | Digest |
| --- | --- | --- | --- | --- |
| `ubuntu24.04` | ubuntu | 24.04 | default | `sha256:69cecf4bbf72...` |
| `ubuntu26.04` | ubuntu | 26.04 | default | `sha256:cd21a4f68a61...` |
| `debian13` | debian | 13 | default | `sha256:f324c7ff5432...` |
| `debian13-slim` | debian | 13 | slim | `sha256:d7e12182ce18...` |
<!-- END GENERATED SUPPORTED BASES -->

Debian 13 default and Debian 13 Slim are supported.

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
| 3.47.4 | stable | `9584c6713b324636289d067944a46fd6b49df14b` | `5b45f0ceda99b9bebdc873e7e69f6450aeb4c30f454b505e2e62fc9255a907d3` |
<!-- END GENERATED SUPPORTED FLUTTER RELEASES -->

The initial image target is Linux amd64 only.

## Images

Images are published as:

```
ghcr.io/mes-systems/containerized-flutter
```

The canonical human-readable tag is:

`{flutter_version}-{base_id}-{base_digest_short}`

For example:

```
3.47.3-ubuntu24.04-224a1869083a
```

The source-revision-qualified build tag adds the first 12 characters of the
repository Git SHA:

`{flutter_version}-{base_id}-{base_digest_short}-g<repository_sha_short>`

The first tag identifies the Flutter and base inputs. The second also
identifies the source revision used for the container build. Neither tag is a
substitute for the final immutable identity. For strict artifact identity, pin
the exact OCI digest:

```
docker pull ghcr.io/mes-systems/containerized-flutter@sha256:<oci-digest>
```

No latest, stable, or bare Flutter-version alias is published.
Strict consumers should continue to pin the exact OCI digest.

Embedded provenance and SBOM descriptors are part of the top-level OCI index,
so independent rebuilds can produce different top-level OCI digests even when
their platform image is equivalent. This is expected: the reproducibility
contract is exact published artifact => exact OCI digest, not guaranteed
identical OCI index bytes for independent rebuilds.

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

BuildKit provenance and the SPDX SBOM for a published image can be inspected
by exact OCI digest:

```
docker buildx imagetools inspect \
  ghcr.io/mes-systems/containerized-flutter@sha256:<digest> \
  --format '{{json .Provenance.SLSA}}' | jq .
```

```
docker buildx imagetools inspect \
  ghcr.io/mes-systems/containerized-flutter@sha256:<digest> \
  --format '{{json .SBOM.SPDX}}' | jq .
```

To verify the GitHub Artifact Attestation for the same published digest:

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

- Environment variable: `FLUTTER_WATCHER_CLIENT_ID`
- Environment secret: `FLUTTER_WATCHER_PRIVATE_KEY`

Install the dedicated least-privilege GitHub App with Metadata read, Contents
read/write, Pull requests read/write, and Issues read/write permissions. Do not
use repository-level equivalents or a PAT. The watcher discovers releases,
creates its proposal commit through GitHub's API from current `main`, and
proposes a PR; it does not modify `main` or merge automatically. GitHub signs
those API-created commits and marks them verified when supported, so this
repository stores no persistent commit-signing private key. Ordinary PR CI
remains the acceptance gate.

Dependabot checks pinned GitHub Actions revisions weekly. Docker Dependabot is
not configured because `FROM ${BASE_IMAGE}` is resolved from the maintainer-
reviewed `supported_bases.json` manifest. A dedicated base watcher updates
`supported_bases.json` by checking upstream Docker Hub tags weekly and
proposing digest changes through a normal pull request. Base changes are never
merged automatically; merging a base digest update selectively republishes
every supported Flutter version for that base.

The base watcher uses the existing repository Environment named
`flutter-release-watcher`. Configure it for the `main` branch/ref with no
required reviewer and add only:

- Environment variable: `FLUTTER_WATCHER_CLIENT_ID`
- Environment secret: `FLUTTER_WATCHER_PRIVATE_KEY`

## CI and maintenance

PR CI and registry publication intentionally use different scopes. CI fails
safe: README/docs-only changes run no image builds, support-manifest-only
changes use the affected image matrix, and any unknown or common
build-affecting change runs the full supported Flutter/base validation matrix.

Automatic main-branch publication is narrower:

- Dockerfile, `.dockerignore`, and image metadata changes rebuild the full
  active matrix;
- supported-version and supported-base manifest changes use the selective
  publication planner;
- validation, matrix-planning, publication-planning, workflow, documentation,
  and test changes do not widen publication scope by themselves.

A control-plane change combined with a manifest update therefore keeps the
manifest's selective scope. Manual workflow dispatch explicitly forces the
full publication matrix. A supported-version change publishes changed Flutter
releases across all current bases; a supported-base digest change publishes
all current Flutter releases for that base.
Retired GHCR artifacts are not deleted. Watcher PRs still pass through this
ordinary CI gate and the watcher does not bypass release verification or image
tests. Manual CI dispatch always runs the full matrix.
