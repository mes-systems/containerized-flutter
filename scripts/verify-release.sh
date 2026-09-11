#!/usr/bin/env bash
set -euo pipefail

if (( $# < 7 || $# > 8 )); then
  printf 'usage: %s PLATFORM VERSION CHANNEL EXPECTED_REVISION EXPECTED_ARCHIVE EXPECTED_ARCHIVE_SHA256 ARCHIVE_PATH [OUTPUT_FILE]\n' "$0" >&2
  exit 2
fi

platform="$1"
version="$2"
channel="$3"
expected_revision="$4"
expected_archive="$5"
expected_archive_sha256="$6"
archive_path="$7"
output_file=""
if (( $# == 8 )); then
  output_file="$8"
fi

fail() {
  printf 'release verification failed: %s\n' "$*" >&2
  exit 1
}

upstream_arch=""
case "$platform" in
  linux/amd64)
    upstream_arch="x64"
    ;;
  *)
    fail "unsupported Flutter platform: $platform"
    ;;
esac

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid Flutter version"
[[ "$channel" == "stable" ]] || fail "unsupported Flutter channel: $channel"
[[ "$expected_revision" =~ ^[0-9a-fA-F]{40}$ ]] \
  || fail "revision must be exactly 40 hexadecimal characters"
[[ "$expected_archive" != /* && "$expected_archive" != *://* && "$expected_archive" != *..* && "$expected_archive" == */* ]] \
  || fail "expected archive must be a relative path"
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

if ! jq -e 'type == "object" and (.releases | type == "array")' "$manifest_path" >/dev/null; then
  fail "malformed release manifest"
fi

release_count="$(jq -er \
  --arg version "$version" \
  --arg channel "$channel" \
  --arg upstream_arch "$upstream_arch" \
  '[.releases[] | select(.version == $version and .channel == $channel and .dart_sdk_arch == $upstream_arch)] | length' \
  "$manifest_path")" || fail "malformed release manifest"
[[ "$release_count" == "1" ]] || fail "expected exactly one matching release, found $release_count"

release_record="$(jq -ce \
  --arg version "$version" \
  --arg channel "$channel" \
  --arg upstream_arch "$upstream_arch" \
  '[.releases[] | select(.version == $version and .channel == $channel and .dart_sdk_arch == $upstream_arch)] | .[0]' \
  "$manifest_path")" || fail "matching release is malformed"
release_arch="$(jq -er '.dart_sdk_arch | select(type == "string")' <<< "$release_record")" \
  || fail "release architecture is missing"
release_version="$(jq -er '.version | select(type == "string")' <<< "$release_record")" \
  || fail "release version is missing"
release_channel="$(jq -er '.channel | select(type == "string")' <<< "$release_record")" \
  || fail "release channel is missing"
release_archive="$(jq -er '.archive | select(type == "string")' <<< "$release_record")" \
  || fail "release archive is missing"
release_revision="$(jq -er '.hash | select(type == "string")' <<< "$release_record")" \
  || fail "release revision is missing"
release_sha256="$(jq -er '.sha256 | select(type == "string")' <<< "$release_record")" \
  || fail "release SHA256 is missing"

[[ "$release_arch" == "$upstream_arch" ]] || fail "release architecture does not match $platform"
[[ "$release_version" == "$version" ]] || fail "version differs from official manifest"
[[ "$release_channel" == "$channel" ]] || fail "channel differs from official manifest"
[[ "$release_archive" == "$expected_archive" ]] || fail "archive differs from official manifest"
[[ "$release_revision" == "$expected_revision" ]] || fail "revision differs from official manifest"
[[ "$release_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || fail "official manifest has an invalid SHA256"
[[ "$release_sha256" == "$expected_archive_sha256" ]] \
  || fail "official manifest SHA256 differs from supported_version.json"

# Future hardening belongs here: authenticate the adjacent SLSA/DSSE bundle
# before accepting the release-manifest SHA256 as the upstream trust root.
actual_sha256="$(sha256sum -- "$archive_path" | awk '{print $1}')"
[[ "$actual_sha256" == "$expected_archive_sha256" ]] \
  || fail "local archive SHA256 differs from supported_version.json"

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

printf 'verified release %s (%s, %s): %s\n' "$version" "$channel" "$platform" "$actual_sha256" >&2
printf '%s\n' "$actual_sha256"
