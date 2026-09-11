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

assert_no_text_match() {
  local pattern="$1"
  local haystack="$2"
  local status
  if grep -nE "$pattern" <<< "$haystack"; then
    fail "unexpected match: $pattern"
  else
    status=$?
    [[ "$status" -eq 1 ]] || fail "grep failed while checking: $pattern (status $status)"
  fi
}

assert_no_repo_match() {
  local pattern="$1"
  local status
  if grep -RniE --exclude='scripts_test.sh' --exclude-dir='.git' "$pattern" "$ROOT_DIR"; then
    fail "unexpected repository match: $pattern"
  else
    status=$?
    [[ "$status" -eq 1 ]] || fail "grep failed while checking repository: $pattern (status $status)"
  fi
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    fail "expected command to fail: $*"
  fi
}

manifest="$ROOT_DIR/supported_version.json"
validator="$ROOT_DIR/scripts/validate-supported-versions.sh"
classifier="$ROOT_DIR/scripts/classify-changes.sh"
publication_classifier="$ROOT_DIR/scripts/classify-publication.sh"
publish_matrix_script="$ROOT_DIR/scripts/publish-matrix.sh"
dockerfile_guard="$ROOT_DIR/scripts/validate-dockerfile.sh"

command -v grep >/dev/null 2>&1 || fail 'required command not found: grep'

"$validator" "$manifest"
python3 "$ROOT_DIR/tests/test_update_supported_versions.py"
"$dockerfile_guard" "$ROOT_DIR/Dockerfile"

assert_classification() {
  local expected="$1"
  shift
  local actual
  actual="$("$classifier" "$@")"
  [[ "$actual" == "requires_toolchain_ci=$expected" ]] \
    || fail "expected requires_toolchain_ci=$expected, got: $actual"
}

assert_publication_mode() {
  local expected="$1"
  shift
  local actual
  actual="$("$publication_classifier" --paths "$@")"
  [[ "$actual" == "publish_mode=$expected" ]] \
    || fail "expected publish_mode=$expected, got: $actual"
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

assert_publication_mode none README.md
assert_publication_mode none .github/workflows/flutter-release-watch.yml
assert_publication_mode none .github/workflows/publish.yml
assert_publication_mode none .github/workflows/ci.yml
assert_publication_mode none scripts/update-supported-versions.py
assert_publication_mode none scripts/verify-release.sh
assert_publication_mode none scripts/acquire-flutter.sh
assert_publication_mode none scripts/smoke-test.sh
assert_publication_mode none scripts/classify-changes.sh
assert_publication_mode none tests/test_update_supported_versions.py
assert_publication_mode none LICENSE SECURITY.md .github/dependabot.yml docs/maintenance.md
assert_publication_mode selective supported_version.json
assert_publication_mode selective supported_version.json README.md \
  .github/workflows/flutter-release-watch.yml
assert_publication_mode full Dockerfile
assert_publication_mode full .dockerignore
assert_publication_mode full scripts/image-metadata.sh
assert_publication_mode full Dockerfile supported_version.json
[[ "$("$publication_classifier" --workflow-dispatch)" == 'publish_mode=full' ]] \
  || fail 'workflow_dispatch classification was not full'
assert_fails "$publication_classifier" --revisions not-a-base not-a-head

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

fixture_dockerfile_publish="$(cd "$fixture_repo" && "$publication_classifier" --revisions \
  "$fixture_docs_head" "$fixture_toolchain_head")"
[[ "$fixture_dockerfile_publish" == 'publish_mode=full' ]] \
  || fail "Dockerfile revision range was not full publication: $fixture_dockerfile_publish"

printf 'Dockerfile exclusions\n' > "$fixture_repo/.dockerignore"
git -C "$fixture_repo" add .dockerignore
git -C "$fixture_repo" -c commit.gpgsign=false commit -qm 'fixture: add Docker ignore file'
fixture_dockerignore_head="$(git -C "$fixture_repo" rev-parse HEAD)"
fixture_dockerignore_publish="$(cd "$fixture_repo" && "$publication_classifier" --revisions \
  "$fixture_toolchain_head" "$fixture_dockerignore_head")"
[[ "$fixture_dockerignore_publish" == 'publish_mode=full' ]] \
  || fail ".dockerignore revision range was not full publication: $fixture_dockerignore_publish"

mkdir -p "$fixture_repo/scripts"
printf '#!/usr/bin/env bash\n' > "$fixture_repo/scripts/image-metadata.sh"
git -C "$fixture_repo" add scripts/image-metadata.sh
git -C "$fixture_repo" -c commit.gpgsign=false commit -qm 'fixture: add image metadata script'
fixture_metadata_head="$(git -C "$fixture_repo" rev-parse HEAD)"
fixture_metadata_publish="$(cd "$fixture_repo" && "$publication_classifier" --revisions \
  "$fixture_dockerignore_head" "$fixture_metadata_head")"
[[ "$fixture_metadata_publish" == 'publish_mode=full' ]] \
  || fail "image metadata revision range was not full publication: $fixture_metadata_publish"

mkdir -p "$fixture_repo/.github/workflows" "$fixture_repo/scripts" "$fixture_repo/tests"
for maintenance_path in \
  .github/workflows/flutter-release-watch.yml \
  .github/workflows/publish.yml \
  .github/workflows/ci.yml \
  scripts/update-supported-versions.py \
  scripts/verify-release.sh \
  scripts/acquire-flutter.sh \
  scripts/smoke-test.sh \
  scripts/classify-changes.sh \
  tests/test_update_supported_versions.py
do
  printf 'maintenance\n' > "$fixture_repo/$maintenance_path"
done
git -C "$fixture_repo" add .github scripts tests
git -C "$fixture_repo" -c commit.gpgsign=false commit -qm 'fixture: merge-6 maintenance changes'
fixture_maintenance_head="$(git -C "$fixture_repo" rev-parse HEAD)"
fixture_maintenance_ci="$(cd "$fixture_repo" && "$classifier" --revisions \
  "$fixture_metadata_head" "$fixture_maintenance_head")"
[[ "$fixture_maintenance_ci" == 'requires_toolchain_ci=true' ]] \
  || fail "merge-6 maintenance fixture did not require toolchain CI: $fixture_maintenance_ci"
fixture_maintenance_publish="$(cd "$fixture_repo" && "$publication_classifier" --revisions \
  "$fixture_metadata_head" "$fixture_maintenance_head")"
[[ "$fixture_maintenance_publish" == 'publish_mode=none' ]] \
  || fail "merge-6 maintenance fixture did not skip publication: $fixture_maintenance_publish"

publish_base="$ROOT_DIR/tests/fixtures/supported_version.json"

dispatch_plan="$("$publication_classifier" --workflow-dispatch "$publish_base")"
assert_contains 'publish_mode=full' "$dispatch_plan"
assert_contains 'publish_needed=true' "$dispatch_plan"
dispatch_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$dispatch_plan")"
[[ "$(jq -er '.include | length' <<< "$dispatch_matrix")" == 3 ]] \
  || fail 'workflow_dispatch did not plan every supported release'

publication_repo="$test_dir/publication-repo"
git init -q "$publication_repo"
git -C "$publication_repo" config user.name publication-test
git -C "$publication_repo" config user.email publication-test@example.invalid
cp "$publish_base" "$publication_repo/supported_version.json"
printf 'README\n' > "$publication_repo/README.md"
git -C "$publication_repo" add supported_version.json README.md
git -C "$publication_repo" -c commit.gpgsign=false commit -qm 'fixture: initial publication manifest'
publication_base="$(git -C "$publication_repo" rev-parse HEAD)"
jq '
  .supported_versions[0] = (.supported_versions[0]
    | .version = "1.2.4"
    | .revision = "7777777777777777777777777777777777777777"
    | .archive = "stable/linux/flutter_linux_1.2.4-stable.tar.xz"
    | .archive_sha256 = "1111111111111111111111111111111111111111111111111111111111111111")
' "$publication_repo/supported_version.json" > "$test_dir/publication-manifest.json"
mv "$test_dir/publication-manifest.json" "$publication_repo/supported_version.json"
git -C "$publication_repo" add supported_version.json
git -C "$publication_repo" -c commit.gpgsign=false commit -qm 'fixture: update publication manifest'
publication_head="$(git -C "$publication_repo" rev-parse HEAD)"
selective_plan="$(cd "$publication_repo" && "$publication_classifier" --revisions \
  "$publication_base" "$publication_head" supported_version.json)"
assert_contains 'publish_mode=selective' "$selective_plan"
assert_contains 'publish_needed=true' "$selective_plan"
selective_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$selective_plan")"
[[ "$(jq -er '.include | length' <<< "$selective_matrix")" == 1 ]] \
  || fail 'selective planner did not contain one patch replacement'
[[ "$(jq -er '.include[0].version' <<< "$selective_matrix")" == '1.2.4' ]] \
  || fail 'selective planner omitted the replacement patch'

jq '.supported_versions = .supported_versions[1:]' "$publication_repo/supported_version.json" \
  > "$test_dir/retirement-manifest.json"
mv "$test_dir/retirement-manifest.json" "$publication_repo/supported_version.json"
git -C "$publication_repo" add supported_version.json
git -C "$publication_repo" -c commit.gpgsign=false commit -qm 'fixture: retire publication release'
retirement_head="$(git -C "$publication_repo" rev-parse HEAD)"
retirement_plan="$(cd "$publication_repo" && "$publication_classifier" --revisions \
  "$publication_head" "$retirement_head" supported_version.json)"
assert_contains 'publish_mode=selective' "$retirement_plan"
assert_contains 'publish_needed=false' "$retirement_plan"
retirement_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$retirement_plan")"
[[ "$(jq -er '.include | length' <<< "$retirement_matrix")" == 0 ]] \
  || fail 'retirement-only planner attempted publication'

jq '.supported_versions += [{
  "version": "2.1.0",
  "channel": "stable",
  "revision": "8888888888888888888888888888888888888888",
  "archive": "stable/linux/flutter_linux_2.1.0-stable.tar.xz",
  "archive_sha256": "2222222222222222222222222222222222222222222222222222222222222222"
}]' "$publication_repo/supported_version.json" > "$test_dir/new-minor-manifest.json"
mv "$test_dir/new-minor-manifest.json" "$publication_repo/supported_version.json"
git -C "$publication_repo" add supported_version.json
git -C "$publication_repo" -c commit.gpgsign=false commit -qm 'fixture: add publication minor'
new_minor_head="$(git -C "$publication_repo" rev-parse HEAD)"
new_minor_plan="$(cd "$publication_repo" && "$publication_classifier" --revisions \
  "$retirement_head" "$new_minor_head" supported_version.json)"
assert_contains 'publish_mode=selective' "$new_minor_plan"
assert_contains 'publish_needed=true' "$new_minor_plan"
new_minor_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$new_minor_plan")"
[[ "$(jq -er '.include | length' <<< "$new_minor_matrix")" == 1 ]] \
  || fail 'new-minor planner did not contain one release'
[[ "$(jq -er '.include[0].version' <<< "$new_minor_matrix")" == '2.1.0' ]] \
  || fail 'new-minor planner omitted the new release'

printf 'README update\n' >> "$publication_repo/README.md"
git -C "$publication_repo" add README.md
git -C "$publication_repo" -c commit.gpgsign=false commit -qm 'fixture: documentation-only change'
readme_head="$(git -C "$publication_repo" rev-parse HEAD)"
readme_plan="$(cd "$publication_repo" && "$publication_classifier" --revisions \
  "$new_minor_head" "$readme_head" supported_version.json)"
assert_contains 'publish_mode=none' "$readme_plan"
assert_contains 'publish_needed=false' "$readme_plan"
readme_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$readme_plan")"
[[ "$(jq -er '.include | length' <<< "$readme_matrix")" == 0 ]] \
  || fail 'README-only planner attempted publication'

broken_repo="$test_dir/broken-publication-repo"
git init -q "$broken_repo"
git -C "$broken_repo" config user.name broken-publication-test
git -C "$broken_repo" config user.email broken-publication-test@example.invalid
printf '{}\n' > "$broken_repo/supported_version.json"
git -C "$broken_repo" add supported_version.json
git -C "$broken_repo" -c commit.gpgsign=false commit -qm 'fixture: broken old manifest'
broken_base="$(git -C "$broken_repo" rev-parse HEAD)"
cp "$publish_base" "$broken_repo/supported_version.json"
git -C "$broken_repo" add supported_version.json
git -C "$broken_repo" -c commit.gpgsign=false commit -qm 'fixture: valid current manifest'
broken_head="$(git -C "$broken_repo" rev-parse HEAD)"
broken_plan_output="$test_dir/broken-publication-plan.out"
if (cd "$broken_repo" && "$publication_classifier" --revisions \
  "$broken_base" "$broken_head" supported_version.json) > "$broken_plan_output" 2>&1; then
  fail 'publication planner accepted a broken previous manifest'
fi
assert_no_text_match 'publish_mode=full' "$(< "$broken_plan_output")"

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

metadata="$("$ROOT_DIR/scripts/image-metadata.sh" 3.47.3 \
  c9a6c484230f8b5e408ec57be1ef71dee1e77020 "$ROOT_DIR/Dockerfile")"
assert_contains 'ubuntu_version=24.04' "$metadata"
ubuntu_version="$(sed -n 's/^ubuntu_version=//p' <<< "$metadata")"
ubuntu_digest="$(sed -n 's/^ubuntu_digest=sha256://p' <<< "$metadata")"
ubuntu_digest_short="${ubuntu_digest:0:12}"
[[ "$ubuntu_digest" =~ ^[0-9a-fA-F]{64}$ ]] \
  || fail 'Dockerfile must pin Ubuntu by a full SHA256'
assert_contains "tag=3.47.3-ubuntu${ubuntu_version}-${ubuntu_digest_short}" "$metadata"
assert_contains "build_tag=3.47.3-ubuntu${ubuntu_version}-${ubuntu_digest_short}-gc9a6c484230f" \
  "$metadata"

printf 'FROM ubuntu:24.04\n' > "$test_dir/Dockerfile"
assert_fails "$ROOT_DIR/scripts/image-metadata.sh" 3.47.3 \
  c9a6c484230f8b5e408ec57be1ef71dee1e77020 "$test_dir/Dockerfile"

printf '%s\n' \
  'FROM ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254 AS flutter-sdk' \
  'COPY .artifacts/flutter-sdk.tar.xz /tmp/flutter-sdk.tar.xz' \
  'FROM ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254' \
  'COPY .artifacts/flutter-sdk.tar.xz /tmp/flutter-sdk.tar.xz' \
  > "$test_dir/archive-in-final.Dockerfile"
assert_fails "$dockerfile_guard" "$test_dir/archive-in-final.Dockerfile"

printf '%s\n' \
  'FROM ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254 AS flutter-sdk' \
  'FROM ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254' \
  'COPY --from=flutter-sdk /opt/not-flutter /opt/flutter' \
  > "$test_dir/missing-sdk-copy.Dockerfile"
assert_fails "$dockerfile_guard" "$test_dir/missing-sdk-copy.Dockerfile"

assert_fails "$ROOT_DIR/scripts/acquire-flutter.sh" 3.47.3 beta "$ROOT_DIR/.artifacts"
assert_fails "$ROOT_DIR/scripts/verify-release.sh" 3.47.3 stable \
  e8113bf45620cbeb8aff64947ee4c93e16adb4cf \
  988665565cad9091db1baa54bf6d3868bb40e29719592f3c3a164deefd4208e1 \
  "$ROOT_DIR/not-the-official-archive.tar.xz"
verify_source="$(sed -n '1,180p' "$ROOT_DIR/scripts/verify-release.sh")"
assert_contains 'dart_sdk_arch == "x64"' "$verify_source"
assert_fails "$ROOT_DIR/scripts/smoke-test.sh" image 3.47.3

assert_no_repo_match 'rst[ -]?platform|consumer application|consumer pub'

acquire_source="$(sed -n '1,180p' "$ROOT_DIR/scripts/acquire-flutter.sh")"
assert_no_text_match 'empty Flutter attestation bundle' "$acquire_source"
assert_contains 'optional Flutter attestation bundle unavailable' "$acquire_source"

publish_source="$(sed -n '1,280p' "$ROOT_DIR/.github/workflows/publish.yml")"
publication_source="$(sed -n '1,280p' "$publication_classifier")"
[[ "$(grep -c '^classify_path() {' <<< "$publication_source")" == 1 ]] \
  || fail 'publication path policy must have one classify_path helper'
[[ "$(grep -c 'Dockerfile|\.dockerignore|scripts/image-metadata\.sh' \
  <<< "$publication_source")" == 1 ]] \
  || fail 'publication artifact input policy must have one path table'
assert_no_text_match 'awk.*digest:' "$publish_source"
assert_contains 'docker image inspect' "$publish_source"
assert_contains '.RepoDigests' "$publish_source"
assert_contains 'provenance: false' "$(sed -n '1,240p' "$ROOT_DIR/.github/workflows/ci.yml")"
assert_contains 'push-to-registry: true' "$publish_source"
assert_contains 'Remove tested image' "$(sed -n '1,240p' "$ROOT_DIR/.github/workflows/ci.yml")"
assert_contains 'Remove tested image' "$publish_source"

ci_source="$(sed -n '1,280p' "$ROOT_DIR/.github/workflows/ci.yml")"
assert_contains 'scripts/classify-changes.sh --revisions' "$ci_source"
assert_contains '.pull_request.base.sha' "$ci_source"
assert_contains '.pull_request.head.sha' "$ci_source"
assert_contains 'if: needs.manifest.outputs.requires_toolchain_ci == '\''true'\''' "$ci_source"
assert_contains 'name: CI gate' "$ci_source"
assert_contains 'if: always()' "$ci_source"
assert_no_text_match 'ref:.*pull_request\.head\.sha' "$ci_source"
assert_no_text_match 'paths-ignore:' "$ci_source"

assert_contains 'scripts/classify-publication.sh' "$publish_source"
assert_contains '.before' "$publish_source"
assert_contains '.after' "$publish_source"
assert_contains 'GITHUB_EVENT_NAME' "$publish_source"
assert_contains 'publish_mode' "$publish_source"
assert_contains 'publish_matrix' "$publish_source"
assert_contains 'publish_needed' "$publish_source"
assert_no_text_match 'requires_toolchain_ci' "$publish_source"
assert_no_text_match 'falling back to full publication' "$publish_source"
assert_contains 'publish-matrix.sh' "$publication_source"
assert_contains 'validate-supported-versions.sh' "$publication_source"
assert_contains 'could not read previous supported version manifest' "$publication_source"
assert_no_text_match 'falling back to full publication' "$publication_source"

watcher_source="$(sed -n '1,320p' "$ROOT_DIR/.github/workflows/flutter-release-watch.yml")"
assert_contains 'cron: "17 3 * * *"' "$watcher_source"
assert_contains 'automation/flutter-support-update' "$watcher_source"
assert_contains 'releases_linux.json' "$watcher_source"
assert_contains 'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1' "$watcher_source"
assert_contains 'environment:' "$watcher_source"
assert_contains 'name: flutter-release-watcher' "$watcher_source"
assert_contains 'deployment: false' "$watcher_source"
assert_contains 'client-id: ${{ vars.FLUTTER_WATCHER_CLIENT_ID }}' "$watcher_source"
assert_contains 'private-key: ${{ secrets.FLUTTER_WATCHER_PRIVATE_KEY }}' "$watcher_source"
assert_contains 'steps.app-token.outputs.app-slug' "$watcher_source"
assert_contains 'gh api "/users/${APP_SLUG}[bot]" --jq .id' "$watcher_source"
assert_contains 'git config user.name "${APP_SLUG}[bot]"' "$watcher_source"
assert_contains 'git config user.email "${BOT_USER_ID}+${APP_SLUG}[bot]@users.noreply.github.com"' "$watcher_source"
assert_contains 'security_anomaly' "$watcher_source"
assert_contains 'Configure it for the `main` branch/ref with no required reviewer' "$(< "$ROOT_DIR/README.md")"
assert_no_text_match 'secrets\.FLUTTER_WATCHER_(APP|CLIENT)_ID|app-id:|peter-evans|create-pull-request|github-actions-create-pr|secrets\.PAT|secrets\.GH_TOKEN' \
  "$watcher_source"
assert_no_text_match 'git config user\.name "flutter-release-watcher\[bot\]"' "$watcher_source"

printf 'PASS: script and supply-chain guardrails\n'
