#!/usr/bin/env bash
set -euo pipefail

if (( $# < 5 || $# > 6 )); then
  printf 'usage: %s VERSION CHANNEL EXPECTED_REVISION EXPECTED_ARCHIVE_SHA256 ARCHIVE_PATH [OUTPUT_FILE]\n' "$0" >&2
  exit 2
fi

version="$1"
channel="$2"
expected_revision="$3"
expected_archive_sha256="$4"
archive_path="$5"
output_file=""
if (( $# == 6 )); then
  output_file="$6"
fi

fail() {
  printf 'release verification failed: %s\n' "$*" >&2
  exit 1
}

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid Flutter version"
[[ "$channel" == "stable" ]] || fail "unsupported Flutter channel: $channel"
[[ "$expected_revision" =~ ^[0-9a-fA-F]{40}$ ]] \
  || fail "revision must be exactly 40 hexadecimal characters"
[[ "$expected_archive_sha256" =~ ^[0-9a-fA-F]{64}$ ]] \
  || fail "archive SHA256 must be exactly 64 hexadecimal characters"
[[ -s "$archive_path" ]] || fail "archive is missing or empty: $archive_path"

archive_name="$(basename -- "$archive_path")"
[[ "$archive_name" == "flutter-sdk.tar.xz" ]] \
  || fail "archive must use the canonical staged filename flutter-sdk.tar.xz"

command -v jq >/dev/null 2>&1 || fail "jq is required"
manifest_path="$(mktemp /tmp/flutter-releases.XXXXXX)"
trap 'rm -f -- "$manifest_path"' EXIT

curl \
  --fail \
  --show-error \
  --location \
  --retry 5 \
  --retry-all-errors \
  --output "$manifest_path" \
  https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json

release_count="$(jq -er --arg version "$version" --arg channel "$channel" \
  '[.releases[]? | select(.version == $version and .channel == $channel)] | length' \
  "$manifest_path")" || fail "malformed release manifest"
[[ "$release_count" == "1" ]] || fail "expected exactly one matching release, found $release_count"

release_archive="$(jq -er --arg version "$version" --arg channel "$channel" \
  '.releases[] | select(.version == $version and .channel == $channel) | .archive' \
  "$manifest_path")" || fail "release archive is missing"
release_revision="$(jq -er --arg version "$version" --arg channel "$channel" \
  '.releases[] | select(.version == $version and .channel == $channel) | .hash' \
  "$manifest_path")" || fail "release revision is missing"
release_sha256="$(jq -er --arg version "$version" --arg channel "$channel" \
  '.releases[] | select(.version == $version and .channel == $channel) | .sha256' \
  "$manifest_path")" || fail "release SHA256 is missing"

expected_archive="$channel/linux/flutter_linux_"$version"-"$channel".tar.xz"
[[ "$release_archive" == "$expected_archive" ]] || fail "unexpected archive path in official manifest"
[[ "$release_revision" == "$expected_revision" ]] || fail "revision differs from official manifest"
[[ "$release_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || fail "official manifest has an invalid SHA256"
[[ "$release_sha256" == "$expected_archive_sha256" ]] \
  || fail "official manifest SHA256 differs from versions.json"

# Future hardening belongs here: authenticate the adjacent SLSA/DSSE bundle
# before accepting the release-manifest SHA256 as the upstream trust root.
actual_sha256="$(sha256sum -- "$archive_path" | awk '{print $1}')"
[[ "$actual_sha256" == "$expected_archive_sha256" ]] \
  || fail "local archive SHA256 differs from versions.json"

if [[ -n "$output_file" ]]; then
  output_parent="$(dirname -- "$output_file")"
  [[ -d "$output_parent" ]] || fail "output directory does not exist: $output_parent"
  output_tmp="$(mktemp "$output_file.XXXXXX")"
  printf 'archive_sha256=%s\n' "$actual_sha256" > "$output_tmp"
  mv -f "$output_tmp" "$output_file"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'archive_sha256=%s\n' "$actual_sha256" >> "$GITHUB_OUTPUT"
fi

printf 'verified release %s (%s): %s\n' "$version" "$channel" "$actual_sha256" >&2
printf '%s\n' "$actual_sha256"
