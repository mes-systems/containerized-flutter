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

from_images="$(awk '
  $1 == "FROM" {
    image = ""
    for (i = 2; i <= NF; i++) {
      if ($i !~ /^--/) {
        image = $i
        break
      }
    }
    if (image == "") exit 1
    print image
  }
' "$dockerfile")" || fail "Dockerfile must contain valid FROM instructions"
[[ -n "$from_images" ]] || fail "Dockerfile must contain at least one FROM instruction"

base_fields="$(printf '%s\n' "$from_images" | sed -nE \
  's/^ubuntu:([0-9]+\.[0-9]+)@sha256:([0-9a-fA-F]{64})$/\1 \2/p')"
from_count="$(printf '%s\n' "$from_images" | awk 'NF { count++ } END { print count + 0 }')"
parsed_count="$(printf '%s\n' "$base_fields" | awk 'NF { count++ } END { print count + 0 }')"
[[ "$from_count" == "$parsed_count" ]] \
  || fail "every FROM must be a literal ubuntu version pinned by a full SHA256"
base_fields="$(printf '%s\n' "$base_fields" | awk '
  NR == 1 { first = $0 }
  $0 != first { mismatch = 1 }
  END {
    if (NR == 0 || mismatch) exit 1
    print first
  }
')" || fail "all FROM instructions must use the same pinned Ubuntu base"

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
