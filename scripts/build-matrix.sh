#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  printf 'usage: %s SUPPORTED_VERSION_MANIFEST SUPPORTED_BASE_MANIFEST\n' "$0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
versions="$1"
bases="$2"

fail() {
  printf 'build matrix failed: %s\n' "$*" >&2
  exit 1
}

[[ -f "$versions" ]] || fail "Flutter manifest not found: $versions"
[[ -f "$bases" ]] || fail "base manifest not found: $bases"
"$SCRIPT_DIR/validate-supported-versions.sh" "$versions" >/dev/null \
  || fail "invalid Flutter manifest: $versions"
# Structural mode lets direct tests exercise future multi-base fixtures. CI and
# publication validate their production manifest in strict production mode first.
"$SCRIPT_DIR/validate-supported-bases.sh" --allow-multiple "$bases" >/dev/null \
  || fail "invalid base manifest: $bases"

if ! jq -c --slurpfile base_manifest "$bases" '
  {include: [
    .supported_versions[] as $version
    | $base_manifest[0].bases[] as $base
    | {
        version: $version.version,
        channel: $version.channel,
        revision: $version.revision,
        archive: $version.archive,
        archive_sha256: $version.archive_sha256,
        base_id: $base.id,
        base_family: $base.family,
        base_version: $base.version,
        base_variant: $base.variant,
        base_reference: $base.reference
      }
  ]}' "$versions"; then
  fail 'could not build matrix'
fi
