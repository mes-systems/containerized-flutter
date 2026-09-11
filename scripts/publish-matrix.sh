#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  printf 'usage: %s OLD_MANIFEST NEW_MANIFEST\n' "$0" >&2
  exit 2
fi

old_manifest="$1"
new_manifest="$2"

command -v jq >/dev/null 2>&1 || {
  printf 'publish matrix failed: jq is required\n' >&2
  exit 1
}
[[ -f "$old_manifest" && -f "$new_manifest" ]] || {
  printf 'publish matrix failed: manifest file not found\n' >&2
  exit 1
}
jq -e 'type == "object" and (.supported_versions | type == "array")' \
  "$old_manifest" >/dev/null
jq -e 'type == "object" and (.supported_versions | type == "array")' \
  "$new_manifest" >/dev/null

jq -c --slurpfile old "$old_manifest" '
  def changed($old; $new):
    ($old == null) or
    ($old.channel != $new.channel) or
    ($old.revision != $new.revision) or
    ($old.archive != $new.archive) or
    ($old.archive_sha256 != $new.archive_sha256);
  {include: [
    .supported_versions[] as $new
    | (($old[0].supported_versions // [])
       | map(select(.version == $new.version)) | .[0]) as $old_entry
    | select(changed($old_entry; $new))
    | {version: $new.version, channel: $new.channel,
       revision: $new.revision, archive: $new.archive,
       archive_sha256: $new.archive_sha256}
  ]}' "$new_manifest"
