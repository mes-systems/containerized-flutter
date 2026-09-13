#!/usr/bin/env bash
set -euo pipefail

if (( $# != 4 )); then
  printf 'usage: %s OLD_FLUTTER_MANIFEST NEW_FLUTTER_MANIFEST OLD_BASE_MANIFEST NEW_BASE_MANIFEST\n' "$0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared affected-pair planner for publication and manifest-scoped PR CI.
old_flutter="$1"
new_flutter="$2"
old_bases="$3"
new_bases="$4"

fail() {
  printf 'publish matrix failed: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail 'jq is required'
for manifest in "$old_flutter" "$new_flutter" "$old_bases" "$new_bases"; do
  [[ -f "$manifest" ]] || fail "manifest file not found: $manifest"
done

"$SCRIPT_DIR/validate-supported-versions.sh" "$old_flutter" >/dev/null \
  || fail "invalid old Flutter manifest: $old_flutter"
"$SCRIPT_DIR/validate-supported-versions.sh" "$new_flutter" >/dev/null \
  || fail "invalid new Flutter manifest: $new_flutter"
# Allow synthetic multi-base fixtures here; classify-publication validates the
# production manifests in strict production mode before invoking this planner.
"$SCRIPT_DIR/validate-supported-bases.sh" --allow-multiple "$old_bases" >/dev/null \
  || fail "invalid old base manifest: $old_bases"
"$SCRIPT_DIR/validate-supported-bases.sh" --allow-multiple "$new_bases" >/dev/null \
  || fail "invalid new base manifest: $new_bases"

if ! jq -c \
  --slurpfile old_manifest "$old_flutter" \
  --slurpfile old_base_manifest "$old_bases" \
  --slurpfile new_base_manifest "$new_bases" '
  def find_entry($entries; $field; $value):
    [$entries[] | select(.[$field] == $value)] | first;
  def flutter_changed($old; $new):
    ($old == null) or
    ($old.channel != $new.channel) or
    ($old.revision != $new.revision) or
    ($old.archive != $new.archive) or
    ($old.archive_sha256 != $new.archive_sha256);
  def base_changed($old; $new):
    ($old == null) or ($old != $new);

  ($old_manifest[0].supported_versions) as $old_versions
  | ($old_base_manifest[0].bases) as $old_base_entries
  | ($new_base_manifest[0].bases) as $new_base_entries
  | {include: [
      .supported_versions[] as $version
      | $new_base_entries[] as $base
      | (find_entry($old_versions; "version"; $version.version)) as $old_version
      | (find_entry($old_base_entries; "id"; $base.id)) as $old_base
      | select(flutter_changed($old_version; $version)
          or base_changed($old_base; $base))
      | {
          version: $version.version,
          channel: $version.channel,
          revision: $version.revision,
          archive: $version.archive,
          archive_sha256: $version.archive_sha256,
          base_id: $base.id,
          base_family: $base.family,
          base_version: $base.version,
          base_variant: $base.variant,
          base_reference: $base.reference
        }
    ]}' \
  "$new_flutter"; then
  fail 'could not build selective publication matrix'
fi
