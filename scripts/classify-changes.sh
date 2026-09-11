#!/usr/bin/env bash
set -euo pipefail

fail_safe() {
  printf 'requires_toolchain_ci=true\n'
}

is_harmless_path() {
  case "$1" in
    README.md|LICENSE|SECURITY.md|.gitignore|.github/dependabot.yml|docs/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

classify_paths() {
  local path

  if (( $# == 0 )); then
    fail_safe
    return
  fi

  for path in "$@"; do
    is_harmless_path "$path" || { fail_safe; return; }
  done

  printf 'requires_toolchain_ci=false\n'
}

classify_revisions() {
  local base="$1"
  local head="$2"
  local diff_file
  local path_count=0

  [[ "$base" =~ ^[[:xdigit:]]{40}$ ]] || { fail_safe; return; }
  [[ "$head" =~ ^[[:xdigit:]]{40}$ ]] || { fail_safe; return; }
  git rev-parse --verify "${base}^{commit}" >/dev/null 2>&1 || { fail_safe; return; }
  git rev-parse --verify "${head}^{commit}" >/dev/null 2>&1 || { fail_safe; return; }

  if ! diff_file="$(mktemp "${TMPDIR:-/tmp}/classify-changes.XXXXXX")"; then
    fail_safe
    return
  fi
  if ! git diff --name-only --no-renames -z "$base" "$head" -- > "$diff_file"; then
    rm -f -- "$diff_file"
    fail_safe
    return
  fi

  local path
  while IFS= read -r -d '' path; do
    path_count=$((path_count + 1))
    if ! is_harmless_path "$path"; then
      rm -f -- "$diff_file"
      fail_safe
      return
    fi
  done < "$diff_file"
  rm -f -- "$diff_file"
  (( path_count > 0 )) || { fail_safe; return; }

  printf 'requires_toolchain_ci=false\n'
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
