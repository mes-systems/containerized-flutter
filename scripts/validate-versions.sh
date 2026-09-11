#!/usr/bin/env bash
set -euo pipefail

manifest="versions.json"
if (( $# > 1 )); then
  printf 'usage: %s [versions.json]\n' "$0" >&2
  exit 2
fi
if (( $# == 1 )); then
  manifest="$1"
fi

fail() {
  printf 'versions.json: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ -f "$manifest" ]] || fail "file not found: $manifest"
jq -e . "$manifest" >/dev/null || fail "invalid JSON"

schema="$(jq -er '.schema' "$manifest")" || fail "missing schema"
[[ "$schema" == "1" ]] || fail "schema must be 1"
[[ "$(jq -er '.versions | type' "$manifest")" == "array" ]] \
  || fail "versions must be an array"
(( "$(jq -er '.versions | length' "$manifest")" > 0 )) \
  || fail "versions must not be empty"

duplicates="$(jq -r '.versions[].version' "$manifest" | sort | uniq -d)"
[[ -z "$duplicates" ]] || fail "duplicate Flutter version: $duplicates"

while IFS= read -r entry; do
  version="$(jq -er '.version | select(type == "string" and length > 0)' <<< "$entry")" \
    || fail "version must be a non-empty string"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "invalid version: $version"

  channel="$(jq -er '.channel | select(type == "string")' <<< "$entry")" \
    || fail "channel must be a string for $version"
  [[ "$channel" == "stable" ]] || fail "unsupported channel for $version: $channel"

  revision="$(jq -er '.revision | select(type == "string")' <<< "$entry")" \
    || fail "revision must be a string for $version"
  [[ "$revision" =~ ^[0-9a-fA-F]{40}$ ]] \
    || fail "revision must be exactly 40 hexadecimal characters for $version"

  archive="$(jq -er '.archive | select(type == "string" and length > 0)' <<< "$entry")" \
    || fail "archive must be a non-empty string for $version"
  expected_archive="$channel/linux/flutter_linux_"$version"-"$channel".tar.xz"
  [[ "$archive" == "$expected_archive" ]] \
    || fail "archive does not match version/channel for $version"

  archive_sha256="$(jq -er '.archive_sha256 | select(type == "string")' <<< "$entry")" \
    || fail "archive_sha256 must be a string for $version"
  [[ "$archive_sha256" =~ ^[0-9a-fA-F]{64}$ ]] \
    || fail "archive_sha256 must be exactly 64 hexadecimal characters for $version"
done < <(jq -c '.versions[]' "$manifest")

printf 'valid: %s\n' "$manifest"
