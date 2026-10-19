#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
checker="${repo_root}/.github/scripts/check-lf.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zmk-lf-check.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT
work="${tmp_dir}/repo"
mkdir -p "${work}"
(cd "${work}" && git init -q && git config core.autocrlf false)
cp "${repo_root}/.gitattributes" "${work}/.gitattributes"
printf 'ignored/\n' >"${work}/.gitignore"
printf 'tracked LF\n' >"${work}/tracked.txt"
(cd "${work}" && git add .gitattributes .gitignore tracked.txt)

check() {
  local name="$1" expected="$2" status=0
  (cd "${work}" && bash "${checker}") >"${tmp_dir}/stdout" 2>"${tmp_dir}/stderr" || status=$?
  if [ "${status}" -ne "${expected}" ]; then
    cat "${tmp_dir}/stdout" "${tmp_dir}/stderr" >&2
    echo "LF ${name}: expected ${expected}, got ${status}" >&2
    exit 1
  fi
  if [ "${expected}" = 1 ]; then
    grep -q 'CR byte found' "${tmp_dir}/stdout"
    grep -q 'use LF line endings' "${tmp_dir}/stderr"
  fi
  printf '[lf] %s\n' "${name}"
}

payload() {
  case "$1" in
    crlf) printf 'one\r\ntwo\r\n' ;;
    bare-cr) printf 'one\rtwo\n' ;;
    mixed) printf 'one\ntwo\r\n' ;;
    blank) printf '\r\n' ;;
    control-z) printf 'first\032hidden\r\n' ;;
    large) awk 'BEGIN { printf "\r\n"; for (i=0; i<50000; i++) print "LF payload" }' ;;
  esac
}

check normal 0
: >"${work}/empty.txt"
printf 'no final newline' >"${work}/no-final-newline.txt"
check empty-and-no-final-newline 0
for tracking in tracked untracked; do
  for kind in crlf bare-cr mixed blank large control-z; do
    file="${work}/${tracking} ${kind}.txt"
    payload "${kind}" >"${file}"
    [ "${tracking}" != tracked ] || (cd "${work}" && git add -N -- "${file##*/}")
    check "${tracking}-${kind}" 1
    rm "${file}"
  done
done
printf 'bad\r\n' >"${work}/--leading-dash.txt"
check leading-dash-name 1
rm "${work}/--leading-dash.txt"
check deleted-tracked 0
mkdir "${work}/ignored"
printf 'ignored\r\n' >"${work}/ignored/generated.txt"
printf 'a\000b\r\n' >"${work}/binary.dat"
(cd "${work}" && git add binary.dat)
check ignored-and-binary 0
printf 'a\000b\r\n' | cmp - "${work}/binary.dat"

# Exercise actual Git clean/checkout filters, with no reset and no test commits.
# Repository LF attributes must override the user's Windows checkout preference.
for autocrlf in false true input; do
  (cd "${work}" && git config core.autocrlf "${autocrlf}")
  printf 'first\r\nsecond\r\n' >"${work}/checkout.sh"
  (cd "${work}" && git add checkout.sh)
  rm "${work}/checkout.sh"
  (cd "${work}" && git checkout-index -- checkout.sh)
  printf 'first\nsecond\n' | cmp - "${work}/checkout.sh"
  check "checkout-autocrlf-${autocrlf}" 0
done

mkdir "${tmp_dir}/bad-git"
printf '#!/usr/bin/env sh\nexit 47\n' >"${tmp_dir}/bad-git/git"
chmod +x "${tmp_dir}/bad-git/git"
status=0
(cd "${work}" && PATH="${tmp_dir}/bad-git:${PATH}" bash "${checker}") >/dev/null 2>&1 || status=$?
[ "${status}" -eq 47 ] || { echo "Git failure was hidden: ${status}" >&2; exit 1; }
echo '[lf] git-failure-visible'
echo 'check-lf.sh behavior tests passed.'
