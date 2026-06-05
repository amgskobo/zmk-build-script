#!/usr/bin/env bash
set -euo pipefail

found=0

while IFS= read -r -d '' file; do
  [ -f "${file}" ] || continue
  if ! LC_ALL=C grep -Iq '' "${file}"; then
    continue
  fi
  if od -An -tx1 "${file}" | grep -qi '0d'; then
    echo "${file}: CR byte found"
    found=1
  fi
done < <(
  git ls-files -z
  git ls-files -z --others --exclude-standard
)

if [ "${found}" = "1" ]; then
  echo "CRLF line endings found." >&2
  exit 1
fi
