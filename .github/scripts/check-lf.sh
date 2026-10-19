#!/usr/bin/env bash
set -euo pipefail

files="$(mktemp "${TMPDIR:-/tmp}/zmk-lf-files.XXXXXX")"
trap 'rm -f "${files}"' EXIT
# Keep Git failures visible: process substitution would discard its exit status.
git ls-files -z --cached --others --exclude-standard >"${files}"
found=0
while IFS= read -r -d '' file; do
  [ -f "${file}" ] || continue
  # BSD -U selects binary handling; keep -I last. GNU -U also disables Windows text conversion.
  LC_ALL=C grep -UIq -- '' "${file}" || continue
  # This reads a file directly, with no producer that could receive SIGPIPE.
  if LC_ALL=C grep -qU -- $'\r' "${file}"; then
    printf '%s: CR byte found\n' "${file}"
    found=1
  fi
done <"${files}"
if [ "${found}" = 1 ]; then
  echo 'CR bytes found in text files; use LF line endings.' >&2
  exit 1
fi
