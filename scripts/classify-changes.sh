#!/usr/bin/env bash
set -euo pipefail

fail_safe() {
  printf 'ci_mode=full\n'
}

classify_path() {
  case "$1" in
    supported_version.json|supported_bases.json)
      printf 'selective\n'
      ;;
    README.md|LICENSE|SECURITY.md|.gitignore|.github/dependabot.yml|docs/*)
      printf 'none\n'
      ;;
    *)
      printf 'full\n'
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

classify_paths() {
  local path
  local mode=none

  if (( $# == 0 )); then
    fail_safe
    return
  fi

  for path in "$@"; do
    mode="$(merge_mode "$mode" "$(classify_path "$path")")"
  done

  printf 'ci_mode=%s\n' "$mode"
}

classify_revisions() {
  local base="$1"
  local head="$2"
  local merge_base
  local diff_file
  local path_count=0

  [[ "$base" =~ ^[[:xdigit:]]{40}$ ]] || { fail_safe; return; }
  [[ "$head" =~ ^[[:xdigit:]]{40}$ ]] || { fail_safe; return; }
  git rev-parse --verify "${base}^{commit}" >/dev/null 2>&1 || { fail_safe; return; }
  git rev-parse --verify "${head}^{commit}" >/dev/null 2>&1 || { fail_safe; return; }

  if ! merge_base="$(git merge-base "$base" "$head")"; then
    fail_safe
    return
  fi
  if [[ ! "$merge_base" =~ ^[[:xdigit:]]{40}$ ]] \
    || ! git rev-parse --verify "${merge_base}^{commit}" >/dev/null 2>&1; then
    fail_safe
    return
  fi

  if ! diff_file="$(mktemp "${TMPDIR:-/tmp}/classify-changes.XXXXXX")"; then
    fail_safe
    return
  fi
  if ! git diff --name-only --no-renames -z "$merge_base" "$head" -- > "$diff_file"; then
    rm -f -- "$diff_file"
    fail_safe
    return
  fi

  local path
  local mode=none
  while IFS= read -r -d '' path; do
    path_count=$((path_count + 1))
    mode="$(merge_mode "$mode" "$(classify_path "$path")")"
  done < "$diff_file"
  rm -f -- "$diff_file"
  (( path_count > 0 )) || { fail_safe; return; }

  printf 'ci_mode=%s\n' "$mode"
}

if (( $# == 0 )); then
  fail_safe
elif [[ "$1" == "--revisions" ]]; then
  if (( $# != 3 )); then
    fail_safe
  else
    classify_revisions "$2" "$3"
  fi
elif [[ "$1" == "--paths" ]]; then
  shift
  classify_paths "$@"
else
  classify_paths "$@"
fi
