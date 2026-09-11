#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
  printf 'usage: %s VERSION CHANNEL OUTPUT_DIRECTORY\n' "$0" >&2
  exit 2
fi

version="$1"
channel="$2"
output_dir="$3"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { printf 'invalid Flutter version: %s\n' "$version" >&2; exit 1; }
[[ "$channel" == "stable" ]] \
  || { printf 'unsupported Flutter channel: %s\n' "$channel" >&2; exit 1; }
[[ -n "$output_dir" ]] \
  || { printf 'output directory must not be empty\n' >&2; exit 1; }

mkdir -p "$output_dir"
[[ -d "$output_dir" ]] || { printf 'not a directory: %s\n' "$output_dir" >&2; exit 1; }

archive_name="flutter_linux_"$version"-"$channel".tar.xz"
archive_url="https://storage.googleapis.com/flutter_infra_release/releases/"$channel"/linux/"$archive_name
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

curl \
  --fail \
  --show-error \
  --location \
  --retry 5 \
  --retry-all-errors \
  --output "$staging_dir/flutter-sdk.tar.xz.intoto.jsonl" \
  "$archive_url.intoto.jsonl"

[[ -s "$staging_dir/flutter-sdk.tar.xz" ]] || { printf 'empty Flutter archive\n' >&2; exit 1; }
[[ -s "$staging_dir/flutter-sdk.tar.xz.intoto.jsonl" ]] \
  || { printf 'empty Flutter attestation bundle\n' >&2; exit 1; }

mv -f "$staging_dir/flutter-sdk.tar.xz" "$output_dir/flutter-sdk.tar.xz"
mv -f "$staging_dir/flutter-sdk.tar.xz.intoto.jsonl" "$output_dir/flutter-sdk.tar.xz.intoto.jsonl"
printf 'acquired %s and informational attestation bundle in %s\n' "$archive_name" "$output_dir"
