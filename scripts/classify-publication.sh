#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
diff_file=""
old_manifest=""
publication_mode=""

cleanup() {
  [[ -z "$diff_file" ]] || rm -f -- "$diff_file"
  [[ -z "$old_manifest" ]] || rm -f -- "$old_manifest"
}
trap cleanup EXIT

usage() {
  printf 'usage: %s --paths [PATH ...]\n' "$0" >&2
  printf '       %s --workflow-dispatch [MANIFEST]\n' "$0" >&2
  printf '       %s --revisions BASE_SHA HEAD_SHA [MANIFEST]\n' "$0" >&2
  exit 2
}

fail() {
  printf 'publication classification failed: %s\n' "$*" >&2
  exit 1
}

# ponytail: this explicit policy is intentionally reviewable, but it is a
# known ceiling. Any new Docker build-context or public tag input (for
# example supported_bases.json, distro variants, or architecture-specific
# files) must be added here and covered by a regression test in the same PR;
# a prior .dockerignore change cannot discover later edits to that input.
classify_path() {
  case "$1" in
    Dockerfile|.dockerignore|scripts/image-metadata.sh)
      printf 'full\n'
      ;;
    supported_version.json)
      printf 'selective\n'
      ;;
    *)
      printf 'none\n'
      ;;
  esac
}

merge_mode() {
  case "$1:$2" in
    full:*|*:full)
      printf 'full\n'
      ;;
    selective:*|*:selective)
      printf 'selective\n'
      ;;
    *)
      printf 'none\n'
      ;;
  esac
}

mode_for_paths() {
  local mode=none
  local path

  for path in "$@"; do
    mode="$(merge_mode "$mode" "$(classify_path "$path")")"
  done

  printf '%s\n' "$mode"
}

mode_for_diff() {
  local path
  local mode=none

  while IFS= read -r -d '' path; do
    mode="$(merge_mode "$mode" "$(classify_path "$path")")"
  done < "$1"

  printf '%s\n' "$mode"
}

validate_revision() {
  local name="$1"
  local revision="$2"

  [[ "$revision" =~ ^[[:xdigit:]]{40}$ ]] || fail "invalid $name SHA: $revision"
  git rev-parse --verify "${revision}^{commit}" >/dev/null 2>&1 \
    || fail "could not resolve $name revision: $revision"
}

mode_for_revisions() {
  local base_sha="$1"
  local head_sha="$2"

  validate_revision base "$base_sha"
  validate_revision head "$head_sha"

  if ! diff_file="$(mktemp "${TMPDIR:-/tmp}/classify-publication.XXXXXX")"; then
    fail 'could not create a temporary diff file'
  fi
  if ! git diff --name-only --no-renames -z "$base_sha" "$head_sha" -- > "$diff_file"; then
    fail "could not calculate changed paths for $base_sha..$head_sha"
  fi
  publication_mode="$(mode_for_diff "$diff_file")"
}

emit_mode() {
  printf 'publish_mode=%s\n' "$1"
}

plan() {
  local manifest="$1"
  local mode="$2"
  local base_sha="${3:-}"
  local matrix
  local publish_matrix='{"include":[]}'
  local publish_needed=false

  "$SCRIPT_DIR/validate-supported-versions.sh" "$manifest" >/dev/null \
    || fail "current manifest is invalid: $manifest"
  if ! matrix="$(jq -c '
    {include: [
      .supported_versions[] as $entry
      | $entry.artifacts | to_entries[] as $artifact
      | {
          version: $entry.version,
          platform: $artifact.key,
          channel: $entry.channel,
          revision: $entry.revision,
          upstream_arch: $artifact.value.upstream_arch,
          archive: $artifact.value.archive,
          archive_sha256: $artifact.value.archive_sha256,
          platform_slug: ($artifact.key | gsub("/"; "-"))
        }
    ]}
  ' "$manifest")"; then
    fail "could not build the current publication matrix"
  fi
  if ! jq -e '.include | type == "array"' <<< "$matrix" >/dev/null; then
    fail 'current publication matrix is malformed'
  fi

  case "$mode" in
    none)
      ;;
    full)
      publish_matrix="$matrix"
      publish_needed=true
      ;;
    selective)
      [[ -n "$base_sha" ]] || fail 'selective publication requires a base revision'
      if ! old_manifest="$(mktemp "${TMPDIR:-/tmp}/publish-old-manifest.XXXXXX")"; then
        fail 'could not create a temporary previous-manifest file'
      fi
      if ! git show "$base_sha:supported_version.json" > "$old_manifest"; then
        fail "could not read previous supported version manifest at $base_sha"
      fi
      if ! publish_matrix="$("$SCRIPT_DIR/publish-matrix.sh" "$old_manifest" "$manifest")"; then
        fail 'could not build the selective publication matrix'
      fi
      if ! jq -e '.include | type == "array"' <<< "$publish_matrix" >/dev/null; then
        fail 'selective publication matrix is malformed'
      fi
      if ! publish_needed="$(jq -r '.include | length > 0' <<< "$publish_matrix")"; then
        fail 'selective publication matrix has no valid length'
      fi
      ;;
    *)
      fail "invalid publication mode: $mode"
      ;;
  esac

  printf 'publish_mode=%s\n' "$mode"
  printf 'publish_matrix=%s\n' "$publish_matrix"
  printf 'publish_needed=%s\n' "$publish_needed"
}

if (( $# == 0 )); then
  usage
fi

case "$1" in
  --paths)
    shift
    emit_mode "$(mode_for_paths "$@")"
    ;;
  --workflow-dispatch)
    case "$#" in
      1)
        emit_mode full
        ;;
      2)
        plan "$2" full
        ;;
      *)
        usage
        ;;
    esac
    ;;
  --revisions)
    case "$#" in
      3)
        mode_for_revisions "$2" "$3"
        emit_mode "$publication_mode"
        ;;
      4)
        mode_for_revisions "$2" "$3"
        plan "$4" "$publication_mode" "$2"
        ;;
      *)
        usage
        ;;
    esac
    ;;
  *)
    usage
    ;;
esac
