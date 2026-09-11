#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  printf 'usage: %s OLD_MANIFEST NEW_MANIFEST\n' "$0" >&2
  exit 2
fi

old_manifest="$1"
new_manifest="$2"
old_normalized=""

cleanup() {
  [[ -z "$old_normalized" || "$old_normalized" == "$old_manifest" ]] \
    || rm -f -- "$old_normalized"
}
trap cleanup EXIT

fail() {
  printf 'publish matrix failed: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail 'jq is required'
[[ -f "$old_manifest" && -f "$new_manifest" ]] || fail 'manifest file not found'

"$(dirname "$0")/validate-supported-versions.sh" "$new_manifest" >/dev/null \
  || fail "current manifest is invalid: $new_manifest"

old_schema="$(jq -er '.schema | select(type == "number" and floor == .)' "$old_manifest")" \
  || fail "previous manifest has no valid schema"
case "$old_schema" in
  1)
    if ! jq -e '
      type == "object"
      and .schema == 1
      and (.support_policy | type == "object")
      and (.support_policy | has("channel") and has("minor_lines") and has("selection"))
      and (.supported_versions | type == "array")
      and all(.supported_versions[]; type == "object" and
        (keys | sort == ["archive", "archive_sha256", "channel", "revision", "version"])
      )
    ' "$old_manifest" >/dev/null; then
      fail 'previous schema 1 manifest is malformed'
    fi
    old_normalized="$(mktemp "${TMPDIR:-/tmp}/publish-old-normalized.XXXXXX")" \
      || fail 'could not create normalized previous-manifest file'
    if ! jq '
      .schema = 2
      | .support_policy.platforms = ["linux/amd64"]
      | .supported_versions |= map(
          . as $entry
          | {
              version: $entry.version,
              channel: $entry.channel,
              revision: $entry.revision,
              artifacts: {
                "linux/amd64": {
                  upstream_arch: "x64",
                  archive: $entry.archive,
                  archive_sha256: $entry.archive_sha256
                }
              }
            }
        )
    ' "$old_manifest" > "$old_normalized"; then
      fail 'could not normalize previous schema 1 manifest'
    fi
    ;;
  2)
    old_normalized="$old_manifest"
    ;;
  *)
    fail "unsupported previous manifest schema: $old_schema"
    ;;
esac

"$(dirname "$0")/validate-supported-versions.sh" "$old_normalized" >/dev/null \
  || fail 'previous supported version manifest is invalid'

if ! jq -c --slurpfile old "$old_normalized" '
  def rows:
    [.supported_versions[] as $entry
     | $entry.artifacts | to_entries[] as $artifact
     | {
         version: $entry.version,
         platform: $artifact.key,
         channel: $entry.channel,
         revision: $entry.revision,
         upstream_arch: $artifact.value.upstream_arch,
         archive: $artifact.value.archive,
         archive_sha256: $artifact.value.archive_sha256,
         platform_slug: ($artifact.key | gsub("/"; "-"))
       }];
  ($old[0] | rows) as $old_rows
  | (rows) as $new_rows
  | {
      include: [
        $new_rows[] as $new
        | ($old_rows | map(select(.version == $new.version and .platform == $new.platform)) | .[0]) as $old
        | select(
            ($old == null)
            or ($old.channel != $new.channel)
            or ($old.revision != $new.revision)
            or ($old.upstream_arch != $new.upstream_arch)
            or ($old.archive != $new.archive)
            or ($old.archive_sha256 != $new.archive_sha256)
          )
        | $new
      ]
    }
' "$new_manifest"; then
  fail 'could not compare normalized publication artifacts'
fi
