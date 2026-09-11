#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )); then
  printf 'usage: %s DOCKERFILE_PATH\n' "$0" >&2
  exit 2
fi

dockerfile="$1"

fail() {
  printf 'Dockerfile validation failed: %s\n' "$*" >&2
  exit 1
}

[[ -f "$dockerfile" ]] || fail "Dockerfile not found: $dockerfile"

declare -a stage_copy_lines=()
stage=-1
from_count=0
builder_stage=-1
final_stage=-1

while IFS= read -r line; do
  line="${line#"${line%%[!$' \t\r']*}"}"
  [[ -z "$line" || "$line" == \#* ]] && continue

  instruction="${line%%[[:space:]]*}"
  rest="${line:${#instruction}}"
  instruction_upper="$(printf '%s' "$instruction" | tr '[:lower:]' '[:upper:]')"
  case "$instruction_upper" in
    FROM)
      from_count=$((from_count + 1))
      stage=$((stage + 1))
      final_stage="$stage"
      read -r -a from_args <<< "$rest"
      for ((i = 0; i + 1 < ${#from_args[@]}; i++)); do
        from_keyword="$(printf '%s' "${from_args[i]}" | tr '[:upper:]' '[:lower:]')"
        if [[ "$from_keyword" == as && "${from_args[i + 1]}" == flutter-sdk ]]; then
          [[ "$builder_stage" == -1 ]] || fail 'flutter-sdk builder stage is duplicated'
          builder_stage="$stage"
        fi
      done
      ;;
    COPY|ADD)
      ((stage >= 0)) || fail 'COPY appears before the first FROM'
      stage_copy_lines[stage]+="$line"$'\n'
      ;;
  esac
done < <(awk '
  {
    sub(/\r$/, "")
    continued = ($0 ~ /\\[[:space:]]*$/)
    sub(/\\[[:space:]]*$/, "")
    if (buffer == "") buffer = $0
    else buffer = buffer " " $0
    if (!continued) {
      print buffer
      buffer = ""
    }
  }
  END {
    if (buffer != "") print buffer
  }
' "$dockerfile")

((from_count == 2)) || fail 'expected exactly two FROM stages'
[[ "$builder_stage" != -1 ]] || fail 'missing named flutter-sdk builder stage'
[[ "$builder_stage" != "$final_stage" ]] || fail 'flutter-sdk must be a non-final stage'

final_sdk_copy=false
final_copy_lines="${stage_copy_lines[final_stage]-}"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  instruction="${line%%[[:space:]]*}"
  instruction_upper="$(printf '%s' "$instruction" | tr '[:lower:]' '[:upper:]')"
  case "$instruction_upper" in
    COPY) ;;
    ADD) fail 'final stage must not use ADD' ;;
    *) continue ;;
  esac
  rest="${line:${#instruction}}"
  read -r -a copy_args <<< "$rest"
  copy_from=""
  operands=()
  for token in "${copy_args[@]}"; do
    case "$token" in
      --from=*) copy_from="${token#--from=}" ;;
      --*) ;;
      *) operands+=("$token") ;;
    esac
  done

  [[ "$copy_from" == flutter-sdk && "${#operands[@]}" == 2 \
    && "${operands[0]}" == /opt/flutter && "${operands[1]}" == /opt/flutter ]] \
    || fail 'final stage may only COPY /opt/flutter from flutter-sdk'
  final_sdk_copy=true
done <<< "$final_copy_lines"

[[ "$final_sdk_copy" == true ]] \
  || fail 'final stage must COPY /opt/flutter from flutter-sdk'

printf 'PASS: Dockerfile uses a verified builder stage and copies no archive into final stage\n'
