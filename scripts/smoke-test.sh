#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
  printf 'usage: %s IMAGE EXPECTED_VERSION EXPECTED_REVISION\n' "$0" >&2
  exit 2
fi

image="$1"
expected_version="$2"
expected_revision="$3"
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$root_dir/tests/smoke_app"

[[ -n "$image" ]] || { printf 'image must not be empty\n' >&2; exit 1; }
[[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { printf 'invalid expected Flutter version\n' >&2; exit 1; }
[[ "$expected_revision" =~ ^[0-9a-fA-F]{40}$ ]] \
  || { printf 'invalid expected Flutter revision\n' >&2; exit 1; }
[[ -d "$fixture" ]] || { printf 'smoke fixture not found: %s\n' "$fixture" >&2; exit 1; }

docker run --rm \
  --mount "type=bind,src=$fixture,dst=/fixture,readonly" \
  "$image" \
  bash -ceu '
    expected_version="$1"
    expected_revision="$2"

    flutter_version_output="$(flutter --version 2>&1)"
    printf "%s\n" "$flutter_version_output"
    grep -Fq -- "Flutter $expected_version" <<< "$flutter_version_output"

    dart_version_output="$(dart --version 2>&1)"
    printf "%s\n" "$dart_version_output"

    actual_revision="$(git -C /opt/flutter rev-parse HEAD)"
    test "$actual_revision" = "$expected_revision"
    git -C /opt/flutter tag --points-at HEAD | grep -Fx -- "$expected_version"

    if command -v python3 >/dev/null 2>&1; then
      printf "python3 must not be installed\n" >&2
      exit 1
    fi

    rm -rf /tmp/smoke
    cp -a /fixture /tmp/smoke
    cd /tmp/smoke
    flutter pub get
    flutter test --no-pub
  ' -- "$expected_version" "$expected_revision"
