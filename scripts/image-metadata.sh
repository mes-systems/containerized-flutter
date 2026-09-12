#!/usr/bin/env bash
set -euo pipefail

if (( $# != 4 )); then
  printf 'usage: %s FLUTTER_VERSION REPOSITORY_GIT_SHA BASE_ID SUPPORTED_BASE_MANIFEST\n' "$0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
flutter_version="$1"
repository_sha="$2"
base_id="$3"
base_manifest="$4"

fail() {
  printf 'image metadata failed: %s\n' "$*" >&2
  exit 1
}

[[ "$flutter_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail 'invalid Flutter version'
[[ "$repository_sha" =~ ^[0-9a-fA-F]{40}$ ]] \
  || fail 'repository SHA must be 40 hexadecimal characters'
[[ -n "$base_id" ]] || fail 'base ID must not be empty'
[[ -f "$base_manifest" ]] || fail "base manifest not found: $base_manifest"

"$SCRIPT_DIR/validate-supported-bases.sh" "$base_manifest" >/dev/null \
  || fail "invalid base manifest: $base_manifest"

base="$(jq -cer --arg id "$base_id" '
  [.bases[] | select(.id == $id)]
  | if length == 1 then .[0] else error("base ID must resolve to exactly one entry") end
' "$base_manifest")" || fail "unknown base ID: $base_id"
base_family="$(jq -er '.family' <<< "$base")" || fail 'base family is missing'
base_version="$(jq -er '.version' <<< "$base")" || fail 'base version is missing'
base_variant="$(jq -er '.variant' <<< "$base")" || fail 'base variant is missing'
base_reference="$(jq -er '.reference' <<< "$base")" || fail 'base reference is missing'

[[ "$base_reference" =~ @sha256:([0-9a-fA-F]{64})$ ]] \
  || fail 'base reference must contain a full SHA256 digest'
base_digest="$(printf '%s' "${base_reference##*@}" | tr '[:upper:]' '[:lower:]')"
base_digest_short="${base_digest#sha256:}"
base_digest_short="${base_digest_short:0:12}"
repository_sha_short="$(printf '%.12s' "$repository_sha" | tr '[:upper:]' '[:lower:]')"
tag="$flutter_version-$base_id-$base_digest_short"
build_tag="$tag-g$repository_sha_short"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

emit flutter_version "$flutter_version"
emit base_id "$base_id"
emit base_family "$base_family"
emit base_version "$base_version"
emit base_variant "$base_variant"
emit base_reference "$base_reference"
emit base_digest "$base_digest"
emit base_digest_short "$base_digest_short"
emit repository_sha_short "$repository_sha_short"
emit tag "$tag"
emit build_tag "$build_tag"
