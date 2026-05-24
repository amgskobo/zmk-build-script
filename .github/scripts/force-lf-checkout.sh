#!/usr/bin/env bash
set -euo pipefail

git config core.autocrlf false
git config core.eol lf
git reset --hard HEAD

fixed=0
while IFS= read -r -d '' file; do
  [ -f "${file}" ] || continue
  if ! LC_ALL=C grep -Iq '' "${file}"; then
    continue
  fi
  if od -An -tx1 "${file}" | grep -qi '0d'; then
    tmp="${file}.lf.$$"
    tr -d '\r' < "${file}" > "${tmp}"
    cat "${tmp}" > "${file}"
    rm -f "${tmp}"
    echo "[lf] normalized ${file}"
    fixed=1
  fi
done < <(git ls-files -z)

if [ "${fixed}" = "1" ]; then
  echo "[lf] normalized tracked text files after checkout"
fi
