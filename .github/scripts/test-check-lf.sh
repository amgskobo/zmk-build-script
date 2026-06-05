#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
checker="${repo_root}/.github/scripts/check-lf.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zmk-lf-check.XXXXXX")"

cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

git -C "${tmp_dir}" init -q
git -C "${tmp_dir}" config core.autocrlf false
git -C "${tmp_dir}" config core.eol lf
git -C "${tmp_dir}" config user.email "ci@example.invalid"
git -C "${tmp_dir}" config user.name "CI"

printf 'tracked lf\n' > "${tmp_dir}/tracked.txt"
printf 'a\000b\r\n' > "${tmp_dir}/binary.dat"
git -C "${tmp_dir}" add tracked.txt binary.dat

(cd "${tmp_dir}" && bash "${checker}" >/dev/null)

printf '\r\n' > "${tmp_dir}/untracked-blank-crlf.txt"
if (cd "${tmp_dir}" && bash "${checker}" >"${tmp_dir}/stdout" 2>"${tmp_dir}/stderr"); then
  echo "check-lf.sh missed an untracked blank CRLF text file." >&2
  exit 1
fi
grep -q "CRLF line endings found" "${tmp_dir}/stderr"
rm -f "${tmp_dir}/untracked-blank-crlf.txt"

printf '\r\n' > "${tmp_dir}/tracked-blank-crlf.txt"
git -C "${tmp_dir}" add tracked-blank-crlf.txt
if (cd "${tmp_dir}" && bash "${checker}" >"${tmp_dir}/stdout" 2>"${tmp_dir}/stderr"); then
  echo "check-lf.sh missed a tracked blank CRLF text file." >&2
  exit 1
fi
grep -q "CRLF line endings found" "${tmp_dir}/stderr"

echo "check-lf.sh behavior tests passed."
