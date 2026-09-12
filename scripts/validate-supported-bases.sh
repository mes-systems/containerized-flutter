#!/usr/bin/env bash
set -euo pipefail

allow_multiple=false
manifest="supported_bases.json"
while (( $# > 0 )); do
  case "$1" in
    --allow-multiple)
      allow_multiple=true
      ;;
    --)
      shift
      [[ $# == 1 ]] || {
        printf 'usage: %s [--allow-multiple] [supported_bases.json]\n' "$0" >&2
        exit 2
      }
      manifest="$1"
      break
      ;;
    -*)
      printf 'usage: %s [--allow-multiple] [supported_bases.json]\n' "$0" >&2
      exit 2
      ;;
    *)
      [[ "$manifest" == "supported_bases.json" ]] || {
        printf 'usage: %s [--allow-multiple] [supported_bases.json]\n' "$0" >&2
        exit 2
      }
      manifest="$1"
      ;;
  esac
  shift
done

fail() {
  printf '%s: %s\n' "$manifest" "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail 'jq is required'
[[ -f "$manifest" ]] || fail 'file not found'
jq -e . "$manifest" >/dev/null || fail 'invalid JSON'

jq -e 'type == "object" and (keys | sort == ["bases", "schema"])' \
  "$manifest" >/dev/null || fail 'top-level fields must be exactly schema and bases'
jq -e '.schema | type == "number" and floor == . and . == 1' \
  "$manifest" >/dev/null || fail 'schema must be 1'
jq -e '.bases | type == "array" and length > 0' \
  "$manifest" >/dev/null || fail 'bases must be a non-empty array'

base_count="$(jq -er '.bases | length' "$manifest")" || fail 'bases length is unavailable'
if [[ "$allow_multiple" != true && "$base_count" != 3 ]]; then
  fail 'production manifest must contain exactly three base records'
fi

while IFS= read -r base; do
  jq -e 'type == "object" and
    (keys | sort == ["family", "id", "reference", "variant", "version"])' \
    <<< "$base" >/dev/null || fail 'each base must contain exactly the allowed fields'

  read_field() {
    local field="$1"
    jq -er --arg field "$field" \
      '.[$field]
       | select(type == "string" and length > 0)
       | select(test("[[:space:]]") | not)' <<< "$base"
  }

  id="$(read_field id)" || fail 'id must be a non-empty string without whitespace'
  family="$(read_field family)" \
    || fail "family must be a non-empty string without whitespace for $id"
  version="$(read_field version)" \
    || fail "version must be a non-empty string without whitespace for $id"
  variant="$(read_field variant)" \
    || fail "variant must be a non-empty string without whitespace for $id"
  reference="$(read_field reference)" \
    || fail "reference must be a non-empty string without whitespace for $id"

  [[ "$id" =~ ^[a-z0-9]+([.-][a-z0-9]+)*$ ]] \
    || fail "invalid id: $id"
  [[ "$reference" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(\/[a-z0-9]+([._-][a-z0-9]+)*)*:[A-Za-z0-9_][A-Za-z0-9_.-]*@sha256:[0-9a-fA-F]{64}$ ]] \
    || fail "reference must be an immutable repository:tag@sha256 reference for $id"

  image_reference="${reference%@*}"
  image_repository="${image_reference%%:*}"
  image_tag="${image_reference#*:}"
  [[ "$image_repository" == "$family" ]] \
    || fail "reference repository does not match family for $id"
  [[ "$image_tag" == "$version" || "$image_tag" == "$version-"* ]] \
    || fail "reference tag does not match family/version semantics for $id"
done < <(jq -c '.bases[]' "$manifest")

duplicates="$(jq -r '.bases[].id' "$manifest" | sort | uniq -d)"
[[ -z "$duplicates" ]] || fail "duplicate base id: $duplicates"

if [[ "$allow_multiple" != true ]]; then
  [[ "$(jq -r '.bases | map(.id) | join(" ")' "$manifest")" == \
    'ubuntu24.04 debian13 debian13-slim' ]] \
    || fail 'production bases must be ordered ubuntu24.04, debian13, debian13-slim'

  ubuntu="$(jq -c '.bases[0]' "$manifest")"
  [[ "$(jq -r '.family' <<< "$ubuntu")" == ubuntu \
    && "$(jq -r '.version' <<< "$ubuntu")" == 24.04 \
    && "$(jq -r '.variant' <<< "$ubuntu")" == default \
    && "$(jq -r '.reference' <<< "$ubuntu")" == 'ubuntu:24.04@sha256:'* ]] \
    || fail 'production ubuntu24.04 base record is invalid'

  debian="$(jq -c '.bases[1]' "$manifest")"
  [[ "$(jq -r '.family' <<< "$debian")" == debian \
    && "$(jq -r '.version' <<< "$debian")" == 13 \
    && "$(jq -r '.variant' <<< "$debian")" == default \
    && "$(jq -r '.reference' <<< "$debian")" == 'debian:13@sha256:'* ]] \
    || fail 'production debian13 base record is invalid'

  debian_slim="$(jq -c '.bases[2]' "$manifest")"
  [[ "$(jq -r '.family' <<< "$debian_slim")" == debian \
    && "$(jq -r '.version' <<< "$debian_slim")" == 13 \
    && "$(jq -r '.variant' <<< "$debian_slim")" == slim \
    && "$(jq -r '.reference' <<< "$debian_slim")" == 'debian:13-slim@sha256:'* ]] \
    || fail 'production debian13-slim base record is invalid'
fi

printf 'valid: %s\n' "$manifest"
