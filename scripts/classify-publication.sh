#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
diff_file=""
old_flutter_manifest=""
old_base_manifest=""

cleanup() {
  [[ -z "$diff_file" ]] || rm -f -- "$diff_file"
  [[ -z "$old_flutter_manifest" ]] || rm -f -- "$old_flutter_manifest"
  [[ -z "$old_base_manifest" ]] || rm -f -- "$old_base_manifest"
}
trap cleanup EXIT

usage() {
  printf 'usage: %s --paths [PATH ...]\n' "$0" >&2
  printf '       %s --workflow-dispatch SUPPORTED_VERSION_JSON SUPPORTED_BASES_JSON\n' "$0" >&2
  printf '       %s --revisions BASE_SHA HEAD_SHA SUPPORTED_VERSION_JSON SUPPORTED_BASES_JSON\n' "$0" >&2
  exit 2
}

fail() {
  printf 'publication classification failed: %s\n' "$*" >&2
  exit 1
}

# ponytail: this explicit policy is intentionally reviewable. Any new
# build-context, base-resolution, or public-tag input must be classified here
# and covered by a regression test in the same PR.
classify_path() {
  case "$1" in
    Dockerfile|.dockerignore|scripts/image-metadata.sh|scripts/build-matrix.sh|\
    scripts/validate-dockerfile.sh|scripts/validate-supported-bases.sh|\
    scripts/publish-matrix.sh|\
    scripts/classify-publication.sh)
      printf 'full\n'
      ;;
    supported_version.json|supported_bases.json)
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

git_path_for_manifest() {
  local manifest="$1"
  local repo_root

  if [[ "$manifest" == /* ]]; then
    repo_root="$(git rev-parse --show-toplevel)" \
      || fail 'could not resolve repository root for manifest'
    [[ "$manifest" == "$repo_root/"* ]] \
      || fail "manifest is outside the repository: $manifest"
    printf '%s\n' "${manifest#"$repo_root/"}"
  else
    printf '%s\n' "${manifest#./}"
  fi
}

plan() {
  local flutter_manifest="$1"
  local base_manifest="$2"
  local mode="$3"
  local base_sha="${4:-}"
  local matrix='{"include":[]}'
  local publish_needed=false

  "$SCRIPT_DIR/validate-supported-versions.sh" "$flutter_manifest" >/dev/null \
    || fail "current Flutter manifest is invalid: $flutter_manifest"
  "$SCRIPT_DIR/validate-supported-bases.sh" "$base_manifest" >/dev/null \
    || fail "current base manifest is invalid: $base_manifest"

  case "$mode" in
    none)
      ;;
    full)
      if ! matrix="$("$SCRIPT_DIR/build-matrix.sh" "$flutter_manifest" "$base_manifest")"; then
        fail 'could not build the full publication matrix'
      fi
      publish_needed=true
      ;;
    selective)
      [[ -n "$base_sha" ]] || fail 'selective publication requires a base revision'
      if ! old_flutter_manifest="$(mktemp "${TMPDIR:-/tmp}/publish-old-flutter.XXXXXX")"; then
        fail 'could not create a temporary previous Flutter manifest'
      fi
      if ! old_base_manifest="$(mktemp "${TMPDIR:-/tmp}/publish-old-bases.XXXXXX")"; then
        fail 'could not create a temporary previous base manifest'
      fi
      old_flutter_path="$(git_path_for_manifest "$flutter_manifest")"
      old_base_path="$(git_path_for_manifest "$base_manifest")"
      if ! git show "$base_sha:$old_flutter_path" > "$old_flutter_manifest"; then
        fail "could not read previous supported version manifest at $base_sha"
      fi
      if ! git show "$base_sha:$old_base_path" > "$old_base_manifest"; then
        fail "could not read previous supported base manifest at $base_sha"
      fi
      "$SCRIPT_DIR/validate-supported-versions.sh" "$old_flutter_manifest" >/dev/null \
        || fail 'previous supported version manifest is invalid'
      "$SCRIPT_DIR/validate-supported-bases.sh" --allow-multiple \
        "$old_base_manifest" >/dev/null \
        || fail 'previous supported base manifest is invalid'
      if ! matrix="$("$SCRIPT_DIR/publish-matrix.sh" \
        "$old_flutter_manifest" "$flutter_manifest" \
        "$old_base_manifest" "$base_manifest")"; then
        fail 'could not build the selective publication matrix'
      fi
      publish_needed="$(jq -r '.include | length > 0' <<< "$matrix")" \
        || fail 'selective publication matrix has no valid length'
      ;;
    *)
      fail "invalid publication mode: $mode"
      ;;
  esac

  jq -e '.include | type == "array"' <<< "$matrix" >/dev/null \
    || fail 'publication matrix is malformed'
  printf 'publish_mode=%s\n' "$mode"
  printf 'publish_matrix=%s\n' "$matrix"
  printf 'publish_needed=%s\n' "$publish_needed"
}

if (( $# == 0 )); then
  usage
fi

case "$1" in
  --paths)
    shift
    printf 'publish_mode=%s\n' "$(mode_for_paths "$@")"
    ;;
  --workflow-dispatch)
    (( $# == 3 )) || usage
    plan "$2" "$3" full
    ;;
  --revisions)
    if (( $# == 3 )); then
      mode_for_revisions "$2" "$3"
      printf 'publish_mode=%s\n' "$publication_mode"
    elif (( $# == 5 )); then
      mode_for_revisions "$2" "$3"
      plan "$4" "$5" "$publication_mode" "$2"
    else
      usage
    fi
    ;;
  *)
    usage
    ;;
esac
