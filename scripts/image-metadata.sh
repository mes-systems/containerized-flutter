#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
  printf 'usage: %s FLUTTER_VERSION REPOSITORY_GIT_SHA DOCKERFILE_PATH\n' "$0" >&2
  exit 2
fi

flutter_version="$1"
repository_sha="$2"
dockerfile="$3"

fail() {
  printf 'image metadata failed: %s\n' "$*" >&2
  exit 1
}

[[ "$flutter_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid Flutter version"
[[ "$repository_sha" =~ ^[0-9a-fA-F]{40}$ ]] || fail "repository SHA must be 40 hexadecimal characters"
[[ -f "$dockerfile" ]] || fail "Dockerfile not found: $dockerfile"

from_line="$(awk '$1 == "FROM" { print; count++ } END { if (count != 1) exit 1 }' "$dockerfile")" \
  || fail "Dockerfile must have exactly one FROM line"
base_fields="$(printf '%s\n' "$from_line" | sed -nE \
  's/^FROM[[:space:]]+ubuntu:([0-9]+\.[0-9]+)@sha256:([0-9a-fA-F]{64})[[:space:]]*$/\1 \2/p')"
[[ "$base_fields" =~ ^[0-9]+\.[0-9]+[[:space:]][0-9a-fA-F]{64}$ ]] \
  || fail "FROM must be a literal ubuntu version pinned by a full SHA256"

ubuntu_version="$(printf '%s\n' "$base_fields" | awk '{print $1}')"
ubuntu_digest="$(printf '%s\n' "$base_fields" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')"
ubuntu_digest_short="$(printf '%.12s' "$ubuntu_digest")"
repository_sha_short="$(printf '%.12s' "$repository_sha" | tr '[:upper:]' '[:lower:]')"
tag="$flutter_version-ubuntu$ubuntu_version-$ubuntu_digest_short"
build_tag="$tag-g$repository_sha_short"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

emit flutter_version "$flutter_version"
emit ubuntu_version "$ubuntu_version"
emit ubuntu_digest "sha256:$ubuntu_digest"
emit ubuntu_digest_short "$ubuntu_digest_short"
emit repository_sha_short "$repository_sha_short"
emit tag "$tag"
emit build_tag "$build_tag"
