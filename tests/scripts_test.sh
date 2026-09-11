#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    fail "expected command to fail: $*"
  fi
}

"$ROOT_DIR/scripts/validate-versions.sh" "$ROOT_DIR/versions.json"

test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
for filter in \
  '.schema = 2' \
  '.versions[1].version = .versions[0].version' \
  '.versions[0].version = ""' \
  '.versions[0].channel = "beta"' \
  '.versions[0].revision = "not-a-revision"'
do
  jq "$filter" "$ROOT_DIR/versions.json" > "$test_dir/invalid.json"
  assert_fails "$ROOT_DIR/scripts/validate-versions.sh" "$test_dir/invalid.json"
done

metadata="$("$ROOT_DIR/scripts/image-metadata.sh" 3.47.3 \
  c9a6c484230f8b5e408ec57be1ef71dee1e77020 "$ROOT_DIR/Dockerfile")"
assert_contains "tag=3.47.3-ubuntu24.04-a61567bd3182" "$metadata"
assert_contains "build_tag=3.47.3-ubuntu24.04-a61567bd3182-gc9a6c484230f" "$metadata"

printf 'FROM ubuntu:24.04\n' > "$test_dir/Dockerfile"
assert_fails "$ROOT_DIR/scripts/image-metadata.sh" 3.47.3 \
  c9a6c484230f8b5e408ec57be1ef71dee1e77020 "$test_dir/Dockerfile"

assert_fails "$ROOT_DIR/scripts/acquire-flutter.sh" 3.47.3 beta "$ROOT_DIR/.artifacts"
assert_fails "$ROOT_DIR/scripts/verify-release.sh" 3.47.3 stable \
  e8113bf45620cbeb8aff64947ee4c93e16adb4cf \
  988665565cad9091db1baa54bf6d3868bb40e29719592f3c3a164deefd4208e1 \
  "$ROOT_DIR/not-the-official-archive.tar.xz"
assert_fails "$ROOT_DIR/scripts/smoke-test.sh" image 3.47.3

if rg -n -i 'rst[ -]?platform|consumer application|consumer pub' \
  "$ROOT_DIR" --glob '!tests/scripts_test.sh' --glob '!.git/**'; then
  fail 'repository contains a consumer-specific reference'
fi

assert_contains 'FROM ubuntu:24.04@sha256:a61567bd31828687156d735ea8eb01ba4e37636e225dd6a48ba94136a70d9d61' \
  "$(sed -n '1,80p' "$ROOT_DIR/Dockerfile")"
assert_contains 'provenance: false' "$(sed -n '1,240p' "$ROOT_DIR/.github/workflows/ci.yml")"
assert_contains 'push-to-registry: true' "$(sed -n '1,260p' "$ROOT_DIR/.github/workflows/publish.yml")"

printf 'PASS: script and supply-chain guardrails\n'
