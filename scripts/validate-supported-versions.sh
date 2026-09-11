#!/usr/bin/env bash
set -euo pipefail

manifest="supported_version.json"
if (( $# > 1 )); then
  printf 'usage: %s [supported_version.json]\n' "$0" >&2
  exit 2
fi
if (( $# == 1 )); then
  manifest="$1"
fi

fail() {
  printf '%s: %s\n' "$manifest" "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ -f "$manifest" ]] || fail "file not found"
jq -e . "$manifest" >/dev/null || fail "invalid JSON"

schema="$(jq -er '.schema | select(type == "number" and floor == .)' "$manifest")" \
  || fail "missing schema"
[[ "$schema" == "2" ]] || fail "schema must be 2"

[[ "$(jq -er '.support_policy | type' "$manifest")" == "object" ]] \
  || fail "support_policy must be an object"
policy_channel="$(jq -er '.support_policy.channel | select(type == "string")' "$manifest")" \
  || fail "support_policy.channel must be a string"
[[ "$policy_channel" == "stable" ]] \
  || fail "unsupported support policy channel: $policy_channel"

minor_lines="$(jq -er \
  '.support_policy.minor_lines | select(type == "number" and floor == . and . > 0)' \
  "$manifest")" || fail "support_policy.minor_lines must be a positive integer"
[[ "$minor_lines" =~ ^[1-9][0-9]*$ ]] \
  || fail "support_policy.minor_lines must be a positive integer"

selection="$(jq -er '.support_policy.selection | select(type == "string")' "$manifest")" \
  || fail "support_policy.selection must be a string"
[[ "$selection" == "latest_patch_per_minor" ]] \
  || fail "unsupported support policy selection: $selection"

platforms_json="$(jq -cer \
  '.support_policy.platforms
   | select(type == "array" and length > 0 and all(.[]; type == "string" and length > 0))' \
  "$manifest")" || fail "support_policy.platforms must be a non-empty string array"
platform_count="$(jq -er 'length' <<< "$platforms_json")" \
  || fail "support_policy.platforms length is unavailable"
unique_platform_count="$(jq -er 'unique | length' <<< "$platforms_json")" \
  || fail "support_policy.platforms uniqueness is unavailable"
[[ "$platform_count" == "$unique_platform_count" ]] \
  || fail "support_policy.platforms must contain unique platforms"
[[ "$platform_count" == "1" ]] || fail 'PR 1 supports exactly one platform: linux/amd64'
platform="$(jq -er '.[0]' <<< "$platforms_json")"
[[ "$platform" == "linux/amd64" ]] || fail "unsupported platform: $platform"

[[ "$(jq -er '.supported_versions | type' "$manifest")" == "array" ]] \
  || fail "supported_versions must be an array"
supported_count="$(jq -er '.supported_versions | length' "$manifest")" \
  || fail "supported_versions length is unavailable"
(( supported_count > 0 )) || fail "supported_versions must not be empty"
(( supported_count <= minor_lines )) \
  || fail "supported_versions exceeds support_policy.minor_lines"

while IFS= read -r entry; do
  if ! jq -e 'keys | sort == ["artifacts", "channel", "revision", "version"]' <<< "$entry" >/dev/null; then
    fail 'supported version entry has invalid fields'
  fi
  version="$(jq -er '.version | select(type == "string" and length > 0)' <<< "$entry")" \
    || fail "version must be a non-empty string"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "invalid version: $version"

  channel="$(jq -er '.channel | select(type == "string")' <<< "$entry")" \
    || fail "channel must be a string for $version"
  [[ "$channel" == "$policy_channel" ]] \
    || fail "unsupported channel for $version: $channel"

  revision="$(jq -er '.revision | select(type == "string")' <<< "$entry")" \
    || fail "revision must be a string for $version"
  [[ "$revision" =~ ^[0-9a-fA-F]{40}$ ]] \
    || fail "revision must be exactly 40 hexadecimal characters for $version"

  [[ "$(jq -er '.artifacts | type' <<< "$entry")" == "object" ]] \
    || fail "artifacts must be an object for $version"
  if ! jq -e --argjson expected "$platforms_json" \
    '.artifacts | keys | sort == ($expected | sort)' <<< "$entry" >/dev/null; then
    fail "artifacts must contain exactly support_policy.platforms for $version"
  fi
  for platform in "$platform"; do
    artifact="$(jq -ce --arg platform "$platform" \
      '.artifacts[$platform] | select(type == "object")' <<< "$entry")" \
      || fail "artifact must be an object for $version on $platform"
    if ! jq -e 'keys | sort == ["archive", "archive_sha256", "upstream_arch"]' <<< "$artifact" >/dev/null; then
      fail "invalid artifact fields for $version on $platform"
    fi
    upstream_arch="$(jq -er '.upstream_arch | select(type == "string")' <<< "$artifact")" \
      || fail "upstream_arch must be a string for $version on $platform"
    [[ "$upstream_arch" == "x64" ]] \
      || fail "upstream_arch must be x64 for $version on $platform"

    archive="$(jq -er '.archive | select(type == "string" and length > 0)' <<< "$artifact")" \
      || fail "archive must be a non-empty string for $version on $platform"
    expected_archive="$channel/linux/flutter_linux_"$version"-"$channel".tar.xz"
    [[ "$archive" == "$expected_archive" ]] \
      || fail "archive does not match version/channel for $version on $platform"

    archive_sha256="$(jq -er '.archive_sha256 | select(type == "string")' <<< "$artifact")" \
      || fail "archive_sha256 must be a string for $version on $platform"
    [[ "$archive_sha256" =~ ^[0-9a-fA-F]{64}$ ]] \
      || fail "archive_sha256 must be exactly 64 hexadecimal characters for $version on $platform"
  done
done < <(jq -c '.supported_versions[]' "$manifest")

duplicates="$(jq -r '.supported_versions[].version' "$manifest" | sort | uniq -d)"
[[ -z "$duplicates" ]] || fail "duplicate Flutter version: $duplicates"

duplicates="$(jq -r \
  '.supported_versions[].version | split(".") | "\(.[0]).\(.[1])"' \
  "$manifest" | sort | uniq -d)"
[[ -z "$duplicates" ]] || fail "duplicate Flutter minor line: $duplicates"

printf 'valid: %s\n' "$manifest"
