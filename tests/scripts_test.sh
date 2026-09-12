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
base_manifest="$ROOT_DIR/supported_bases.json"
base_validator="$ROOT_DIR/scripts/validate-supported-bases.sh"
classifier="$ROOT_DIR/scripts/classify-changes.sh"
publication_classifier="$ROOT_DIR/scripts/classify-publication.sh"
publish_matrix_script="$ROOT_DIR/scripts/publish-matrix.sh"
build_matrix_script="$ROOT_DIR/scripts/build-matrix.sh"
dockerfile_guard="$ROOT_DIR/scripts/validate-dockerfile.sh"

command -v grep >/dev/null 2>&1 || fail 'required command not found: grep'

"$validator" "$manifest"
"$base_validator" "$base_manifest"
python3 "$ROOT_DIR/tests/test_update_supported_versions.py"
"$dockerfile_guard" "$ROOT_DIR/Dockerfile"
current_matrix="$("$build_matrix_script" "$manifest" "$base_manifest")"
[[ "$(jq -er '.include | length' <<< "$current_matrix")" == 3 ]] \
  || fail 'current build matrix must contain three Flutter/base rows'
jq -e '
  [.include[] | [.version, .base_id]]
  == [["3.41.9", "ubuntu24.04"],
      ["3.44.9", "ubuntu24.04"],
      ["3.47.3", "ubuntu24.04"]]
' <<< "$current_matrix" >/dev/null \
  || fail 'current build matrix has unexpected Flutter/base pairs'

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
assert_publication_mode selective supported_bases.json
assert_publication_mode selective supported_version.json README.md \
  .github/workflows/flutter-release-watch.yml
assert_publication_mode full Dockerfile
assert_publication_mode full .dockerignore
assert_publication_mode full scripts/image-metadata.sh
assert_publication_mode full scripts/build-matrix.sh
assert_publication_mode full scripts/validate-dockerfile.sh
assert_publication_mode full scripts/validate-supported-bases.sh
assert_publication_mode full scripts/publish-matrix.sh
assert_publication_mode full scripts/classify-publication.sh
assert_publication_mode full Dockerfile supported_version.json
dispatch_mode="$("$publication_classifier" --workflow-dispatch "$manifest" "$base_manifest")"
assert_contains 'publish_mode=full' "$dispatch_mode"
dispatch_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$dispatch_mode")"
[[ "$(jq -er '.include | length' <<< "$dispatch_matrix")" == 3 ]] \
  || fail 'workflow_dispatch did not plan every supported Flutter/base row'
assert_fails "$publication_classifier" --revisions not-a-base not-a-head

test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

for filter in \
  'del(.schema)' \
  '.schema = 2' \
  'del(.bases)' \
  '.bases = []' \
  '.bases[0] += {extra: "not-allowed"}' \
  '.bases[0].id = ""' \
  '.bases[0].id = "Ubuntu24.04"' \
  'del(.bases[0].family)' \
  '.bases[0].family = ""' \
  'del(.bases[0].version)' \
  '.bases[0].version = ""' \
  'del(.bases[0].variant)' \
  '.bases[0].variant = ""' \
  'del(.bases[0].reference)' \
  '.bases[0].reference = ""' \
  '.bases[0].reference = "ubuntu:24.04"' \
  '.bases[0].reference = "ubuntu:24.04@sha256:aaaaaaaa"' \
  '.bases[0].reference = "ubuntu:24.04@sha256:gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg"' \
  '.bases[0].reference = "https://example.invalid/ubuntu:24.04@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  '.bases[0].reference = "debian:trixie@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  '.bases[0].family = "debian"' \
  '.bases += [.bases[0]]'
do
  jq "$filter" "$base_manifest" > "$test_dir/invalid-bases.json"
  assert_fails "$base_validator" "$test_dir/invalid-bases.json"
done

synthetic_bases="$test_dir/supported_bases-two.json"
jq '.bases += [{
  "id": "debian13",
  "family": "debian",
  "version": "13",
  "variant": "default",
  "reference": "debian:13@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}]' "$base_manifest" > "$synthetic_bases"
assert_fails "$base_validator" "$synthetic_bases"
"$base_validator" --allow-multiple "$synthetic_bases"

synthetic_matrix="$("$build_matrix_script" "$ROOT_DIR/tests/fixtures/supported_version.json" "$synthetic_bases")"
[[ "$(jq -er '.include | length' <<< "$synthetic_matrix")" == 6 ]] \
  || fail 'synthetic two-base matrix did not contain six rows'
[[ "$(jq -er '[.include[] | [.version, .base_id]] | unique | length' <<< "$synthetic_matrix")" == 6 ]] \
  || fail 'synthetic matrix contains duplicate Flutter/base pairs'

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
publish_base_bases="$base_manifest"

dispatch_plan="$("$publication_classifier" --workflow-dispatch "$publish_base" "$publish_base_bases")"
assert_contains 'publish_mode=full' "$dispatch_plan"
assert_contains 'publish_needed=true' "$dispatch_plan"
dispatch_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$dispatch_plan")"
[[ "$(jq -er '.include | length' <<< "$dispatch_matrix")" == 3 ]] \
  || fail 'workflow_dispatch did not plan every supported Flutter/base row'

publication_repo="$test_dir/publication-repo"
git init -q "$publication_repo"
git -C "$publication_repo" config user.name publication-test
git -C "$publication_repo" config user.email publication-test@example.invalid
cp "$publish_base" "$publication_repo/supported_version.json"
cp "$publish_base_bases" "$publication_repo/supported_bases.json"
printf 'README\n' > "$publication_repo/README.md"
git -C "$publication_repo" add supported_version.json supported_bases.json README.md
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
  "$publication_base" "$publication_head" supported_version.json supported_bases.json)"
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
  "$publication_head" "$retirement_head" supported_version.json supported_bases.json)"
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
  "$retirement_head" "$new_minor_head" supported_version.json supported_bases.json)"
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
  "$new_minor_head" "$readme_head" supported_version.json supported_bases.json)"
assert_contains 'publish_mode=none' "$readme_plan"
assert_contains 'publish_needed=false' "$readme_plan"
readme_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$readme_plan")"
[[ "$(jq -er '.include | length' <<< "$readme_matrix")" == 0 ]] \
  || fail 'README-only planner attempted publication'

current_base_update="$test_dir/current-base-update.json"
jq '.bases[0].reference = "ubuntu:24.04@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' \
  "$base_manifest" > "$current_base_update"
cp "$current_base_update" "$publication_repo/supported_bases.json"
git -C "$publication_repo" add supported_bases.json
git -C "$publication_repo" -c commit.gpgsign=false commit -qm 'fixture: update base digest'
base_update_head="$(git -C "$publication_repo" rev-parse HEAD)"
base_update_plan="$(cd "$publication_repo" && "$publication_classifier" --revisions \
  "$readme_head" "$base_update_head" supported_version.json supported_bases.json)"
assert_contains 'publish_mode=selective' "$base_update_plan"
assert_contains 'publish_needed=true' "$base_update_plan"
base_update_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$base_update_plan")"
[[ "$(jq -er '.include | length' <<< "$base_update_matrix")" == 3 ]] \
  || fail 'base digest update should publish every current Flutter for that base'

broken_repo="$test_dir/broken-publication-repo"
git init -q "$broken_repo"
git -C "$broken_repo" config user.name broken-publication-test
git -C "$broken_repo" config user.email broken-publication-test@example.invalid
printf '{}\n' > "$broken_repo/supported_version.json"
cp "$publish_base_bases" "$broken_repo/supported_bases.json"
git -C "$broken_repo" add supported_version.json supported_bases.json
git -C "$broken_repo" -c commit.gpgsign=false commit -qm 'fixture: broken old manifest'
broken_base="$(git -C "$broken_repo" rev-parse HEAD)"
cp "$publish_base" "$broken_repo/supported_version.json"
git -C "$broken_repo" add supported_version.json
git -C "$broken_repo" -c commit.gpgsign=false commit -qm 'fixture: valid current manifest'
broken_head="$(git -C "$broken_repo" rev-parse HEAD)"
broken_plan_output="$test_dir/broken-publication-plan.out"
if (cd "$broken_repo" && "$publication_classifier" --revisions \
  "$broken_base" "$broken_head" supported_version.json supported_bases.json) > "$broken_plan_output" 2>&1; then
  fail 'publication planner accepted a broken previous manifest'
fi
assert_no_text_match 'publish_mode=full' "$(< "$broken_plan_output")"

broken_base_repo="$test_dir/broken-base-publication-repo"
git init -q "$broken_base_repo"
git -C "$broken_base_repo" config user.name broken-base-publication-test
git -C "$broken_base_repo" config user.email broken-base-publication-test@example.invalid
cp "$publish_base" "$broken_base_repo/supported_version.json"
printf '{}\n' > "$broken_base_repo/supported_bases.json"
git -C "$broken_base_repo" add supported_version.json supported_bases.json
git -C "$broken_base_repo" -c commit.gpgsign=false commit -qm 'fixture: broken old base manifest'
broken_base_manifest_sha="$(git -C "$broken_base_repo" rev-parse HEAD)"
cp "$base_manifest" "$broken_base_repo/supported_bases.json"
git -C "$broken_base_repo" add supported_bases.json
git -C "$broken_base_repo" -c commit.gpgsign=false commit -qm 'fixture: valid current base manifest'
broken_base_manifest_head="$(git -C "$broken_base_repo" rev-parse HEAD)"
if (cd "$broken_base_repo" && "$publication_classifier" --revisions \
  "$broken_base_manifest_sha" "$broken_base_manifest_head" \
  supported_version.json supported_bases.json); then
  fail 'publication planner accepted a broken previous base manifest'
fi

jq '
  .supported_versions[0] = (.supported_versions[0]
    | .version = "1.2.4"
    | .revision = "7777777777777777777777777777777777777777"
    | .archive = "stable/linux/flutter_linux_1.2.4-stable.tar.xz"
    | .archive_sha256 = "1111111111111111111111111111111111111111111111111111111111111111")
' "$publish_base" > "$test_dir/publish-patch.json"
patch_matrix="$("$publish_matrix_script" "$publish_base" "$test_dir/publish-patch.json" \
  "$publish_base_bases" "$publish_base_bases")"
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
new_minor_matrix="$("$publish_matrix_script" "$publish_base" "$test_dir/publish-new-minor.json" \
  "$publish_base_bases" "$publish_base_bases")"
[[ "$(jq -er '.include | length' <<< "$new_minor_matrix")" == 1 ]] \
  || fail 'publish matrix did not contain one new minor'
[[ "$(jq -er '.include[0].version' <<< "$new_minor_matrix")" == '2.1.0' ]] \
  || fail 'publish matrix omitted the new minor'

jq '.supported_versions = .supported_versions[1:]' "$publish_base" > "$test_dir/publish-retire-only.json"
retire_matrix="$("$publish_matrix_script" "$publish_base" "$test_dir/publish-retire-only.json" \
  "$publish_base_bases" "$publish_base_bases")"
[[ "$(jq -er '.include | length' <<< "$retire_matrix")" == 0 ]] \
  || fail 'publish matrix attempted to publish a retired-only change'
assert_fails "$publish_matrix_script" "$test_dir/missing.json" "$publish_base" \
  "$publish_base_bases" "$publish_base_bases"

unchanged_two_base_matrix="$("$publish_matrix_script" "$publish_base" "$publish_base" \
  "$synthetic_bases" "$synthetic_bases")"
[[ "$(jq -er '.include | length' <<< "$unchanged_two_base_matrix")" == 0 ]] \
  || fail 'unchanged Flutter and bases should publish nothing'

patch_two_base_matrix="$("$publish_matrix_script" "$publish_base" \
  "$test_dir/publish-patch.json" "$synthetic_bases" "$synthetic_bases")"
[[ "$(jq -er '.include | length' <<< "$patch_two_base_matrix")" == 2 ]] \
  || fail 'Flutter patch should publish across every current base'
[[ "$(jq -er '[.include[] | [.version, .base_id]] | unique | length' <<< "$patch_two_base_matrix")" == 2 ]] \
  || fail 'Flutter patch matrix contains duplicate pairs'

new_minor_two_base_matrix="$("$publish_matrix_script" "$publish_base" \
  "$test_dir/publish-new-minor.json" "$synthetic_bases" "$synthetic_bases")"
[[ "$(jq -er '.include | length' <<< "$new_minor_two_base_matrix")" == 2 ]] \
  || fail 'new Flutter release should publish across every current base'

changed_base="$test_dir/supported_bases-changed.json"
jq '.bases[0].reference = "ubuntu:24.04@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "$synthetic_bases" > "$changed_base"
changed_base_matrix="$("$publish_matrix_script" "$publish_base" "$publish_base" \
  "$synthetic_bases" "$changed_base")"
[[ "$(jq -er '.include | length' <<< "$changed_base_matrix")" == 3 ]] \
  || fail 'base digest change should publish every current Flutter for that base'
[[ "$(jq -er '[.include[] | select(.base_id == "ubuntu24.04")] | length' <<< "$changed_base_matrix")" == 3 ]] \
  || fail 'base digest change selected the wrong base'

new_base_matrix="$("$publish_matrix_script" "$publish_base" "$publish_base" \
  "$publish_base_bases" "$synthetic_bases")"
[[ "$(jq -er '.include | length' <<< "$new_base_matrix")" == 3 ]] \
  || fail 'new base should publish every current Flutter'
[[ "$(jq -er '[.include[] | select(.base_id == "debian13")] | length' <<< "$new_base_matrix")" == 3 ]] \
  || fail 'new base rows are missing'

retired_base_matrix="$("$publish_matrix_script" "$publish_base" "$publish_base" \
  "$synthetic_bases" "$publish_base_bases")"
[[ "$(jq -er '.include | length' <<< "$retired_base_matrix")" == 0 ]] \
  || fail 'base retirement should publish nothing'

union_matrix="$("$publish_matrix_script" "$publish_base" \
  "$test_dir/publish-patch.json" "$synthetic_bases" "$changed_base")"
[[ "$(jq -er '.include | length' <<< "$union_matrix")" == 4 ]] \
  || fail 'Flutter and base changes should use their union'
[[ "$(jq -er '[.include[] | [.version, .base_id]] | unique | length' <<< "$union_matrix")" == 4 ]] \
  || fail 'union publication matrix contains duplicate pairs'

jq '.schema = 2' "$synthetic_bases" > "$test_dir/invalid-old-bases.json"
printf '{}\n' > "$test_dir/invalid-old-flutter.json"
assert_fails "$publish_matrix_script" "$test_dir/invalid-old-flutter.json" "$publish_base" \
  "$synthetic_bases" "$synthetic_bases"
assert_fails "$publish_matrix_script" "$publish_base" "$publish_base" \
  "$test_dir/invalid-old-bases.json" "$synthetic_bases"
assert_fails "$publish_matrix_script" "$publish_base" "$publish_base" \
  "$synthetic_bases" "$test_dir/invalid-old-bases.json"

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
  c9a6c484230f8b5e408ec57be1ef71dee1e77020 ubuntu24.04 "$base_manifest")"
assert_contains 'flutter_version=3.47.3' "$metadata"
assert_contains 'base_id=ubuntu24.04' "$metadata"
assert_contains 'base_family=ubuntu' "$metadata"
assert_contains 'base_version=24.04' "$metadata"
assert_contains 'base_variant=default' "$metadata"
assert_contains 'base_reference=ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254' "$metadata"
assert_contains 'base_digest=sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254' "$metadata"
assert_contains 'base_digest_short=224a1869083a' "$metadata"
assert_contains 'repository_sha_short=c9a6c484230f' "$metadata"
assert_contains 'tag=3.47.3-ubuntu24.04-224a1869083a' "$metadata"
assert_contains 'build_tag=3.47.3-ubuntu24.04-224a1869083a-gc9a6c484230f' \
  "$metadata"
assert_fails "$ROOT_DIR/scripts/image-metadata.sh" 3.47.3 \
  c9a6c484230f8b5e408ec57be1ef71dee1e77020 unknown-base "$base_manifest"
assert_fails "$ROOT_DIR/scripts/image-metadata.sh" 3.47.3 \
  c9a6c484230f8b5e408ec57be1ef71dee1e77020 ubuntu24.04 "$test_dir/invalid-bases.json"

for dockerfile_input in \
  $'FROM ubuntu:24.04@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa AS flutter-sdk\nFROM ubuntu:24.04@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  $'ARG BASE_IMAGE=ubuntu:24.04\nFROM ${BASE_IMAGE} AS flutter-sdk\nFROM ${BASE_IMAGE}' \
  $'ARG SOME_OTHER_ARG\nFROM ${SOME_OTHER_ARG} AS flutter-sdk\nFROM ${SOME_OTHER_ARG}' \
  $'ARG BASE_IMAGE\nFROM ${BASE_IMAGE} AS flutter-sdk\nFROM ubuntu:24.04@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
  printf '%s\n' "$dockerfile_input" > "$test_dir/invalid-contract.Dockerfile"
  assert_fails "$dockerfile_guard" "$test_dir/invalid-contract.Dockerfile"
done

for final_input in \
  'COPY . /workspace' \
  'COPY .artifacts/ /tmp/artifacts/' \
  'ADD .artifacts/flutter-sdk.tar.xz /tmp/flutter-sdk.tar.xz'; do
  printf '%s\n' \
    'ARG BASE_IMAGE' \
    'FROM ${BASE_IMAGE} AS flutter-sdk' \
    'COPY .artifacts/flutter-sdk.tar.xz /tmp/flutter-sdk.tar.xz' \
    'FROM ${BASE_IMAGE}' \
    "$final_input" \
    > "$test_dir/context-input-in-final.Dockerfile"
  assert_fails "$dockerfile_guard" "$test_dir/context-input-in-final.Dockerfile"
done

printf '%s\n' \
  'ARG BASE_IMAGE' \
  'FROM ${BASE_IMAGE} AS flutter-sdk' \
  'FROM ${BASE_IMAGE}' \
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
publish_cleanup_source="$(sed -n '/^      - name: Remove tested image/,$p' <<< "$publish_source")"
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
assert_contains 'push-to-registry: false' "$publish_source"
assert_contains 'create-storage-record: false' "$publish_source"
assert_no_text_match 'artifact-metadata: write' "$publish_source"
assert_contains 'Remove tested image' "$(sed -n '1,240p' "$ROOT_DIR/.github/workflows/ci.yml")"
assert_contains 'Remove tested image' "$publish_source"
assert_contains 'test image leaked after cleanup' "$publish_cleanup_source"
assert_no_text_match '\|\| true' "$publish_cleanup_source"

ci_source="$(sed -n '1,280p' "$ROOT_DIR/.github/workflows/ci.yml")"
ci_cleanup_source="$(sed -n '/^      - name: Remove tested image/,/^  ci-gate:/p' <<< "$ci_source")"
ci_metadata_source="$(sed -n '/^      - name: Derive image metadata/,/^      - name: Set up Docker Buildx/p' <<< "$ci_source")"
assert_contains 'scripts/classify-changes.sh --revisions' "$ci_source"
assert_contains 'scripts/validate-supported-bases.sh supported_bases.json' "$ci_source"
assert_contains 'scripts/build-matrix.sh supported_version.json supported_bases.json' "$ci_source"
assert_contains 'matrix.base_reference' "$ci_source"
assert_contains 'BASE_IMAGE=${{ matrix.base_reference }}' "$ci_source"
assert_contains 'cache-from: type=gha,scope=flutter-${{ matrix.version }}-${{ matrix.base_id }}' "$ci_source"
assert_contains 'cache-to: type=gha,mode=max,scope=flutter-${{ matrix.version }}-${{ matrix.base_id }}' "$ci_source"
assert_no_text_match 'ubuntu:24\.04' "$ci_source"
assert_no_text_match 'image-metadata\.sh.*Dockerfile' "$ci_source"
assert_contains '.pull_request.base.sha' "$ci_source"
assert_contains '.pull_request.head.sha' "$ci_source"
assert_contains 'if: needs.manifest.outputs.requires_toolchain_ci == '\''true'\''' "$ci_source"
assert_contains 'name: CI gate' "$ci_source"
assert_contains 'if: always()' "$ci_source"
assert_contains 'run: |' "$ci_metadata_source"
assert_contains 'test image leaked after cleanup' "$ci_cleanup_source"
assert_no_text_match '\|\| true' "$ci_cleanup_source"
assert_no_text_match 'ref:.*pull_request\.head\.sha' "$ci_source"
assert_no_text_match 'paths-ignore:' "$ci_source"

assert_contains 'scripts/classify-publication.sh' "$publish_source"
publish_metadata_source="$(sed -n '/^      - name: Derive image metadata/,/^      - name: Set up Docker Buildx/p' <<< "$publish_source")"
assert_contains '.before' "$publish_source"
assert_contains '.after' "$publish_source"
assert_contains 'GITHUB_EVENT_NAME' "$publish_source"
assert_contains 'publish_mode' "$publish_source"
assert_contains 'publish_matrix' "$publish_source"
assert_contains 'publish_needed' "$publish_source"
assert_contains 'scripts/validate-supported-bases.sh supported_bases.json' "$publish_source"
assert_contains 'scripts/build-matrix.sh' "$publication_source"
assert_contains 'supported_bases.json' "$publish_source"
assert_contains 'matrix.base_reference' "$publish_source"
assert_contains 'BASE_IMAGE=${{ matrix.base_reference }}' "$publish_source"
assert_contains 'run: |' "$publish_metadata_source"
assert_contains 'cache-from: type=gha,scope=flutter-${{ matrix.version }}-${{ matrix.base_id }}' "$publish_source"
assert_contains 'cache-to: type=gha,mode=max,scope=flutter-${{ matrix.version }}-${{ matrix.base_id }}' "$publish_source"
assert_no_text_match 'ubuntu:24\.04' "$publish_source"
assert_no_text_match 'image-metadata\.sh.*Dockerfile' "$publish_source"
assert_no_text_match 'requires_toolchain_ci' "$publish_source"
assert_no_text_match 'falling back to full publication' "$publish_source"
assert_contains 'publish-matrix.sh' "$publication_source"
assert_contains 'validate-supported-versions.sh' "$publication_source"
assert_contains 'validate-supported-bases.sh' "$publication_source"
assert_contains 'supported_bases.json' "$publication_source"
assert_contains 'could not read previous supported version manifest' "$publication_source"
assert_contains 'could not read previous supported base manifest' "$publication_source"
assert_no_text_match 'falling back to full publication' "$publication_source"

metadata_source="$(sed -n '1,240p' "$ROOT_DIR/scripts/image-metadata.sh")"
assert_no_text_match 'Dockerfile|FROM|awk.*digest' "$metadata_source"
dependabot_source="$(sed -n '1,120p' "$ROOT_DIR/.github/dependabot.yml")"
assert_no_text_match 'package-ecosystem: docker' "$dependabot_source"
assert_contains 'package-ecosystem: github-actions' "$dependabot_source"
assert_contains 'dedicated base watcher' "$(< "$ROOT_DIR/README.md")"

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
