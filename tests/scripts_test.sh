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

manifest="$ROOT_DIR/supported_version.json"
validator="$ROOT_DIR/scripts/validate-supported-versions.sh"
classifier="$ROOT_DIR/scripts/classify-changes.sh"
publish_matrix_script="$ROOT_DIR/scripts/publish-matrix.sh"

"$validator" "$manifest"
python3 "$ROOT_DIR/tests/test_update_supported_versions.py"

assert_classification() {
  local expected="$1"
  shift
  local actual
  actual="$("$classifier" "$@")"
  [[ "$actual" == "requires_toolchain_ci=$expected" ]] \
    || fail "expected requires_toolchain_ci=$expected, got: $actual"
}

assert_classification false README.md
assert_classification false README.md SECURITY.md
assert_classification false docs/maintenance.md
assert_classification true README.md Dockerfile
assert_classification true README.md supported_version.json
assert_classification true README.md scripts/verify-release.sh
assert_classification true README.md tests/smoke_app/test/smoke_test.dart
assert_classification true some-new-future-file
assert_classification true
assert_classification true --revisions not-a-base not-a-head

test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

fixture_repo="$test_dir/classifier-repo"
git init -q "$fixture_repo"
git -C "$fixture_repo" config user.name classifier-test
git -C "$fixture_repo" config user.email classifier-test@example.invalid
printf 'docs\n' > "$fixture_repo/README.md"
git -C "$fixture_repo" add README.md
git -C "$fixture_repo" -c commit.gpgsign=false commit -qm 'fixture: initial harmless file'
fixture_base="$(git -C "$fixture_repo" rev-parse HEAD)"
printf 'license\n' > "$fixture_repo/LICENSE"
git -C "$fixture_repo" add LICENSE
git -C "$fixture_repo" -c commit.gpgsign=false commit -qm 'fixture: add harmless file'
fixture_docs_head="$(git -C "$fixture_repo" rev-parse HEAD)"
fixture_docs_result="$(cd "$fixture_repo" && "$classifier" --revisions \
  "$fixture_base" "$fixture_docs_head")"
[[ "$fixture_docs_result" == 'requires_toolchain_ci=false' ]] \
  || fail "expected harmless revision range to skip toolchain CI, got: $fixture_docs_result"
printf 'FROM ubuntu:24.04\n' > "$fixture_repo/Dockerfile"
git -C "$fixture_repo" add Dockerfile
git -C "$fixture_repo" -c commit.gpgsign=false commit -qm 'fixture: add toolchain file'
fixture_toolchain_head="$(git -C "$fixture_repo" rev-parse HEAD)"
fixture_toolchain_result="$(cd "$fixture_repo" && "$classifier" --revisions \
  "$fixture_base" "$fixture_toolchain_head")"
[[ "$fixture_toolchain_result" == 'requires_toolchain_ci=true' ]] \
  || fail "expected toolchain revision range to require CI, got: $fixture_toolchain_result"

publish_base="$ROOT_DIR/tests/fixtures/supported_version.json"
jq '
  .supported_versions[0] = (.supported_versions[0]
    | .version = "1.2.4"
    | .revision = "7777777777777777777777777777777777777777"
    | .archive = "stable/linux/flutter_linux_1.2.4-stable.tar.xz"
    | .archive_sha256 = "1111111111111111111111111111111111111111111111111111111111111111")
' "$publish_base" > "$test_dir/publish-patch.json"
patch_matrix="$("$publish_matrix_script" "$publish_base" "$test_dir/publish-patch.json")"
[[ "$(jq -er '.include | length' <<< "$patch_matrix")" == 1 ]] \
  || fail 'publish matrix did not contain one patch replacement'
[[ "$(jq -er '.include[0].version' <<< "$patch_matrix")" == '1.2.4' ]] \
  || fail 'publish matrix omitted the replacement patch'

jq '.supported_versions += [{
  "version": "2.1.0",
  "channel": "stable",
  "revision": "8888888888888888888888888888888888888888",
  "archive": "stable/linux/flutter_linux_2.1.0-stable.tar.xz",
  "archive_sha256": "2222222222222222222222222222222222222222222222222222222222222222"
}]' "$publish_base" > "$test_dir/publish-new-minor.json"
new_minor_matrix="$("$publish_matrix_script" "$publish_base" "$test_dir/publish-new-minor.json")"
[[ "$(jq -er '.include | length' <<< "$new_minor_matrix")" == 1 ]] \
  || fail 'publish matrix did not contain one new minor'
[[ "$(jq -er '.include[0].version' <<< "$new_minor_matrix")" == '2.1.0' ]] \
  || fail 'publish matrix omitted the new minor'

jq '.supported_versions = .supported_versions[1:]' "$publish_base" > "$test_dir/publish-retire-only.json"
retire_matrix="$("$publish_matrix_script" "$publish_base" "$test_dir/publish-retire-only.json")"
[[ "$(jq -er '.include | length' <<< "$retire_matrix")" == 0 ]] \
  || fail 'publish matrix attempted to publish a retired-only change'
assert_fails "$publish_matrix_script" "$test_dir/missing.json" "$publish_base"

for filter in \
  '.schema = 2' \
  '.support_policy.selection = "all_releases"' \
  '.supported_versions = []' \
  '.support_policy.minor_lines = 1' \
  '.supported_versions[1].version = .supported_versions[0].version' \
  '.supported_versions[0].version = ""' \
  '.supported_versions[0].channel = "beta"' \
  '.supported_versions[0].revision = "not-a-revision"'
do
  jq "$filter" "$manifest" > "$test_dir/invalid.json"
  assert_fails "$validator" "$test_dir/invalid.json"
done

mutated_version="$(jq -er '
  .supported_versions[0].version
  | split(".")
  | "\(.[0]).\(.[1]).\((.[2] | tonumber) + 1)"
' "$manifest")"
jq --arg new_version "$mutated_version" '
  .supported_versions[0] as $base
  | if (.supported_versions | length) >= 2 then
      .supported_versions[1] = (
        .supported_versions[1]
        | .version = $new_version
        | .archive = (.channel + "/linux/flutter_linux_" + $new_version + "-" + .channel + ".tar.xz")
      )
    else
      .supported_versions += [
        ($base
         | .version = $new_version
         | .archive = (.channel + "/linux/flutter_linux_" + $new_version + "-" + .channel + ".tar.xz"))
      ]
    end
' "$manifest" > "$test_dir/duplicate-minor.json"
duplicate_minor_output="$test_dir/duplicate-minor.out"
if "$validator" "$test_dir/duplicate-minor.json" > "$duplicate_minor_output" 2>&1; then
  fail 'validator accepted duplicate Flutter minor line'
fi
assert_contains 'duplicate Flutter minor line' "$(< "$duplicate_minor_output")"

from_line="$(awk '$1 == "FROM" { print; count++ } END { if (count != 1) exit 1 }' \
  "$ROOT_DIR/Dockerfile")" || fail 'Dockerfile must have one FROM line'
base_fields="$(printf '%s\n' "$from_line" | sed -nE \
  's/^FROM[[:space:]]+ubuntu:([0-9]+\.[0-9]+)@sha256:([0-9a-fA-F]{64})[[:space:]]*$/\1 \2/p')"
[[ "$base_fields" =~ ^24\.04[[:space:]][0-9a-fA-F]{64}$ ]] \
  || fail 'Dockerfile must pin Ubuntu 24.04 by a full SHA256'
ubuntu_version="${base_fields%% *}"
ubuntu_digest="${base_fields#* }"
ubuntu_digest_short="${ubuntu_digest:0:12}"

metadata="$("$ROOT_DIR/scripts/image-metadata.sh" 3.47.3 \
  c9a6c484230f8b5e408ec57be1ef71dee1e77020 "$ROOT_DIR/Dockerfile")"
assert_contains "tag=3.47.3-ubuntu${ubuntu_version}-${ubuntu_digest_short}" "$metadata"
assert_contains "build_tag=3.47.3-ubuntu${ubuntu_version}-${ubuntu_digest_short}-gc9a6c484230f" \
  "$metadata"

printf 'FROM ubuntu:24.04\n' > "$test_dir/Dockerfile"
assert_fails "$ROOT_DIR/scripts/image-metadata.sh" 3.47.3 \
  c9a6c484230f8b5e408ec57be1ef71dee1e77020 "$test_dir/Dockerfile"

assert_fails "$ROOT_DIR/scripts/acquire-flutter.sh" 3.47.3 beta "$ROOT_DIR/.artifacts"
assert_fails "$ROOT_DIR/scripts/verify-release.sh" 3.47.3 stable \
  e8113bf45620cbeb8aff64947ee4c93e16adb4cf \
  988665565cad9091db1baa54bf6d3868bb40e29719592f3c3a164deefd4208e1 \
  "$ROOT_DIR/not-the-official-archive.tar.xz"
verify_source="$(sed -n '1,180p' "$ROOT_DIR/scripts/verify-release.sh")"
assert_contains 'dart_sdk_arch == "x64"' "$verify_source"
assert_fails "$ROOT_DIR/scripts/smoke-test.sh" image 3.47.3

if rg -n -i 'rst[ -]?platform|consumer application|consumer pub' \
  "$ROOT_DIR" --glob '!tests/scripts_test.sh' --glob '!.git/**'; then
  fail 'repository contains a consumer-specific reference'
fi

acquire_source="$(sed -n '1,180p' "$ROOT_DIR/scripts/acquire-flutter.sh")"
if rg -n 'empty Flutter attestation bundle' <<< "$acquire_source"; then
  fail 'informational attestation download must not be mandatory'
fi
assert_contains 'optional Flutter attestation bundle unavailable' "$acquire_source"

publish_source="$(sed -n '1,280p' "$ROOT_DIR/.github/workflows/publish.yml")"
if rg -n 'awk.*digest:' <<< "$publish_source"; then
  fail 'publish workflow must not parse docker push output'
fi
assert_contains 'docker image inspect' "$publish_source"
assert_contains '.RepoDigests' "$publish_source"
assert_contains 'provenance: false' "$(sed -n '1,240p' "$ROOT_DIR/.github/workflows/ci.yml")"
assert_contains 'push-to-registry: true' "$publish_source"

ci_source="$(sed -n '1,280p' "$ROOT_DIR/.github/workflows/ci.yml")"
assert_contains 'scripts/classify-changes.sh --revisions' "$ci_source"
assert_contains '.pull_request.base.sha' "$ci_source"
assert_contains '.pull_request.head.sha' "$ci_source"
assert_contains 'if: needs.manifest.outputs.requires_toolchain_ci == '\''true'\''' "$ci_source"
assert_contains 'name: CI gate' "$ci_source"
assert_contains 'if: always()' "$ci_source"
if rg -n 'ref:.*pull_request\.head\.sha' <<< "$ci_source"; then
  fail 'manifest validation must use the merge checkout, not the PR head'
fi
if rg -n 'paths-ignore:' <<< "$ci_source"; then
  fail 'CI must not be skipped at the event level'
fi

assert_contains 'scripts/classify-changes.sh --revisions' "$publish_source"
assert_contains '.before' "$publish_source"
assert_contains '.after' "$publish_source"
assert_contains 'GITHUB_EVENT_NAME' "$publish_source"
assert_contains 'publish_matrix' "$publish_source"
assert_contains 'publish_needed' "$publish_source"
assert_contains 'scripts/publish-matrix.sh' "$publish_source"
assert_contains 'git show "$base_sha:supported_version.json"' "$publish_source"
assert_contains 'falling back to full publication' "$publish_source"

watcher_source="$(sed -n '1,320p' "$ROOT_DIR/.github/workflows/flutter-release-watch.yml")"
assert_contains 'cron: "17 3 * * *"' "$watcher_source"
assert_contains 'automation/flutter-support-update' "$watcher_source"
assert_contains 'releases_linux.json' "$watcher_source"
assert_contains 'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1' "$watcher_source"
assert_contains 'environment:' "$watcher_source"
assert_contains 'name: flutter-release-watcher' "$watcher_source"
assert_contains 'deployment: false' "$watcher_source"
assert_contains 'app-id: ${{ vars.FLUTTER_WATCHER_APP_ID }}' "$watcher_source"
assert_contains 'private-key: ${{ secrets.FLUTTER_WATCHER_PRIVATE_KEY }}' "$watcher_source"
assert_contains 'security_anomaly' "$watcher_source"
assert_contains 'Configure it for the `main` branch/ref with no required reviewer' "$(< "$ROOT_DIR/README.md")"
if rg -n 'secrets\.FLUTTER_WATCHER_APP_ID|peter-evans|create-pull-request|github-actions-create-pr|secrets\.PAT|secrets\.GH_TOKEN' \
  <<< "$watcher_source"; then
  fail 'watcher must use the dedicated GitHub App token, not a PAT or third-party PR action'
fi

printf 'PASS: script and supply-chain guardrails\n'
