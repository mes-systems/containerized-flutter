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

assert_no_output_value() {
  local expected_key="$1"
  local expected_value="$2"
  local output_file="$3"
  local key value
  while IFS='=' read -r key value; do
    [[ "$key" == "$expected_key" && "$value" == "$expected_value" ]] \
      && fail "unexpected output value: $expected_key=$expected_value"
  done < "$output_file"
  return 0
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
assert_publication_mode none .github/workflows/scorecard.yml
assert_publication_mode none scripts/update-supported-versions.py
assert_publication_mode none scripts/update-supported-bases.py
assert_publication_mode none scripts/verify-release.sh
assert_publication_mode none scripts/acquire-flutter.sh
assert_publication_mode none scripts/smoke-test.sh
assert_publication_mode none scripts/classify-changes.sh
assert_publication_mode none tests/test_update_supported_versions.py
assert_publication_mode none tests/test_update_supported_bases.py
assert_publication_mode none LICENSE SECURITY.md .github/dependabot.yml \
  .github/VULNERABILITY_REPORT.yml docs/maintenance.md
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
assert_no_output_value publish_mode full "$broken_plan_output"

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
assert_fails "$ROOT_DIR/scripts/smoke-test.sh" image 3.47.3

python3 "$ROOT_DIR/tests/test_release_script_contracts.py"
ruby "$ROOT_DIR/tests/workflow_contracts_test.rb"

printf 'PASS: script and supply-chain guardrails\n'
