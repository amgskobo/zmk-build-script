#!/usr/bin/env bash
set -euo pipefail

cr="$(printf '\r')"
found=0

while IFS= read -r -d '' file; do
  [ -f "${file}" ] || continue
  if ! LC_ALL=C grep -Iq . "${file}"; then
    continue
  fi
  if LC_ALL=C grep -n "${cr}" "${file}"; then
    found=1
  fi
done < <(git ls-files -z)

if [ "${found}" = "1" ]; then
  echo "CRLF line endings found." >&2
  exit 1
fi
