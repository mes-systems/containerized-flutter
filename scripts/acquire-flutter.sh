#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  printf 'usage: %s TRUSTED_ARCHIVE_PATH OUTPUT_DIRECTORY\n' "$0" >&2
  exit 2
fi

archive_path="$1"
output_dir="$2"

[[ "$archive_path" =~ ^stable/linux/flutter_linux_[0-9]+\.[0-9]+\.[0-9]+-stable\.tar\.xz$ ]] \
  || { printf 'invalid trusted Flutter archive path: %s\n' "$archive_path" >&2; exit 1; }
[[ -n "$output_dir" ]] \
  || { printf 'output directory must not be empty\n' >&2; exit 1; }

mkdir -p "$output_dir"
[[ -d "$output_dir" ]] || { printf 'not a directory: %s\n' "$output_dir" >&2; exit 1; }

archive_url="https://storage.googleapis.com/flutter_infra_release/releases/$archive_path"
staging_dir="$(mktemp -d "$output_dir/.flutter-acquire.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT

curl \
  --fail \
  --show-error \
  --location \
  --retry 5 \
  --retry-all-errors \
  --output "$staging_dir/flutter-sdk.tar.xz" \
  "$archive_url"

if ! curl \
  --fail \
  --show-error \
  --location \
  --retry 5 \
  --retry-all-errors \
  --output "$staging_dir/flutter-sdk.tar.xz.intoto.jsonl" \
  "$archive_url.intoto.jsonl" \
  || [[ ! -s "$staging_dir/flutter-sdk.tar.xz.intoto.jsonl" ]]; then
  rm -f -- "$staging_dir/flutter-sdk.tar.xz.intoto.jsonl"
  printf 'warning: optional Flutter attestation bundle unavailable; continuing without it\n' >&2
fi

[[ -s "$staging_dir/flutter-sdk.tar.xz" ]] || { printf 'empty Flutter archive\n' >&2; exit 1; }

mv -f "$staging_dir/flutter-sdk.tar.xz" "$output_dir/flutter-sdk.tar.xz"
if [[ -s "$staging_dir/flutter-sdk.tar.xz.intoto.jsonl" ]]; then
  mv -f "$staging_dir/flutter-sdk.tar.xz.intoto.jsonl" \
    "$output_dir/flutter-sdk.tar.xz.intoto.jsonl"
else
  rm -f -- "$output_dir/flutter-sdk.tar.xz.intoto.jsonl"
fi
printf 'acquired %s in %s (attestation bundle is optional diagnostics)\n' \
  "$archive_path" "$output_dir"
