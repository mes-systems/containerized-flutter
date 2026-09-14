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
  if grep -nE -- "$pattern" <<< "$haystack"; then
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

assert_matrix_matches_manifests() {
  local versions="$1"
  local bases="$2"
  local label="$3"
  local matrix

  matrix="$("$build_matrix_script" "$versions" "$bases")"

  jq -e \
    --slurpfile versions "$versions" \
    --slurpfile bases "$bases" '
      ($versions[0].supported_versions | length) as $version_count
      | ($bases[0].bases | length) as $base_count

      | (.include | length) == ($version_count * $base_count)

      and (
        [.include[] | [.version, .base_id]]
        ==
        [
          $versions[0].supported_versions[] as $version
          | $bases[0].bases[] as $base
          | [$version.version, $base.id]
        ]
      )

      and all(
        .include[];

        . as $row
        | any(
            $versions[0].supported_versions[];
            .version == $row.version
            and .channel == $row.channel
            and .revision == $row.revision
            and .archive == $row.archive
            and .archive_sha256 == $row.archive_sha256
          )

        and any(
            $bases[0].bases[];
            .id == $row.base_id
            and .family == $row.base_family
            and .version == $row.base_version
            and .variant == $row.base_variant
            and .reference == $row.base_reference
          )
      )
    ' <<< "$matrix" >/dev/null \
    || fail "$label build matrix does not match its manifests"
}

assert_matrix_rows_match_manifests() {
  local matrix="$1"
  local versions="$2"
  local bases="$3"
  local label="$4"

  jq -e \
    --slurpfile versions "$versions" \
    --slurpfile bases "$bases" '
      (.include | type == "array")
      and all(
        .include[];
        . as $row
        | any(
            $versions[0].supported_versions[];
            .version == $row.version
            and .channel == $row.channel
            and .revision == $row.revision
            and .archive == $row.archive
            and .archive_sha256 == $row.archive_sha256
          )
        and any(
            $bases[0].bases[];
            .id == $row.base_id
            and .family == $row.base_family
            and .version == $row.base_version
            and .variant == $row.base_variant
            and .reference == $row.base_reference
          )
      )
    ' <<< "$matrix" >/dev/null \
    || fail "$label matrix rows do not match its manifests"
}

assert_metadata_matches_base_manifest() {
  local flutter_version="$1"
  local repository_sha="$2"
  local base_id="$3"
  local bases="$4"

  local base
  local family
  local version
  local variant
  local reference
  local digest
  local digest_hex
  local digest_short
  local repository_sha_short
  local metadata

  base="$(
    jq -cer --arg id "$base_id" \
      '.bases[] | select(.id == $id)' \
      "$bases"
  )"

  family="$(jq -er '.family' <<< "$base")"
  version="$(jq -er '.version' <<< "$base")"
  variant="$(jq -er '.variant' <<< "$base")"
  reference="$(jq -er '.reference' <<< "$base")"

  digest="$(printf '%s' "${reference##*@}" | tr '[:upper:]' '[:lower:]')"
  digest_hex="${digest#sha256:}"
  digest_short="${digest_hex:0:12}"
  repository_sha_short="$(printf '%.12s' "$repository_sha" | tr '[:upper:]' '[:lower:]')"

  metadata="$(
    "$ROOT_DIR/scripts/image-metadata.sh" \
      "$flutter_version" \
      "$repository_sha" \
      "$base_id" \
      "$bases"
  )"

  assert_contains "flutter_version=$flutter_version" "$metadata"
  assert_contains "base_id=$base_id" "$metadata"
  assert_contains "base_family=$family" "$metadata"
  assert_contains "base_version=$version" "$metadata"
  assert_contains "base_variant=$variant" "$metadata"
  assert_contains "base_reference=$reference" "$metadata"
  assert_contains "base_digest=$digest" "$metadata"
  assert_contains "base_digest_short=$digest_short" "$metadata"
  assert_contains "repository_sha_short=$repository_sha_short" "$metadata"
  assert_contains \
    "tag=$flutter_version-$base_id-$digest_short" \
    "$metadata"
  assert_contains \
    "build_tag=$flutter_version-$base_id-$digest_short-g$repository_sha_short" \
    "$metadata"
}

live_manifest="$ROOT_DIR/supported_version.json"
validator="$ROOT_DIR/scripts/validate-supported-versions.sh"
live_base_manifest="$ROOT_DIR/supported_bases.json"
base_validator="$ROOT_DIR/scripts/validate-supported-bases.sh"
classifier="$ROOT_DIR/scripts/classify-changes.sh"
publication_classifier="$ROOT_DIR/scripts/classify-publication.sh"
publish_matrix_script="$ROOT_DIR/scripts/publish-matrix.sh"
build_matrix_script="$ROOT_DIR/scripts/build-matrix.sh"
dockerfile_guard="$ROOT_DIR/scripts/validate-dockerfile.sh"

command -v grep >/dev/null 2>&1 || fail 'required command not found: grep'

"$validator" "$live_manifest"
"$base_validator" "$live_base_manifest"
python3 "$ROOT_DIR/tests/test_update_supported_versions.py"
python3 "$ROOT_DIR/tests/test_update_supported_bases.py"
"$dockerfile_guard" "$ROOT_DIR/Dockerfile"
assert_matrix_matches_manifests \
  "$live_manifest" \
  "$live_base_manifest" \
  "current"
current_matrix_row_count="$(
  jq -ner \
    --slurpfile versions "$live_manifest" \
    --slurpfile bases "$live_base_manifest" \
    '($versions[0].supported_versions | length)
     * ($bases[0].bases | length)'
)"

assert_classification() {
  local expected="$1"
  shift
  local actual
  actual="$("$classifier" "$@")"
  [[ "$actual" == "ci_mode=$expected" ]] \
    || fail "expected ci_mode=$expected, got: $actual"
}

assert_publication_mode() {
  local expected="$1"
  shift
  local actual
  actual="$("$publication_classifier" --paths "$@")"
  [[ "$actual" == "publish_mode=$expected" ]] \
    || fail "expected publish_mode=$expected, got: $actual"
}

assert_classification none README.md
assert_classification none README.md SECURITY.md
assert_classification none docs/maintenance.md
assert_classification full README.md Dockerfile
assert_classification selective README.md supported_version.json
assert_classification selective supported_bases.json
assert_classification selective supported_version.json supported_bases.json README.md
assert_classification full README.md scripts/verify-release.sh
assert_classification full README.md tests/smoke_app/test/smoke_test.dart
assert_classification full some-new-future-file
assert_classification full
assert_classification full --revisions not-a-base not-a-head
assert_classification full \
  README.md \
  scripts/validate-supported-bases.sh \
  supported_bases.json \
  tests/scripts_test.sh \
  tests/test_update_supported_bases.py

assert_publication_mode none README.md
assert_publication_mode none .github/workflows/flutter-release-watch.yml
assert_publication_mode none .github/workflows/base-image-watch.yml
assert_publication_mode none .github/workflows/publish.yml
assert_publication_mode none .github/workflows/ci.yml
assert_publication_mode none scripts/update-supported-versions.py
assert_publication_mode none scripts/update-supported-bases.py
assert_publication_mode none scripts/verify-release.sh
assert_publication_mode none scripts/acquire-flutter.sh
assert_publication_mode none scripts/smoke-test.sh
assert_publication_mode none scripts/classify-changes.sh
assert_publication_mode none tests/test_update_supported_versions.py
assert_publication_mode none tests/test_update_supported_bases.py
assert_publication_mode none LICENSE SECURITY.md .github/dependabot.yml docs/maintenance.md
assert_publication_mode selective supported_version.json
assert_publication_mode selective supported_bases.json
assert_publication_mode selective supported_version.json README.md \
  .github/workflows/flutter-release-watch.yml
assert_publication_mode selective \
  supported_bases.json \
  scripts/validate-supported-bases.sh
assert_publication_mode selective \
  supported_version.json \
  scripts/build-matrix.sh
assert_publication_mode selective \
  README.md \
  scripts/validate-supported-bases.sh \
  supported_bases.json \
  tests/scripts_test.sh \
  tests/test_update_supported_bases.py
assert_publication_mode full Dockerfile
assert_publication_mode full .dockerignore
assert_publication_mode full scripts/image-metadata.sh
assert_publication_mode none scripts/build-matrix.sh
assert_publication_mode none scripts/validate-dockerfile.sh
assert_publication_mode none scripts/validate-supported-bases.sh
assert_publication_mode none scripts/publish-matrix.sh
assert_publication_mode none scripts/classify-publication.sh
assert_publication_mode full Dockerfile supported_version.json
assert_publication_mode full \
  scripts/image-metadata.sh \
  supported_version.json \
  scripts/publish-matrix.sh
assert_publication_mode full \
  Dockerfile \
  supported_bases.json \
  scripts/validate-supported-bases.sh
dispatch_mode="$("$publication_classifier" --workflow-dispatch "$live_manifest" "$live_base_manifest")"
assert_contains 'publish_mode=full' "$dispatch_mode"
dispatch_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$dispatch_mode")"
[[ "$(jq -er '.include | length' <<< "$dispatch_matrix")" == "$current_matrix_row_count" ]] \
  || fail 'workflow_dispatch did not plan every supported Flutter/base row'
assert_fails "$publication_classifier" --revisions not-a-base not-a-head

test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

checked_in_manifest="$test_dir/checked-in-supported_version.json"
checked_in_base_manifest="$test_dir/checked-in-supported_bases.json"
git -C "$ROOT_DIR" show HEAD:supported_version.json > "$checked_in_manifest"
git -C "$ROOT_DIR" show HEAD:supported_bases.json > "$checked_in_base_manifest"
"$validator" "$checked_in_manifest"
"$base_validator" "$checked_in_base_manifest"
expected_base_count="$(jq -er '.bases | length' "$checked_in_base_manifest")"

watcher_mutation_repo="$test_dir/watcher-mutation-repo"
git init -q "$watcher_mutation_repo"
git -C "$watcher_mutation_repo" config user.name watcher-mutation-test
git -C "$watcher_mutation_repo" config user.email watcher-mutation-test@example.invalid
cp "$checked_in_manifest" "$watcher_mutation_repo/supported_version.json"
cp "$checked_in_base_manifest" "$watcher_mutation_repo/supported_bases.json"
git -C "$watcher_mutation_repo" add supported_version.json supported_bases.json
git -C "$watcher_mutation_repo" -c commit.gpgsign=false commit -qm 'fixture: watcher baseline'

watcher_mutation_old_manifest="$test_dir/watcher-mutation-old-supported_version.json"
watcher_mutation_old_base_manifest="$test_dir/watcher-mutation-old-supported_bases.json"
git -C "$watcher_mutation_repo" show HEAD:supported_version.json > "$watcher_mutation_old_manifest"
git -C "$watcher_mutation_repo" show HEAD:supported_bases.json > "$watcher_mutation_old_base_manifest"
cmp -s "$watcher_mutation_old_manifest" "$checked_in_manifest" \
  || fail 'watcher mutation fixture did not read the checked-in Flutter manifest from HEAD'
watcher_mutation_old_version="$(jq -er '.supported_versions[-1].version' "$watcher_mutation_old_manifest")"
watcher_mutation_new_version="$(jq -er '
  .supported_versions[-1].version
  | split(".")
  | "\(.[0]).\(.[1]).\((.[2] | tonumber) + 1)"
' "$watcher_mutation_old_manifest")"

jq --arg new_version "$watcher_mutation_new_version" '
  .supported_versions[-1] = (.supported_versions[-1]
    | .channel as $channel
    | .version = $new_version
    | .revision = "7777777777777777777777777777777777777777"
    | .archive = ($channel + "/linux/flutter_linux_" + $new_version + "-" + $channel + ".tar.xz")
    | .archive_sha256 = "1111111111111111111111111111111111111111111111111111111111111111")
' "$watcher_mutation_repo/supported_version.json" > "$test_dir/mutated-supported_version.json"
mv "$test_dir/mutated-supported_version.json" "$watcher_mutation_repo/supported_version.json"
git -C "$watcher_mutation_repo" diff --quiet -- supported_version.json \
  && fail 'watcher mutation fixture did not update the working-tree Flutter manifest'
"$validator" "$watcher_mutation_repo/supported_version.json"
[[ "$watcher_mutation_new_version" != "$watcher_mutation_old_version" ]] \
  || fail 'watcher mutation fixture did not advance the historical Flutter version'
watcher_mutation_matrix="$("$publish_matrix_script" \
  "$watcher_mutation_old_manifest" "$watcher_mutation_repo/supported_version.json" \
  "$watcher_mutation_old_base_manifest" "$watcher_mutation_old_base_manifest")"
jq -e \
  --argjson expected_base_count "$expected_base_count" \
  --arg expected_version "$watcher_mutation_new_version" '
  (.include | length == $expected_base_count)
  and (all(.include[]; .version == $expected_version))
  and ([.include[] | [.version, .base_id]] | unique | length == $expected_base_count)
' <<< "$watcher_mutation_matrix" >/dev/null \
  || fail 'watcher mutation fixture did not plan the updated Flutter release for every base'

cp "$watcher_mutation_old_manifest" "$watcher_mutation_repo/supported_version.json"
cp "$checked_in_base_manifest" "$watcher_mutation_repo/supported_bases.json"
watcher_mutation_old_base_reference="$(jq -er \
  '.bases[] | select(.id == "ubuntu24.04") | .reference' \
  "$watcher_mutation_old_base_manifest")"
watcher_mutation_new_base_reference='ubuntu:24.04@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
if [[ "$watcher_mutation_new_base_reference" == "$watcher_mutation_old_base_reference" ]]; then
  watcher_mutation_new_base_reference='ubuntu:24.04@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
fi
jq --arg ref \
  "$watcher_mutation_new_base_reference" \
  '.bases |= map(if .id == "ubuntu24.04" then .reference = $ref else . end)' \
  "$watcher_mutation_repo/supported_bases.json" > "$test_dir/mutated-supported_bases.json"
mv "$test_dir/mutated-supported_bases.json" "$watcher_mutation_repo/supported_bases.json"
git -C "$watcher_mutation_repo" diff --quiet -- supported_bases.json \
  && fail 'watcher mutation fixture did not update the working-tree base manifest'
"$base_validator" "$watcher_mutation_repo/supported_bases.json"
cmp -s "$watcher_mutation_old_base_manifest" "$checked_in_base_manifest" \
  || fail 'base watcher mutation fixture did not read the checked-in base manifest from HEAD'
cmp -s "$watcher_mutation_old_base_manifest" "$watcher_mutation_repo/supported_bases.json" \
  && fail 'base watcher mutation did not change the working-tree base fixture'
expected_version_count="$(jq -er '.supported_versions | length' "$watcher_mutation_old_manifest")"
base_mutation_matrix="$("$publish_matrix_script" \
  "$watcher_mutation_old_manifest" "$watcher_mutation_old_manifest" \
  "$watcher_mutation_old_base_manifest" "$watcher_mutation_repo/supported_bases.json")"
jq -e \
  --argjson expected_version_count "$expected_version_count" \
  --arg expected_base_id ubuntu24.04 \
  --arg expected_base_reference "$watcher_mutation_new_base_reference" '
  (.include | length == $expected_version_count)
  and (all(.include[]; .base_id == $expected_base_id))
  and (all(.include[]; .base_reference == $expected_base_reference))
' <<< "$base_mutation_matrix" >/dev/null \
  || fail 'base watcher mutation fixture did not plan every Flutter release for the changed base'

watcher_flutter_manifest="$test_dir/watcher-flutter-update.json"
jq '
  .supported_versions[-1].version as $old
  | ($old | split(".")) as $parts
  | ($parts[0] + "." + $parts[1] + "." +
      (((($parts[2] | tonumber) + 1)) | tostring)) as $new
  | .supported_versions[-1].version = $new
  | .supported_versions[-1].revision =
      "7777777777777777777777777777777777777777"
  | .supported_versions[-1].archive =
      ("stable/linux/flutter_linux_" + $new + "-stable.tar.xz")
  | .supported_versions[-1].archive_sha256 =
      "1111111111111111111111111111111111111111111111111111111111111111"
' "$checked_in_manifest" > "$watcher_flutter_manifest"
"$validator" "$watcher_flutter_manifest"
assert_matrix_matches_manifests \
  "$watcher_flutter_manifest" \
  "$checked_in_base_manifest" \
  "Flutter watcher patch update"

watcher_new_minor_manifest="$test_dir/watcher-new-minor.json"
jq '
  .supported_versions += [{
    "version": "2.1.0",
    "channel": "stable",
    "revision": "8888888888888888888888888888888888888888",
    "archive": "stable/linux/flutter_linux_2.1.0-stable.tar.xz",
    "archive_sha256":
      "2222222222222222222222222222222222222222222222222222222222222222"
  }]
' "$ROOT_DIR/tests/fixtures/supported_version.json" \
  > "$watcher_new_minor_manifest"
"$validator" "$watcher_new_minor_manifest"
assert_matrix_matches_manifests \
  "$watcher_new_minor_manifest" \
  "$checked_in_base_manifest" \
  "Flutter watcher new minor"

for filter in \
  'del(.schema)' \
  '.schema = 2' \
  'del(.bases)' \
  '.bases = []' \
  '.bases |= map(if .id == "ubuntu24.04" then . += {extra: "not-allowed"} else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .id = "" else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .id = "Ubuntu24.04" else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then del(.family) else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .family = "" else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then del(.version) else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .version = "" else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then del(.variant) else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .variant = "" else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then del(.reference) else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .reference = "" else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .reference = "ubuntu:24.04" else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .reference = "ubuntu:24.04@sha256:aaaaaaaa" else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .reference = "ubuntu:24.04@sha256:gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg" else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .reference = "https://example.invalid/ubuntu:24.04@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .reference = "debian:trixie@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" else . end)' \
  '.bases |= map(if .id == "ubuntu24.04" then .family = "debian" else . end)' \
  '.bases += [.bases[] | select(.id == "ubuntu24.04")]'
do
  jq "$filter" "$live_base_manifest" > "$test_dir/invalid-bases.json"
  assert_fails "$base_validator" "$test_dir/invalid-bases.json"
done

ubuntu_only_bases="$test_dir/supported_bases-ubuntu-only.json"
jq '.bases |= map(select(.id == "ubuntu24.04"))' "$live_base_manifest" > "$ubuntu_only_bases"
assert_fails "$base_validator" "$ubuntu_only_bases"
"$base_validator" --allow-multiple "$ubuntu_only_bases"

debian_only_bases="$test_dir/supported_bases-debian-only.json"
jq '.bases |= map(select(.id == "debian13"))' "$live_base_manifest" > "$debian_only_bases"
assert_fails "$base_validator" "$debian_only_bases"
"$base_validator" --allow-multiple "$debian_only_bases"

two_base_bases="$test_dir/supported_bases-two-production.json"
jq '.bases |= map(select(.id == "ubuntu24.04" or .id == "debian13"))' \
  "$live_base_manifest" > "$two_base_bases"
assert_fails "$base_validator" "$two_base_bases"
"$base_validator" --allow-multiple "$two_base_bases"

debian_slim_bases="$test_dir/supported_bases-debian-slim.json"
jq '.bases |= map(select(.id == "debian13-slim"))' \
  "$live_base_manifest" > "$debian_slim_bases"
assert_fails "$base_validator" "$debian_slim_bases"

fifth_base_bases="$test_dir/supported_bases-fifth.json"
jq '.bases += [{
  "id": "debian13-extra",
  "family": "debian",
  "version": "13",
  "variant": "default",
  "reference": "debian:13@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}]' "$live_base_manifest" > "$fifth_base_bases"
assert_fails "$base_validator" "$fifth_base_bases"

wrong_order_bases="$test_dir/supported_bases-wrong-order.json"
jq '.bases = [.bases[1], .bases[0], .bases[2], .bases[3]]' \
  "$live_base_manifest" > "$wrong_order_bases"
assert_fails "$base_validator" "$wrong_order_bases"
"$base_validator" --allow-multiple "$wrong_order_bases"

duplicate_ubuntu26_bases="$test_dir/supported_bases-duplicate-ubuntu26.json"
jq '.bases |= . + [(.[] | select(.id == "ubuntu26.04"))]' \
  "$live_base_manifest" > "$duplicate_ubuntu26_bases"
assert_fails "$base_validator" "$duplicate_ubuntu26_bases"

pre_ubuntu26_bases="$test_dir/supported_bases-pre-ubuntu26.json"
jq '.bases |= map(select(.id != "ubuntu26.04"))' "$checked_in_base_manifest" > "$pre_ubuntu26_bases"
assert_fails "$base_validator" "$pre_ubuntu26_bases"
"$base_validator" --allow-multiple "$pre_ubuntu26_bases"

only_ubuntu26_bases="$test_dir/supported_bases-ubuntu26-only.json"
jq '.bases |= map(select(.id == "ubuntu26.04"))' "$live_base_manifest" > "$only_ubuntu26_bases"
assert_fails "$base_validator" "$only_ubuntu26_bases"
"$base_validator" --allow-multiple "$only_ubuntu26_bases"

for filter in \
  '.bases |= map(if .id == "ubuntu26.04" then .family = "debian" else . end)' \
  '.bases |= map(if .id == "ubuntu26.04" then .version = "24.04" else . end)' \
  '.bases |= map(if .id == "ubuntu26.04" then .variant = "slim" else . end)' \
  '.bases |= map(if .id == "ubuntu26.04" then .reference = "ubuntu:24.04@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" else . end)' \
  '.bases |= map(if .id == "ubuntu26.04" then .reference = "ubuntu:26.10@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" else . end)'
do
  jq "$filter" "$live_base_manifest" > "$test_dir/invalid-ubuntu26-bases.json"
  assert_fails "$base_validator" "$test_dir/invalid-ubuntu26-bases.json"
done

for filter in \
  '.bases |= map(if .id == "debian13" then .family = "ubuntu" else . end)' \
  '.bases |= map(if .id == "debian13" then .version = "12" else . end)' \
  '.bases |= map(if .id == "debian13" then .variant = "slim" else . end)' \
  '.bases |= map(if .id == "debian13" then .reference = "debian:12@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" else . end)'
do
  jq "$filter" "$live_base_manifest" > "$test_dir/invalid-debian-bases.json"
  assert_fails "$base_validator" "$test_dir/invalid-debian-bases.json"
done

for filter in \
  '.bases |= map(if .id == "debian13-slim" then .variant = "default" else . end)' \
  '.bases |= map(if .id == "debian13-slim" then .reference = "debian:13@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" else . end)' \
  '.bases |= map(if .id == "debian13-slim" then .family = "ubuntu" else . end)' \
  '.bases |= map(if .id == "debian13-slim" then .version = "12" else . end)'
do
  jq "$filter" "$live_base_manifest" > "$test_dir/invalid-debian-slim-bases.json"
  assert_fails "$base_validator" "$test_dir/invalid-debian-slim-bases.json"
done

synthetic_bases="$test_dir/supported_bases-two.json"
jq '.bases |= (map(select(.id == "ubuntu24.04" or .id == "debian13"))
  | map(if .id == "debian13" then .reference = "debian:13@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" else . end))' \
  "$checked_in_base_manifest" > "$synthetic_bases"
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
[[ "$fixture_docs_result" == 'ci_mode=none' ]] \
  || fail "expected harmless revision range to skip toolchain CI, got: $fixture_docs_result"
printf 'FROM ubuntu:24.04\n' > "$fixture_repo/Dockerfile"
git -C "$fixture_repo" add Dockerfile
git -C "$fixture_repo" -c commit.gpgsign=false commit -qm 'fixture: add toolchain file'
fixture_toolchain_head="$(git -C "$fixture_repo" rev-parse HEAD)"
fixture_toolchain_result="$(cd "$fixture_repo" && "$classifier" --revisions \
  "$fixture_base" "$fixture_toolchain_head")"
[[ "$fixture_toolchain_result" == 'ci_mode=full' ]] \
  || fail "expected toolchain revision range to require CI, got: $fixture_toolchain_result"

history_repo="$test_dir/classification-history-repo"
git init -q "$history_repo"
git -C "$history_repo" config user.name classification-history-test
git -C "$history_repo" config user.email classification-history-test@example.invalid
mkdir -p "$history_repo/scripts"
printf 'baseline\n' > "$history_repo/README.md"
printf 'baseline\n' > "$history_repo/supported_version.json"
printf 'baseline\n' > "$history_repo/scripts/verify-release.sh"
printf 'baseline\n' > "$history_repo/Dockerfile"
git -C "$history_repo" add .
git -C "$history_repo" -c commit.gpgsign=false commit -qm 'fixture: classification common ancestor'
history_common="$(git -C "$history_repo" rev-parse HEAD)"

git -C "$history_repo" checkout -q -b pr-selective "$history_common"
printf 'PR Flutter manifest update\n' > "$history_repo/supported_version.json"
git -C "$history_repo" add supported_version.json
git -C "$history_repo" -c commit.gpgsign=false commit -qm 'fixture: PR selective manifest change'
pr_selective_head="$(git -C "$history_repo" rev-parse HEAD)"

git -C "$history_repo" checkout -q -b main-selective "$history_common"
printf 'main-only verification change\n' > "$history_repo/scripts/verify-release.sh"
git -C "$history_repo" add scripts/verify-release.sh
git -C "$history_repo" -c commit.gpgsign=false commit -qm 'fixture: unrelated main verification change'
main_selective_head="$(git -C "$history_repo" rev-parse HEAD)"
two_dot_paths="$(git -C "$history_repo" diff --name-only --no-renames \
  "$main_selective_head" "$pr_selective_head")"
assert_contains 'scripts/verify-release.sh' "$two_dot_paths"
history_selective_result="$(cd "$history_repo" && "$classifier" --revisions \
  "$main_selective_head" "$pr_selective_head")"
[[ "$history_selective_result" == 'ci_mode=selective' ]] \
  || fail "unrelated main-only build change promoted selective PR: $history_selective_result"

git -C "$history_repo" checkout -q -b pr-docs "$history_common"
printf 'PR documentation update\n' > "$history_repo/README.md"
git -C "$history_repo" add README.md
git -C "$history_repo" -c commit.gpgsign=false commit -qm 'fixture: PR documentation change'
pr_docs_head="$(git -C "$history_repo" rev-parse HEAD)"

git -C "$history_repo" checkout -q -b main-docs "$history_common"
printf 'main-only Dockerfile change\n' > "$history_repo/Dockerfile"
git -C "$history_repo" add Dockerfile
git -C "$history_repo" -c commit.gpgsign=false commit -qm 'fixture: unrelated main Dockerfile change'
main_docs_head="$(git -C "$history_repo" rev-parse HEAD)"
history_docs_result="$(cd "$history_repo" && "$classifier" --revisions \
  "$main_docs_head" "$pr_docs_head")"
[[ "$history_docs_result" == 'ci_mode=none' ]] \
  || fail "unrelated main-only Dockerfile change promoted docs PR: $history_docs_result"

git -C "$history_repo" checkout -q -b pr-full "$history_common"
printf 'PR Flutter manifest and verification update\n' > "$history_repo/supported_version.json"
printf 'PR verification change\n' > "$history_repo/scripts/verify-release.sh"
git -C "$history_repo" add supported_version.json scripts/verify-release.sh
git -C "$history_repo" -c commit.gpgsign=false commit -qm 'fixture: PR full CI change'
pr_full_head="$(git -C "$history_repo" rev-parse HEAD)"
history_full_result="$(cd "$history_repo" && "$classifier" --revisions \
  "$history_common" "$pr_full_head")"
[[ "$history_full_result" == 'ci_mode=full' ]] \
  || fail "PR-owned build change did not require full CI: $history_full_result"

unrelated_history_repo="$test_dir/no-common-history-repo"
git init -q "$unrelated_history_repo"
git -C "$unrelated_history_repo" config user.name no-common-history-test
git -C "$unrelated_history_repo" config user.email no-common-history-test@example.invalid
printf 'root A\n' > "$unrelated_history_repo/a.txt"
git -C "$unrelated_history_repo" add a.txt
git -C "$unrelated_history_repo" -c commit.gpgsign=false commit -qm 'fixture: unrelated root A'
unrelated_history_base="$(git -C "$unrelated_history_repo" rev-parse HEAD)"
git -C "$unrelated_history_repo" checkout -q --orphan root-b
printf 'root B\n' > "$unrelated_history_repo/b.txt"
git -C "$unrelated_history_repo" add b.txt
git -C "$unrelated_history_repo" -c commit.gpgsign=false commit -qm 'fixture: unrelated root B'
unrelated_history_head="$(git -C "$unrelated_history_repo" rev-parse HEAD)"
unrelated_history_result="$(cd "$unrelated_history_repo" && "$classifier" --revisions \
  "$unrelated_history_base" "$unrelated_history_head")"
[[ "$unrelated_history_result" == 'ci_mode=full' ]] \
  || fail "merge-base failure did not fail safe: $unrelated_history_result"

fixture_dockerfile_plan="$(cd "$fixture_repo" && "$publication_classifier" --revisions \
  "$fixture_docs_head" "$fixture_toolchain_head" "$live_manifest" "$live_base_manifest")"
assert_contains 'publish_mode=full' "$fixture_dockerfile_plan"
fixture_dockerfile_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$fixture_dockerfile_plan")"
[[ "$(jq -er '.include | length' <<< "$fixture_dockerfile_matrix")" == "$current_matrix_row_count" ]] \
  || fail 'Dockerfile revision range did not plan the full matrix'

printf 'Dockerfile exclusions\n' > "$fixture_repo/.dockerignore"
git -C "$fixture_repo" add .dockerignore
git -C "$fixture_repo" -c commit.gpgsign=false commit -qm 'fixture: add Docker ignore file'
fixture_dockerignore_head="$(git -C "$fixture_repo" rev-parse HEAD)"
fixture_dockerignore_plan="$(cd "$fixture_repo" && "$publication_classifier" --revisions \
  "$fixture_toolchain_head" "$fixture_dockerignore_head" "$live_manifest" "$live_base_manifest")"
assert_contains 'publish_mode=full' "$fixture_dockerignore_plan"
fixture_dockerignore_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$fixture_dockerignore_plan")"
[[ "$(jq -er '.include | length' <<< "$fixture_dockerignore_matrix")" == "$current_matrix_row_count" ]] \
  || fail '.dockerignore revision range did not plan the full matrix'

mkdir -p "$fixture_repo/scripts"
printf '#!/usr/bin/env bash\n' > "$fixture_repo/scripts/image-metadata.sh"
git -C "$fixture_repo" add scripts/image-metadata.sh
git -C "$fixture_repo" -c commit.gpgsign=false commit -qm 'fixture: add image metadata script'
fixture_metadata_head="$(git -C "$fixture_repo" rev-parse HEAD)"
fixture_metadata_plan="$(cd "$fixture_repo" && "$publication_classifier" --revisions \
  "$fixture_dockerignore_head" "$fixture_metadata_head" "$live_manifest" "$live_base_manifest")"
assert_contains 'publish_mode=full' "$fixture_metadata_plan"
fixture_metadata_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$fixture_metadata_plan")"
[[ "$(jq -er '.include | length' <<< "$fixture_metadata_matrix")" == "$current_matrix_row_count" ]] \
  || fail 'image metadata revision range did not plan the full matrix'

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
[[ "$fixture_maintenance_ci" == 'ci_mode=full' ]] \
  || fail "merge-6 maintenance fixture did not require toolchain CI: $fixture_maintenance_ci"
fixture_maintenance_publish="$(cd "$fixture_repo" && "$publication_classifier" --revisions \
  "$fixture_metadata_head" "$fixture_maintenance_head")"
[[ "$fixture_maintenance_publish" == 'publish_mode=none' ]] \
  || fail "merge-6 maintenance fixture did not skip publication: $fixture_maintenance_publish"

publish_base="$ROOT_DIR/tests/fixtures/supported_version.json"
publish_base_bases="$checked_in_base_manifest"
publish_base_row_count="$(
  jq -ner \
    --slurpfile versions "$publish_base" \
    --slurpfile bases "$publish_base_bases" \
    '($versions[0].supported_versions | length)
     * ($bases[0].bases | length)'
)"

dispatch_plan="$("$publication_classifier" --workflow-dispatch "$publish_base" "$publish_base_bases")"
assert_contains 'publish_mode=full' "$dispatch_plan"
assert_contains 'publish_needed=true' "$dispatch_plan"
dispatch_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$dispatch_plan")"
[[ "$(jq -er '.include | length' <<< "$dispatch_matrix")" == "$publish_base_row_count" ]] \
  || fail 'workflow_dispatch did not plan every supported Flutter/base row'

migration_repo="$test_dir/base-migration-repo"
git init -q "$migration_repo"
git -C "$migration_repo" config user.name base-migration-test
git -C "$migration_repo" config user.email base-migration-test@example.invalid
mkdir -p "$migration_repo/scripts"
cp "$publish_base" "$migration_repo/supported_version.json"
cp "$pre_ubuntu26_bases" "$migration_repo/supported_bases.json"
printf 'three-base validation policy\n' > "$migration_repo/scripts/validate-supported-bases.sh"
git -C "$migration_repo" add \
  supported_version.json \
  supported_bases.json \
  scripts/validate-supported-bases.sh
git -C "$migration_repo" -c commit.gpgsign=false commit -qm 'fixture: historical three-base manifest'
migration_base="$(git -C "$migration_repo" rev-parse HEAD)"
cp "$checked_in_base_manifest" "$migration_repo/supported_bases.json"
printf 'four-base validation policy\n' > "$migration_repo/scripts/validate-supported-bases.sh"
git -C "$migration_repo" add \
  supported_bases.json \
  scripts/validate-supported-bases.sh
git -C "$migration_repo" -c commit.gpgsign=false commit -qm 'fixture: add Debian base'
migration_head="$(git -C "$migration_repo" rev-parse HEAD)"
migration_plan="$(cd "$migration_repo" && "$publication_classifier" --revisions \
  "$migration_base" "$migration_head" supported_version.json supported_bases.json)"
assert_contains 'publish_mode=selective' "$migration_plan"
assert_contains 'publish_needed=true' "$migration_plan"
migration_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$migration_plan")"
jq -e '
  (.include | length == 3)
  and
  (all(.include[]; .base_id == "ubuntu26.04"))
' <<< "$migration_matrix" >/dev/null \
  || fail 'three-base to four-base migration did not plan Ubuntu 26.04 rows'
migration_ci="$(cd "$migration_repo" && "$classifier" --revisions \
  "$migration_base" "$migration_head")"
[[ "$migration_ci" == 'ci_mode=full' ]] \
  || fail "manifest plus validator migration did not require full CI: $migration_ci"

control_plane_repo="$test_dir/control-plane-repo"
git init -q "$control_plane_repo"
git -C "$control_plane_repo" config user.name control-plane-test
git -C "$control_plane_repo" config user.email control-plane-test@example.invalid
mkdir -p "$control_plane_repo/scripts" "$control_plane_repo/tests"
cp "$publish_base" "$control_plane_repo/supported_version.json"
cp "$publish_base_bases" "$control_plane_repo/supported_bases.json"
printf 'README baseline\n' > "$control_plane_repo/README.md"
printf 'classifier baseline\n' > "$control_plane_repo/scripts/classify-publication.sh"
printf 'test baseline\n' > "$control_plane_repo/tests/scripts_test.sh"
git -C "$control_plane_repo" add .
git -C "$control_plane_repo" -c commit.gpgsign=false commit -qm 'fixture: initial control-plane files'
control_plane_base="$(git -C "$control_plane_repo" rev-parse HEAD)"
printf 'README update\n' > "$control_plane_repo/README.md"
printf 'classifier update\n' > "$control_plane_repo/scripts/classify-publication.sh"
printf 'test update\n' > "$control_plane_repo/tests/scripts_test.sh"
git -C "$control_plane_repo" add README.md scripts/classify-publication.sh tests/scripts_test.sh
git -C "$control_plane_repo" -c commit.gpgsign=false commit -qm 'fixture: control-plane-only change'
control_plane_head="$(git -C "$control_plane_repo" rev-parse HEAD)"
control_plane_ci="$(cd "$control_plane_repo" && "$classifier" --revisions \
  "$control_plane_base" "$control_plane_head")"
[[ "$control_plane_ci" == 'ci_mode=full' ]] \
  || fail "control-plane-only revision range did not require full CI: $control_plane_ci"
control_plane_plan="$(cd "$control_plane_repo" && "$publication_classifier" --revisions \
  "$control_plane_base" "$control_plane_head" supported_version.json supported_bases.json)"
assert_contains 'publish_mode=none' "$control_plane_plan"
assert_contains 'publish_matrix={"include":[]}' "$control_plane_plan"
assert_contains 'publish_needed=false' "$control_plane_plan"
control_plane_matrix="$(sed -n 's/^publish_matrix=//p' <<< "$control_plane_plan")"
[[ "$(jq -er '.include | length' <<< "$control_plane_matrix")" == 0 ]] \
  || fail 'control-plane-only change attempted publication'

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
[[ "$(jq -er '.include | length' <<< "$selective_matrix")" == "$expected_base_count" ]] \
  || fail 'selective planner did not contain one patch replacement for all bases'
[[ "$(jq -er 'all(.include[]; .version == "1.2.4")' <<< "$selective_matrix")" == true ]] \
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
[[ "$(jq -er '.include | length' <<< "$new_minor_matrix")" == "$expected_base_count" ]] \
  || fail 'new-minor planner did not contain one release for all bases'
[[ "$(jq -er 'all(.include[]; .version == "2.1.0")' <<< "$new_minor_matrix")" == true ]] \
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
jq '.bases |= map(if .id == "ubuntu24.04" then .reference = "ubuntu:24.04@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" else . end)' \
  "$checked_in_base_manifest" > "$current_base_update"
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
cp "$checked_in_base_manifest" "$broken_base_repo/supported_bases.json"
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
[[ "$(jq -er '.include | length' <<< "$patch_matrix")" == "$expected_base_count" ]] \
  || fail 'publish matrix did not contain one patch replacement for all bases'
[[ "$(jq -er 'all(.include[]; .version == "1.2.4")' <<< "$patch_matrix")" == true ]] \
  || fail 'publish matrix omitted the replacement patch'
[[ "$(jq -er '[.include[].base_id] | sort == ["debian13", "debian13-slim", "ubuntu24.04", "ubuntu26.04"]' \
  <<< "$patch_matrix")" == true ]] \
  || fail 'publish matrix did not cover all four production bases'

watcher_regression_old_manifest="$test_dir/watcher-3.47.3-old.json"
jq '
  .supported_versions[-1] = (.supported_versions[-1]
    | .version = "3.47.3"
    | .revision = "6666666666666666666666666666666666666666"
    | .archive = "stable/linux/flutter_linux_3.47.3-stable.tar.xz"
    | .archive_sha256 = "3333333333333333333333333333333333333333333333333333333333333333")
' "$publish_base" > "$watcher_regression_old_manifest"
"$validator" "$watcher_regression_old_manifest"

watcher_patch_manifest="$test_dir/watcher-3.47.4.json"
jq '
  .supported_versions |= map(
    if .version == "3.47.3" then
      .version = "3.47.4"
      | .revision = "7777777777777777777777777777777777777777"
      | .archive = "stable/linux/flutter_linux_3.47.4-stable.tar.xz"
      | .archive_sha256 = "1111111111111111111111111111111111111111111111111111111111111111"
    else . end
  )
' "$watcher_regression_old_manifest" > "$watcher_patch_manifest"
"$validator" "$watcher_patch_manifest"
watcher_patch_matrix="$("$publish_matrix_script" "$watcher_regression_old_manifest" "$watcher_patch_manifest" \
  "$checked_in_base_manifest" "$checked_in_base_manifest")"
jq -e --argjson expected_base_count "$expected_base_count" '
  (.include | length == $expected_base_count)
  and (all(.include[]; .version == "3.47.4"))
  and ([.include[] | [.version, .base_id]] | unique | length == $expected_base_count)
' <<< "$watcher_patch_matrix" >/dev/null \
  || fail '3.47.3 to 3.47.4 watcher update did not plan one replacement row per supported base'

stale_merge_repo="$test_dir/stale-merge-result-repo"
git init -q "$stale_merge_repo"
git -C "$stale_merge_repo" config user.name stale-merge-result-test
git -C "$stale_merge_repo" config user.email stale-merge-result-test@example.invalid
cp "$watcher_regression_old_manifest" "$stale_merge_repo/supported_version.json"
jq --arg ref \
  'ubuntu:24.04@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '.bases |= map(if .id == "ubuntu24.04" then .reference = $ref else . end)' \
  "$checked_in_base_manifest" > "$stale_merge_repo/supported_bases.json"
printf 'stale merge result fixture\n' > "$stale_merge_repo/README.md"
git -C "$stale_merge_repo" add supported_version.json supported_bases.json README.md
git -C "$stale_merge_repo" -c commit.gpgsign=false commit -qm 'fixture: stale watcher common ancestor'
stale_merge_common="$(git -C "$stale_merge_repo" rev-parse HEAD)"

git -C "$stale_merge_repo" checkout -q -b stale-pr "$stale_merge_common"
jq '
  .supported_versions |= map(
    if .version == "3.47.3" then
      .version = "3.47.4"
      | .revision = "7777777777777777777777777777777777777777"
      | .archive = "stable/linux/flutter_linux_3.47.4-stable.tar.xz"
      | .archive_sha256 = "1111111111111111111111111111111111111111111111111111111111111111"
    else . end
  )
' "$stale_merge_repo/supported_version.json" > "$test_dir/stale-pr-versions.json"
mv "$test_dir/stale-pr-versions.json" "$stale_merge_repo/supported_version.json"
"$validator" "$stale_merge_repo/supported_version.json"
git -C "$stale_merge_repo" add supported_version.json
git -C "$stale_merge_repo" -c commit.gpgsign=false commit -qm 'fixture: stale watcher Flutter update'
stale_merge_pr_head="$(git -C "$stale_merge_repo" rev-parse HEAD)"

git -C "$stale_merge_repo" checkout -q -b stale-main "$stale_merge_common"
jq --arg ref \
  'ubuntu:24.04@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  '.bases |= map(if .id == "ubuntu24.04" then .reference = $ref else . end)' \
  "$stale_merge_repo/supported_bases.json" > "$test_dir/stale-main-bases.json"
mv "$test_dir/stale-main-bases.json" "$stale_merge_repo/supported_bases.json"
"$base_validator" "$stale_merge_repo/supported_bases.json"
git -C "$stale_merge_repo" add supported_bases.json
git -C "$stale_merge_repo" -c commit.gpgsign=false commit -qm 'fixture: current main base digest update'
stale_merge_main_head="$(git -C "$stale_merge_repo" rev-parse HEAD)"
git -C "$stale_merge_repo" -c commit.gpgsign=false merge --no-ff --no-edit stale-pr >/dev/null
stale_merge_result="$(git -C "$stale_merge_repo" rev-parse HEAD)"
[[ -n "$stale_merge_result" && "$stale_merge_result" != "$stale_merge_main_head" ]] \
  || fail 'stale watcher fixture did not create a merge result'

stale_old_versions="$test_dir/stale-old-supported_version.json"
stale_old_bases="$test_dir/stale-old-supported_bases.json"
stale_new_versions="$test_dir/stale-tested-supported_version.json"
stale_new_bases="$test_dir/stale-tested-supported_bases.json"
git -C "$stale_merge_repo" show "$stale_merge_main_head:supported_version.json" > "$stale_old_versions"
git -C "$stale_merge_repo" show "$stale_merge_main_head:supported_bases.json" > "$stale_old_bases"
cp "$stale_merge_repo/supported_version.json" "$stale_new_versions"
cp "$stale_merge_repo/supported_bases.json" "$stale_new_bases"
stale_merge_matrix="$("$publish_matrix_script" \
  "$stale_old_versions" "$stale_new_versions" \
  "$stale_old_bases" "$stale_new_bases")"
jq -e \
  --argjson expected_base_count "$expected_base_count" \
  --slurpfile bases "$checked_in_base_manifest" '
  (.include | length == $expected_base_count)
  and (all(.include[]; .version == "3.47.4"))
  and ([.include[] | [.version, .base_id]] | unique | length == $expected_base_count)
  and (([.include[].base_id] | sort) == ([$bases[0].bases[].id] | sort))
  and ([.include[] | select(.base_id == "ubuntu24.04"
      and .base_reference == "ubuntu:24.04@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")]
      | length == 1)
  and (all(.include[]; (.base_reference | contains("aaaaaaaa")) | not))
' <<< "$stale_merge_matrix" >/dev/null \
  || fail 'stale watcher merge-result matrix used the wrong Flutter/base state'
assert_matrix_rows_match_manifests \
  "$stale_merge_matrix" \
  "$stale_new_versions" \
  "$stale_new_bases" \
  'stale watcher merge-result'

flutter_metadata_manifest="$test_dir/flutter-metadata-update.json"
jq '
  .supported_versions |= map(
    if .version == "3.47.3" then
      .revision = "8888888888888888888888888888888888888888"
      | .archive_sha256 = "2222222222222222222222222222222222222222222222222222222222222222"
    else . end
  )
' "$watcher_regression_old_manifest" > "$flutter_metadata_manifest"
"$validator" "$flutter_metadata_manifest"
flutter_metadata_matrix="$("$publish_matrix_script" "$watcher_regression_old_manifest" "$flutter_metadata_manifest" \
  "$checked_in_base_manifest" "$checked_in_base_manifest")"
jq -e --argjson expected_base_count "$expected_base_count" '
  (.include | length == $expected_base_count)
  and (all(.include[]; .version == "3.47.3"))
' <<< "$flutter_metadata_matrix" >/dev/null \
  || fail 'Flutter metadata-only update did not plan that version across every supported base'

jq '.supported_versions += [{
  "version": "2.1.0",
  "channel": "stable",
  "revision": "8888888888888888888888888888888888888888",
  "archive": "stable/linux/flutter_linux_2.1.0-stable.tar.xz",
  "archive_sha256": "2222222222222222222222222222222222222222222222222222222222222222"
}]' "$publish_base" > "$test_dir/publish-new-minor.json"
new_minor_matrix="$("$publish_matrix_script" "$publish_base" "$test_dir/publish-new-minor.json" \
  "$publish_base_bases" "$publish_base_bases")"
[[ "$(jq -er '.include | length' <<< "$new_minor_matrix")" == "$expected_base_count" ]] \
  || fail 'publish matrix did not contain one new minor for all bases'
[[ "$(jq -er 'all(.include[]; .version == "2.1.0")' <<< "$new_minor_matrix")" == true ]] \
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
jq '.bases |= map(if .id == "ubuntu26.04" then .reference = "ubuntu:26.04@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" else . end)' \
  "$checked_in_base_manifest" > "$changed_base"
changed_base_matrix="$("$publish_matrix_script" "$publish_base" "$publish_base" \
  "$checked_in_base_manifest" "$changed_base")"
[[ "$(jq -er '.include | length' <<< "$changed_base_matrix")" == 3 ]] \
  || fail 'base digest change should publish every current Flutter for that base'
[[ "$(jq -er '[.include[] | select(.base_id == "ubuntu26.04")] | length' <<< "$changed_base_matrix")" == 3 ]] \
  || fail 'base digest change selected the wrong base'

new_base_matrix="$("$publish_matrix_script" "$publish_base" "$publish_base" \
  "$pre_ubuntu26_bases" "$checked_in_base_manifest")"
jq -e '
  (.include | length == 3)
  and
  (all(.include[]; .base_id == "ubuntu26.04"))
' <<< "$new_base_matrix" >/dev/null \
  || fail 'new Ubuntu 26.04 base should publish every current Flutter for Ubuntu 26.04 only'

retired_base_matrix="$("$publish_matrix_script" "$publish_base" "$publish_base" \
  "$checked_in_base_manifest" "$pre_ubuntu26_bases")"
[[ "$(jq -er '.include | length' <<< "$retired_base_matrix")" == 0 ]] \
  || fail 'base retirement should publish nothing'

union_matrix="$("$publish_matrix_script" "$publish_base" \
  "$test_dir/publish-patch.json" "$checked_in_base_manifest" "$changed_base")"
[[ "$(jq -er '.include | length' <<< "$union_matrix")" == 6 ]] \
  || fail 'Flutter and base changes should use their union'
[[ "$(jq -er '[.include[] | [.version, .base_id]] | unique | length' <<< "$union_matrix")" == 6 ]] \
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
  jq "$filter" "$live_manifest" > "$test_dir/invalid.json"
  assert_fails "$validator" "$test_dir/invalid.json"
done

mutated_version="$(jq -er '
  .supported_versions[0].version
  | split(".")
  | "\(.[0]).\(.[1]).\((.[2] | tonumber) + 1)"
' "$live_manifest")"
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
' "$live_manifest" > "$test_dir/duplicate-minor.json"
duplicate_minor_output="$test_dir/duplicate-minor.out"
if "$validator" "$test_dir/duplicate-minor.json" > "$duplicate_minor_output" 2>&1; then
  fail 'validator accepted duplicate Flutter minor line'
fi
assert_contains 'duplicate Flutter minor line' "$(< "$duplicate_minor_output")"

metadata_flutter_version="1.2.3"
metadata_repository_sha="c9a6c484230f8b5e408ec57be1ef71dee1e77020"

while IFS= read -r base_id; do
  assert_metadata_matches_base_manifest \
    "$metadata_flutter_version" \
    "$metadata_repository_sha" \
    "$base_id" \
    "$live_base_manifest"
done < <(jq -r '.bases[].id' "$live_base_manifest")

base_index=0
while IFS= read -r base_id; do
  base_index=$((base_index + 1))
  rotated_hex="$(printf '%064x' "$base_index")"
  rotated_bases="$test_dir/rotated-$base_id.json"

  jq \
    --arg id "$base_id" \
    --arg digest "sha256:$rotated_hex" '
      .bases |= map(
        if .id == $id then
          .reference =
            ((.reference | split("@")[0]) + "@" + $digest)
        else
          .
        end
      )
    ' "$live_base_manifest" > "$rotated_bases"

  "$base_validator" "$rotated_bases"
  assert_matrix_matches_manifests \
    "$live_manifest" \
    "$rotated_bases" \
    "Base watcher digest rotation for $base_id"
  assert_metadata_matches_base_manifest \
    "$metadata_flutter_version" \
    "$metadata_repository_sha" \
    "$base_id" \
    "$rotated_bases"
done < <(jq -r '.bases[].id' "$live_base_manifest")

assert_fails "$ROOT_DIR/scripts/image-metadata.sh" 3.47.3 \
  c9a6c484230f8b5e408ec57be1ef71dee1e77020 unknown-base "$live_base_manifest"
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

publish_source="$(sed -n '1,400p' "$ROOT_DIR/.github/workflows/publish.yml")"
publish_cleanup_source="$(sed -n '/^      - name: Remove tested image/,$p' <<< "$publish_source")"
publication_source="$(sed -n '1,280p' "$publication_classifier")"
ci_source="$(sed -n '1,400p' "$ROOT_DIR/.github/workflows/ci.yml")"
classifier_source="$(sed -n '1,180p' "$classifier")"
expected_build_arg_keys="$(
  printf '%s\n' \
    BASE_IMAGE \
    FLUTTER_VERSION \
    FLUTTER_CHANNEL \
    FLUTTER_REVISION \
    FLUTTER_ARCHIVE_SHA256 \
    SOURCE_REVISION \
    | sort
)"
build_arg_keys() {
  awk '
    /^          build-args: \|$/ { in_block = 1; next }
    in_block && $0 !~ /^            [A-Z_][A-Z0-9_]*=/ { exit }
    in_block {
      key = $0
      sub(/=.*/, "", key)
      sub(/^[[:space:]]*/, "", key)
      print key
    }
  ' <<< "$1" | sort
}
workflow_step() {
  awk -v target="$1" '
    $0 == "      - name: " target { in_step = 1; print; next }
    in_step && $0 ~ /^      - name: / { exit }
    in_step { print }
  ' <<< "$2"
}
line_number() {
  awk -v needle="$1" 'index($0, needle) { print NR; exit }' <<< "$2"
}
assert_before() {
  local before="$1"
  local after="$2"
  local source="$3"
  local before_line after_line
  before_line="$(line_number "$before" "$source")"
  after_line="$(line_number "$after" "$source")"
  [[ "$before_line" =~ ^[0-9]+$ && "$after_line" =~ ^[0-9]+$ ]] \
    || fail "missing workflow order marker: $before -> $after"
  (( before_line < after_line )) \
    || fail "workflow order is wrong: $before -> $after"
}
ci_docker_setup_source="$(workflow_step \
  'Set up Docker with containerd image store' "$ci_source")"
publish_docker_setup_source="$(workflow_step \
  'Set up Docker with containerd image store' "$publish_source")"
ci_docker_verify_source="$(workflow_step \
  'Verify containerd image store' "$ci_source")"
publish_docker_verify_source="$(workflow_step \
  'Verify containerd image store' "$publish_source")"
ci_build_source="$(workflow_step 'Build image' "$ci_source")"
publish_build_source="$(workflow_step 'Build image locally' "$publish_source")"
ci_attest_source="$(workflow_step 'Verify local build attestations' "$ci_source")"
publish_attest_source="$(workflow_step 'Verify local build attestations' "$publish_source")"
publish_push_source="$(workflow_step 'Push tested image and capture digest' "$publish_source")"
[[ "$(grep -c '^classify_path() {' <<< "$publication_source")" == 1 ]] \
  || fail 'publication path policy must have one classify_path helper'
[[ "$(grep -c 'Dockerfile|\.dockerignore|scripts/image-metadata\.sh' \
  <<< "$publication_source")" == 1 ]] \
  || fail 'publication artifact input policy must have one path table'
assert_no_text_match 'awk.*digest:' "$publish_source"
for docker_setup_source in "$ci_docker_setup_source" "$publish_docker_setup_source"; do
  assert_contains 'id: docker' "$docker_setup_source"
  assert_contains 'uses: docker/setup-docker-action@77e84dbf09b47d1e29270283c22f16145aa85ca1' \
    "$docker_setup_source"
  assert_contains 'version: v29.8.0' "$docker_setup_source"
  assert_contains '"containerd-snapshotter": true' "$docker_setup_source"
done
for docker_verify_source in "$ci_docker_verify_source" "$publish_docker_verify_source"; do
  assert_contains "docker info --format '{{json .DriverStatus}}'" "$docker_verify_source"
  assert_contains "grep -F 'io.containerd.snapshotter.v1'" "$docker_verify_source"
done
for build_source in "$ci_build_source" "$publish_build_source"; do
  assert_contains 'platforms: linux/amd64' "$build_source"
  assert_contains 'load: true' "$build_source"
  assert_contains 'push: false' "$build_source"
  assert_contains 'provenance: mode=max,version=v1' "$build_source"
  assert_contains 'sbom: true' "$build_source"
done
assert_contains 'provenance: mode=max,version=v1' "$ci_source"
assert_contains 'provenance: mode=max,version=v1' "$publish_source"
assert_contains 'sbom: true' "$ci_source"
assert_contains 'sbom: true' "$publish_source"
assert_no_text_match 'provenance: false' "$ci_source"
assert_no_text_match 'provenance: false' "$publish_source"
assert_no_text_match '\.RepoDigests' "$publish_push_source"
assert_contains 'docker buildx imagetools inspect' "$publish_push_source"
assert_contains '.Manifest.Digest' "$publish_push_source"
assert_contains '.Provenance.SLSA' "$publish_push_source"
assert_contains '.SBOM.SPDX' "$publish_push_source"
assert_contains "docker info --format '{{json .DriverStatus}}'" "$ci_source"
assert_contains "docker info --format '{{json .DriverStatus}}'" "$publish_source"
assert_contains 'io.containerd.snapshotter.v1' "$ci_source"
assert_contains 'io.containerd.snapshotter.v1' "$publish_source"
for workflow_name in ci publish; do
  workflow_source="$ci_source"
  attest_source="$ci_attest_source"
  [[ "$workflow_name" == publish ]] && workflow_source="$publish_source"
  [[ "$workflow_name" == publish ]] && attest_source="$publish_attest_source"
  [[ "$(build_arg_keys "$workflow_source")" == "$expected_build_arg_keys" ]] \
    || fail "$workflow_name build-args keys differ from the public whitelist"
  build_args_source="$(sed -n '/^          build-args: |$/,/^$/p' <<< "$workflow_source")"
  assert_no_text_match 'secrets\.' "$build_args_source"
  assert_contains 'name: Verify local build attestations' "$attest_source"
  assert_contains 'curl' "$attest_source"
  assert_contains '--fail-with-body' "$attest_source"
  assert_contains '--silent' "$attest_source"
  assert_contains '--show-error' "$attest_source"
  assert_contains '--unix-socket "$docker_socket"' "$attest_source"
  assert_contains '--get' "$attest_source"
  assert_contains "--data-urlencode 'platform={\"os\":\"linux\",\"architecture\":\"amd64\"}'" \
    "$attest_source"
  assert_contains "--data-urlencode 'statement=1'" "$attest_source"
  assert_contains 'http://localhost/v1.55/images/${image}/attestations' "$attest_source"
  assert_contains 'expected_base_digest="${{ matrix.base_reference }}"' "$attest_source"
  assert_contains 'expected_base_digest="${expected_base_digest##*@}"' "$attest_source"
  assert_contains 'expected_base_digest="${expected_base_digest#sha256:}"' "$attest_source"
  assert_contains "printf '%s' \"\$expected_base_digest\" | tr '[:upper:]' '[:lower:]'" \
    "$attest_source"
  assert_before 'expected_base_digest="${expected_base_digest#sha256:}"' \
    "printf '%s' \"\$expected_base_digest\" | tr '[:upper:]' '[:lower:]'" \
    "$attest_source"
  assert_before "printf '%s' \"\$expected_base_digest\" | tr '[:upper:]' '[:lower:]'" \
    '[[ "$expected_base_digest" =~ ^[0-9a-f]{64}$ ]]' "$attest_source"
  assert_contains 'jq --arg digest "$expected_base_digest" -e' "$attest_source"
  assert_contains 'type == "array"' "$attest_source"
  assert_contains 'PredicateType' "$attest_source"
  assert_contains 'https://slsa.dev/provenance/v1' "$attest_source"
  assert_contains 'https://spdx.dev/Document' "$attest_source"
  assert_contains '.Statement.predicateType' "$attest_source"
  assert_contains '.Statement.predicate.buildDefinition' "$attest_source"
  assert_contains '.Statement.predicate.runDetails' "$attest_source"
  assert_contains 'https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md' \
    "$attest_source"
  assert_contains '.Statement.predicate.buildDefinition.resolvedDependencies[]?' \
    "$attest_source"
  assert_contains '.digest.sha256 == $digest' "$attest_source"
  assert_contains '.Statement.predicate.buildDefinition.internalParameters.buildConfig.llbDefinition' \
    "$attest_source"
  assert_contains '.Statement.predicate.runDetails.metadata.buildkit_completeness.request' \
    "$attest_source"
  assert_contains '.Statement.predicate.SPDXID == "SPDXRef-DOCUMENT"' "$attest_source"
  assert_contains '.Statement.predicate.spdxVersion | type == "string"' "$attest_source"
  assert_no_text_match 'BUILD_METADATA' "$attest_source"
  assert_no_text_match 'steps\.build\.outputs\.metadata' "$attest_source"
  assert_no_text_match 'buildx\.build\.ref' "$attest_source"
  assert_no_text_match 'history inspect' "$attest_source"
  assert_no_text_match 'Attachments\[\]\.Type' "$attest_source"
  assert_contains 'DOCKER_SOCKET: ${{ steps.docker.outputs.sock }}' "$attest_source"
  assert_contains 'docker_socket_uri="${DOCKER_SOCKET:?docker/setup-docker-action did not return a socket}"' \
    "$attest_source"
  assert_contains 'case "$docker_socket_uri" in' "$attest_source"
  assert_contains 'unix://*)' "$attest_source"
  assert_contains 'docker_socket="${docker_socket_uri#unix://}"' "$attest_source"
  assert_contains 'if [[ ! -S "$docker_socket" ]]; then' "$attest_source"
  assert_contains 'Docker socket does not exist or is not a Unix socket: %s\n' "$attest_source"
  assert_contains '--unix-socket "$docker_socket"' "$attest_source"
  assert_no_text_match '--unix-socket /var/run/docker\.sock' "$attest_source"
done
assert_contains 'image="ghcr.io/mes-systems/containerized-flutter:${{ steps.metadata.outputs.tag }}"' \
  "$ci_attest_source"
assert_contains 'image="${{ env.IMAGE_NAME }}:${{ steps.metadata.outputs.tag }}"' \
  "$publish_attest_source"
assert_no_text_match '^        id: build$' "$ci_build_source"
assert_contains 'id: build' "$publish_build_source"
assert_contains 'expected_digest=' "$publish_push_source"
assert_contains 'steps.build.outputs.digest' "$publish_push_source"
assert_contains 'expected_base_digest="${{ matrix.base_reference }}"' "$publish_push_source"
assert_contains 'expected_base_digest="${expected_base_digest##*@}"' "$publish_push_source"
assert_contains 'expected_base_digest="${expected_base_digest#sha256:}"' "$publish_push_source"
assert_contains "printf '%s' \"\$expected_base_digest\" | tr '[:upper:]' '[:lower:]'" \
  "$publish_push_source"
assert_before 'expected_base_digest="${expected_base_digest#sha256:}"' \
  "printf '%s' \"\$expected_base_digest\" | tr '[:upper:]' '[:lower:]'" \
  "$publish_push_source"
assert_before "printf '%s' \"\$expected_base_digest\" | tr '[:upper:]' '[:lower:]'" \
  '[[ "$expected_base_digest" =~ ^[0-9a-f]{64}$ ]]' "$publish_push_source"
assert_contains 'jq --arg digest "$expected_base_digest" -e' "$publish_push_source"
assert_contains '.buildDefinition.resolvedDependencies[]' "$publish_push_source"
assert_contains '.digest.sha256 == $digest' "$publish_push_source"
assert_contains 'registry_digest=' "$publish_push_source"
assert_contains 'canonical_digest=' "$publish_push_source"
assert_contains 'docker push "$IMAGE_NAME:$BUILD_TAG"' "$publish_push_source"
assert_contains 'docker push "$IMAGE_NAME:$CANONICAL_TAG"' "$publish_push_source"
assert_contains '[[ "$canonical_digest" == "$registry_digest" ]]' "$publish_push_source"
assert_contains 'printf '\''digest=%s\n'\'' "$registry_digest"' "$publish_push_source"
assert_before 'name: Verify containerd image store' 'name: Set up Docker Buildx' "$ci_source"
assert_before 'name: Verify containerd image store' 'name: Set up Docker Buildx' "$publish_source"
assert_before 'name: Verify local build attestations' 'name: Smoke test image' "$ci_source"
assert_before 'name: Verify local build attestations' 'name: Smoke test image' "$publish_source"
assert_before 'docker push "$IMAGE_NAME:$BUILD_TAG"' 'provenance=' "$publish_push_source"
assert_before 'provenance=' 'docker push "$IMAGE_NAME:$CANONICAL_TAG"' "$publish_push_source"
assert_before 'sbom=' 'docker push "$IMAGE_NAME:$CANONICAL_TAG"' "$publish_push_source"
assert_before 'name: Smoke test image' 'name: Log in to GHCR' "$publish_source"
assert_before 'name: Log in to GHCR' 'docker push "$IMAGE_NAME:$BUILD_TAG"' "$publish_source"
assert_before 'docker push "$IMAGE_NAME:$BUILD_TAG"' \
  'docker push "$IMAGE_NAME:$CANONICAL_TAG"' "$publish_source"
assert_before 'docker push "$IMAGE_NAME:$CANONICAL_TAG"' \
  'name: Attest published image' "$publish_source"
assert_contains 'push-to-registry: false' "$publish_source"
assert_contains 'create-storage-record: false' "$publish_source"
assert_no_text_match 'artifact-metadata: write' "$publish_source"
assert_contains 'Remove tested image' "$ci_source"
assert_contains 'Remove tested image' "$publish_source"
assert_contains 'test image leaked after cleanup' "$publish_cleanup_source"
assert_no_text_match '\|\| true' "$publish_cleanup_source"
assert_before 'name: Set up Docker with containerd image store' \
  'name: Verify containerd image store' "$ci_source"
assert_before 'name: Set up Docker with containerd image store' \
  'name: Verify containerd image store' "$publish_source"
assert_before 'name: Set up Docker Buildx' 'name: Build image' "$ci_source"
assert_before 'name: Set up Docker Buildx' 'name: Build image locally' "$publish_source"
assert_before 'name: Build image' 'name: Verify local build attestations' "$ci_source"
assert_before 'name: Build image locally' 'name: Verify local build attestations' "$publish_source"

ci_cleanup_source="$(sed -n '/^      - name: Remove tested image/,/^  ci-gate:/p' <<< "$ci_source")"
ci_metadata_source="$(sed -n '/^      - name: Derive image metadata/,/^      - name: Set up Docker Buildx/p' <<< "$ci_source")"
assert_contains 'scripts/classify-changes.sh --revisions' "$ci_source"
assert_contains 'scripts/validate-supported-bases.sh supported_bases.json' "$ci_source"
assert_contains 'scripts/build-matrix.sh supported_version.json supported_bases.json' "$ci_source"
assert_contains 'scripts/publish-matrix.sh' "$ci_source"
assert_contains 'ci_mode' "$ci_source"
assert_contains 'build_needed' "$ci_source"
assert_contains '            none)' "$ci_source"
assert_contains '            selective)' "$ci_source"
assert_contains 'ci_mode=full' "$ci_source"
assert_contains 'matrix.base_reference' "$ci_source"
assert_contains 'BASE_IMAGE=${{ matrix.base_reference }}' "$ci_source"
assert_contains 'cache-from: type=gha,scope=flutter-${{ matrix.version }}-${{ matrix.base_id }}' "$ci_source"
assert_contains 'cache-to: type=gha,mode=max,scope=flutter-${{ matrix.version }}-${{ matrix.base_id }}' "$ci_source"
assert_no_text_match 'ubuntu:24\.04' "$ci_source"
assert_no_text_match 'image-metadata\.sh.*Dockerfile' "$ci_source"
assert_contains '.pull_request.base.sha' "$ci_source"
assert_contains '.pull_request.head.sha' "$ci_source"
assert_contains 'git show "$base_sha:supported_version.json"' "$ci_source"
assert_contains 'cp supported_version.json "$new_versions"' "$ci_source"
assert_contains 'cp supported_bases.json "$new_bases"' "$ci_source"
assert_no_text_match 'git show "\$head_sha:supported_version\.json"|git show "\$head_sha:supported_bases\.json"' \
  "$ci_source"
assert_contains 'selective CI matrix is inconsistent with the tested manifests' "$ci_source"
assert_contains 'scripts/validate-supported-bases.sh --allow-multiple "$old_bases"' "$ci_source"
assert_contains 'falling back to full CI' "$ci_source"
assert_contains 'unexpected empty matrix' "$ci_source"
assert_contains "if: needs.manifest.outputs.ci_mode != 'none'" "$ci_source"
assert_contains 'name: build (${{ matrix.version }}, ${{ matrix.base_id }})' "$ci_source"
assert_contains 'name: CI gate' "$ci_source"
assert_contains 'if: always()' "$ci_source"
assert_contains 'CI_MODE: ${{ needs.manifest.outputs.ci_mode }}' "$ci_source"
assert_contains 'BUILD_RESULT: ${{ needs.build.result }}' "$ci_source"
assert_contains 'BUILD_NEEDED: ${{ needs.manifest.outputs.build_needed }}' "$ci_source"
assert_contains 'MATRIX: ${{ needs.manifest.outputs.matrix }}' "$ci_source"
assert_contains 'run: |' "$ci_metadata_source"
assert_contains 'test image leaked after cleanup' "$ci_cleanup_source"
assert_no_text_match '\|\| true' "$ci_cleanup_source"
assert_no_text_match 'ref:.*pull_request\.head\.sha' "$ci_source"
assert_no_text_match 'paths-ignore:' "$ci_source"
assert_no_text_match 'requires_toolchain_ci' "$ci_source"
assert_contains 'git merge-base "$base" "$head"' "$classifier_source"
assert_contains 'git diff --name-only --no-renames -z "$merge_base" "$head" --' "$classifier_source"
assert_no_text_match 'git diff --name-only --no-renames -z "\$base" "\$head" --' \
  "$classifier_source"

assert_contains 'scripts/classify-publication.sh' "$publish_source"
assert_contains 'name: publish (${{ matrix.version }}, ${{ matrix.base_id }})' "$publish_source"
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
readme_source="$(< "$ROOT_DIR/README.md")"
assert_contains 'dedicated base watcher' "$readme_source"
assert_contains 'BuildKit provenance:' "$readme_source"
assert_contains 'describes how the OCI image was built' "$readme_source"
assert_contains 'GitHub Artifact Attestation:' "$readme_source"
assert_contains 'authenticates that the exact published digest came from the' "$readme_source"
assert_contains 'SLSA provenance format: v1' "$readme_source"
assert_contains 'BuildKit provenance mode: max' "$readme_source"
assert_contains 'SBOM format: SPDX' "$readme_source"
assert_contains "--format '{{json .Provenance.SLSA}}'" "$readme_source"
assert_contains "--format '{{json .SBOM.SPDX}}'" "$readme_source"
assert_contains 'exact published artifact => exact OCI digest' "$readme_source"
assert_contains 'creates its proposal commit through GitHub' "$readme_source"
assert_contains 'GitHub signs' "$readme_source"
assert_contains 'no persistent commit-signing private key' "$readme_source"
assert_contains 'changes use the affected image matrix' "$readme_source"
assert_contains 'Manual CI dispatch always runs the full matrix' "$readme_source"
assert_no_text_match 'SLSA Level 3|fully SLSA compliant|end-to-end SLSA|fully reproducible' \
  "$readme_source"

watcher_source="$(sed -n '1,360p' "$ROOT_DIR/.github/workflows/flutter-release-watch.yml")"
assert_contains 'cron: "30 3 * * *"' "$watcher_source"
assert_contains 'automation/flutter-support-update' "$watcher_source"
assert_contains 'releases_linux.json' "$watcher_source"
assert_contains 'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1' "$watcher_source"
assert_contains 'environment:' "$watcher_source"
assert_contains 'name: flutter-release-watcher' "$watcher_source"
assert_contains 'deployment: false' "$watcher_source"
assert_contains 'client-id: ${{ vars.FLUTTER_WATCHER_CLIENT_ID }}' "$watcher_source"
assert_contains 'private-key: ${{ secrets.FLUTTER_WATCHER_PRIVATE_KEY }}' "$watcher_source"
assert_contains 'name: Create and verify GitHub-signed watcher commit' "$watcher_source"
assert_contains 'git rev-parse --verify '\''refs/remotes/origin/main^{commit}'\''' "$watcher_source"
assert_contains 'automation/tmp/flutter-support-update-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}' "$watcher_source"
assert_contains 'gh api graphql --input -' "$watcher_source"
assert_contains 'CreateCommitOnBranchInput!' "$watcher_source"
assert_contains 'createCommitOnBranch' "$watcher_source"
assert_contains 'repositoryNameWithOwner: $repository' "$watcher_source"
assert_contains '--arg branch_name "$temp_branch"' "$watcher_source"
assert_contains 'branchName: $branch_name' "$watcher_source"
assert_no_text_match 'refName: \$ref' "$watcher_source"
assert_contains 'expectedHeadOid' "$watcher_source"
assert_contains 'supported_version.json", contents: $version_contents' "$watcher_source"
assert_contains 'README.md", contents: $readme_contents' "$watcher_source"
assert_contains 'version_contents="$(base64 < supported_version.json' "$watcher_source"
assert_contains 'readme_contents="$(base64 < README.md' "$watcher_source"
assert_contains 'repos/$GITHUB_REPOSITORY/commits/$commit_oid' "$watcher_source"
assert_contains '.commit.verification.verified == true' "$watcher_source"
assert_contains 'GitHub watcher commit was not verified; refusing branch update' "$watcher_source"
assert_contains 'current_remote="$(gh api' "$watcher_source"
assert_contains 'UpdateRefsInput!' "$watcher_source"
assert_contains 'updateRefs' "$watcher_source"
assert_contains 'beforeOid: $before_oid' "$watcher_source"
assert_contains 'repositoryId: $repository_id' "$watcher_source"
assert_contains 'force: true' "$watcher_source"
assert_contains 'before_oid=0000000000000000000000000000000000000000' "$watcher_source"
assert_contains 'GitHub rejected the guarded watcher branch update' "$watcher_source"
assert_contains 'gh api --method DELETE' "$watcher_source"
assert_contains 'watcher branch tree matches but its head is not verified; recreating it' "$watcher_source"
assert_contains 'existing_details="$(gh api' "$watcher_source"
assert_before '.commit.verification.verified == true' 'updateRefs' "$watcher_source"
assert_before 'GitHub watcher commit was not verified; refusing branch update' 'updateRefs' "$watcher_source"
assert_no_text_match 'git commit|git add|git push|git config user\.(name|email)|bot-user|APP_SLUG|BOT_USER_ID' \
  "$watcher_source"
assert_contains 'security_anomaly' "$watcher_source"
assert_contains 'Configure it for the `main` branch/ref with no required reviewer' "$(< "$ROOT_DIR/README.md")"
assert_no_text_match 'secrets\.FLUTTER_WATCHER_(APP|CLIENT)_ID|app-id:|peter-evans|create-pull-request|github-actions-create-pr|secrets\.PAT|secrets\.GH_TOKEN' \
  "$watcher_source"
assert_no_text_match 'git config user\.name "flutter-release-watcher\[bot\]"' "$watcher_source"

base_watcher_source="$(sed -n '1,360p' "$ROOT_DIR/.github/workflows/base-image-watch.yml")"
assert_contains 'cron: "0 3 * * *"' "$base_watcher_source"
assert_contains 'workflow_dispatch:' "$base_watcher_source"
assert_contains 'group: base-image-watcher' "$base_watcher_source"
assert_contains 'cancel-in-progress: false' "$base_watcher_source"
assert_contains 'contents: read' "$base_watcher_source"
assert_contains 'ref: main' "$base_watcher_source"
assert_contains 'persist-credentials: false' "$base_watcher_source"
assert_contains 'name: flutter-release-watcher' "$base_watcher_source"
assert_contains 'deployment: false' "$base_watcher_source"
assert_contains 'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1' \
  "$base_watcher_source"
assert_contains 'client-id: ${{ vars.FLUTTER_WATCHER_CLIENT_ID }}' "$base_watcher_source"
assert_contains 'private-key: ${{ secrets.FLUTTER_WATCHER_PRIVATE_KEY }}' "$base_watcher_source"
assert_contains 'git fetch --no-tags origin main' "$base_watcher_source"
assert_contains 'automation/base-image-update' "$base_watcher_source"
assert_contains 'git checkout -B "$WATCHER_BRANCH" origin/main' "$base_watcher_source"
assert_contains 'name: Create and verify GitHub-signed watcher commit' "$base_watcher_source"
assert_contains 'git rev-parse --verify '\''refs/remotes/origin/main^{commit}'\''' "$base_watcher_source"
assert_contains 'automation/tmp/base-image-update-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}' "$base_watcher_source"
assert_contains 'gh api graphql --input -' "$base_watcher_source"
assert_contains 'CreateCommitOnBranchInput!' "$base_watcher_source"
assert_contains 'createCommitOnBranch' "$base_watcher_source"
assert_contains 'repositoryNameWithOwner: $repository' "$base_watcher_source"
assert_contains '--arg branch_name "$temp_branch"' "$base_watcher_source"
assert_contains 'branchName: $branch_name' "$base_watcher_source"
assert_no_text_match 'refName: \$ref' "$base_watcher_source"
assert_contains 'expectedHeadOid' "$base_watcher_source"
assert_contains 'supported_bases.json", contents: $base_contents' "$base_watcher_source"
assert_contains 'README.md", contents: $readme_contents' "$base_watcher_source"
assert_contains 'base_contents="$(base64 < supported_bases.json' "$base_watcher_source"
assert_contains 'readme_contents="$(base64 < README.md' "$base_watcher_source"
assert_contains 'repos/$GITHUB_REPOSITORY/commits/$commit_oid' "$base_watcher_source"
assert_contains '.commit.verification.verified == true' "$base_watcher_source"
assert_contains 'GitHub watcher commit was not verified; refusing branch update' "$base_watcher_source"
assert_contains 'current_remote="$(gh api' "$base_watcher_source"
assert_contains 'UpdateRefsInput!' "$base_watcher_source"
assert_contains 'updateRefs' "$base_watcher_source"
assert_contains 'beforeOid: $before_oid' "$base_watcher_source"
assert_contains 'repositoryId: $repository_id' "$base_watcher_source"
assert_contains 'force: true' "$base_watcher_source"
assert_contains 'before_oid=0000000000000000000000000000000000000000' "$base_watcher_source"
assert_contains 'GitHub rejected the guarded watcher branch update' "$base_watcher_source"
assert_contains 'gh api --method DELETE' "$base_watcher_source"
assert_contains 'watcher branch tree matches but its head is not verified; recreating it' "$base_watcher_source"
assert_contains 'existing_details="$(gh api' "$base_watcher_source"
assert_before '.commit.verification.verified == true' 'updateRefs' "$base_watcher_source"
assert_before 'GitHub watcher commit was not verified; refusing branch update' 'updateRefs' "$base_watcher_source"
assert_no_text_match 'git commit|git add|git push|git config user\.(name|email)|bot-user|APP_SLUG|BOT_USER_ID' \
  "$base_watcher_source"
assert_contains 'scripts/update-supported-bases.py' "$base_watcher_source"
assert_contains '--manifest supported_bases.json' "$base_watcher_source"
assert_contains '--readme README.md' "$base_watcher_source"
assert_contains '--write' "$base_watcher_source"
assert_contains 'python3 -m unittest tests/test_update_supported_bases.py' "$base_watcher_source"
assert_contains 'scripts/validate-supported-bases.sh supported_bases.json' "$base_watcher_source"
assert_contains 'tests/scripts_test.sh' "$base_watcher_source"
assert_contains 'git diff --check' "$base_watcher_source"
assert_contains 'gh pr list' "$base_watcher_source"
assert_contains 'gh pr edit' "$base_watcher_source"
assert_contains 'gh pr create' "$base_watcher_source"
assert_contains 'Reconcile obsolete watcher pull request' "$base_watcher_source"
assert_contains "steps.update.outputs.status == 'unchanged'" "$base_watcher_source"
assert_contains "steps.update.outputs.status == 'security_anomaly'" "$base_watcher_source"
assert_contains 'gh pr comment' "$base_watcher_source"
assert_contains 'gh pr close' "$base_watcher_source"
assert_contains 'watcher branch already matches current main and generated files' "$base_watcher_source"
assert_contains 'git diff --quiet "refs/remotes/origin/$WATCHER_BRANCH" --' "$base_watcher_source"
assert_contains 'security_anomaly' "$base_watcher_source"
assert_contains 'gh issue list' "$base_watcher_source"
assert_contains 'gh issue edit' "$base_watcher_source"
assert_contains 'gh issue create' "$base_watcher_source"
assert_no_text_match 'gh pr merge|git push[^\n]*main|secrets\.(PAT|GH_TOKEN)|peter-evans|create-pull-request' \
  "$base_watcher_source"
assert_contains 'BEGIN GENERATED SUPPORTED BASES' "$(< "$ROOT_DIR/README.md")"
assert_contains 'END GENERATED SUPPORTED BASES' "$(< "$ROOT_DIR/README.md")"
assert_no_text_match 'Base refresh automation is.*deferred' "$(< "$ROOT_DIR/README.md")"

while IFS= read -r uses_line; do
  action_ref="$(sed -E 's/.*uses: [^@]+@([^ #]+).*/\1/' <<< "$uses_line")"
  [[ "$action_ref" =~ ^[0-9a-f]{40}$ ]] \
    || fail "GitHub Action is not pinned to a full commit SHA: $uses_line"
done < <(grep -hE '^[[:space:]]+uses: [^@]+@' "$ROOT_DIR"/.github/workflows/*.yml)

printf 'PASS: script and supply-chain guardrails\n'
