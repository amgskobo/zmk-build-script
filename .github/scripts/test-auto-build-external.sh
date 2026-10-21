#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
builder="${repo_root}/scripts/auto-build-external.sh"
source_builder="${repo_root}/scripts/build-external-source.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zmk-external-test.XXXXXX")"
tmp_dir="$(cd "${tmp_dir}" && pwd -P)"

cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  printf '%s\n' "${haystack}" | grep -F "${needle}" >/dev/null ||
    fail "${label}: ${haystack}"
}

assert_file_contains() {
  local file="$1" needle="$2" label="$3"
  grep -F "${needle}" "${file}" >/dev/null ||
    fail "${label}: $(cat "${file}")"
}

# Bound tests of worker death and a zero-width queue without depending on GNU timeout on the host.
run_bounded() {
  local child timer status
  "$@" &
  child=$!
  (sleep 30; kill -TERM "${child}" 2>/dev/null || true) &
  timer=$!
  if wait "${child}"; then status=0; else status=$?; fi
  kill "${timer}" 2>/dev/null || true
  wait "${timer}" 2>/dev/null || true
  return "${status}"
}

local_one="${tmp_dir}/local-one"
local_two="${tmp_dir}/local-two"
local_three="${tmp_dir}/local-three"
mkdir -p "${local_one}/config" "${local_two}/config" "${local_three}/config"
touch "${local_one}/config/west.yml" "${local_one}/build.yaml"
touch "${local_two}/config/west.yml" "${local_two}/build.yaml"
touch "${local_three}/config/west.yml" "${local_three}/build.yaml"

repos_file="${tmp_dir}/repos.txt"
cat > "${repos_file}" <<'EOF'
# comments and blank lines are ignored
https://github.com/caksoylar/zmk-config.git

https://github.com/urob/zmk-config.git
git@github.com:GEIGEIGEIST/zmk-config-totem.git
git://github.com/example/zmk-config.git
file:///tmp/zmk-config.git
path:local-one
local-two
https://github.com/caksoylar/zmk-config.git
EOF

list="$(bash "${builder}" --list "${repos_file}")"
json="$(bash "${builder}" --list-json "${repos_file}")"

assert_contains "${list}" $'caksoylar-zmk-config\tzmk-cache-external-caksoylar-zmk-config\trepo\thttps://github.com/caksoylar/zmk-config.git' \
  "list did not include caksoylar slug"
assert_contains "${list}" $'urob-zmk-config\tzmk-cache-external-urob-zmk-config\trepo\thttps://github.com/urob/zmk-config.git' \
  "list did not include urob slug"
assert_contains "${list}" $'geigeigeist-zmk-config-totem\tzmk-cache-external-geigeigeist-zmk-config-totem\trepo\tgit@github.com:GEIGEIGEIST/zmk-config-totem.git' \
  "list did not include ssh slug"
assert_contains "${list}" $'example-zmk-config\tzmk-cache-external-example-zmk-config\trepo\tgit://github.com/example/zmk-config.git' \
  "list did not include git protocol slug"
assert_contains "${list}" $'tmp-zmk-config\tzmk-cache-external-tmp-zmk-config\trepo\tfile:///tmp/zmk-config.git' \
  "list did not include file protocol slug"
assert_contains "${list}" $'local-one\tzmk-cache-external-local-one\tpath\t'"${local_one}" \
  "list did not include prefixed local path"
assert_contains "${list}" $'local-two\tzmk-cache-external-local-two\tpath\t'"${local_two}" \
  "list did not include inferred local path"
assert_contains "${list}" $'caksoylar-zmk-config-2\tzmk-cache-external-caksoylar-zmk-config-2\trepo\thttps://github.com/caksoylar/zmk-config.git' \
  "duplicate slug was not made unique"
assert_contains "${json}" '"slug":"caksoylar-zmk-config"' \
  "json list did not include caksoylar slug"
assert_contains "${json}" '"type":"repo"' \
  "json list did not include repo type"
assert_contains "${json}" '"source":"https://github.com/caksoylar/zmk-config.git"' \
  "json list did not include repo source"

path_list="$(bash "${builder}" --list --path "${local_one}" --repo-slug custom-local --path "${local_two}")"
assert_contains "${path_list}" $'custom-local\tzmk-cache-external-custom-local\tpath\t'"${local_one}" \
  "explicit path slug was not honored"
assert_contains "${path_list}" $'local-two\tzmk-cache-external-local-two\tpath\t'"${local_two}" \
  "second explicit path was not listed"

path_cases_file="${tmp_dir}/path-cases.txt"
cat > "${path_cases_file}" <<'EOF'
path://server/share
path:\\server\share
path:C:relative
EOF
path_cases="$(bash "${builder}" --list "${path_cases_file}")"
assert_contains "${path_cases}" $'share\tzmk-cache-external-share\tpath\t//server/share' \
  "UNC slash path was not treated as absolute"
assert_contains "${path_cases}" $'share-2\tzmk-cache-external-share-2\tpath\t\\\\server\\share' \
  "UNC backslash path was not treated as absolute"
assert_contains "${path_cases}" $'c-relative\tzmk-cache-external-c-relative\tpath\t'"${tmp_dir}/C:relative" \
  "drive-relative path was not resolved from the source file"

empty_file="${tmp_dir}/empty.txt"
printf '# no sources\n\n' > "${empty_file}"
[ -z "$(bash "${builder}" --list "${empty_file}")" ] ||
  fail "empty sources file did not produce an empty list"

missing_path="${tmp_dir}/missing"
failure_output="${tmp_dir}/failure.out"
failure_summary="${tmp_dir}/summary.md"

set +e
GITHUB_ACTIONS=true \
  GITHUB_STEP_SUMMARY="${failure_summary}" \
  bash "${builder}" --path "${missing_path}" --source-slug missing --source-jobs 1 > "${failure_output}" 2>&1
failure_status=$?
set -e

[ "${failure_status}" -eq 1 ] ||
  fail "missing source did not fail with status 1: ${failure_status}"
assert_file_contains "${failure_output}" "::error title=External build failed: missing::" \
  "failure annotation was not emitted"
assert_file_contains "${failure_output}" "path not found missing" \
  "missing path failure was not printed"
assert_file_contains "${failure_summary}" '| failure | `missing` | path |' \
  "failure summary row was not written"

invalid_output="${tmp_dir}/invalid.out"
set +e
bash "${builder}" --path "${missing_path}" --source-jobs 0 > "${invalid_output}" 2>&1
invalid_status=$?
set -e

[ "${invalid_status}" -eq 1 ] ||
  fail "invalid source jobs did not fail with status 1: ${invalid_status}"
assert_file_contains "${invalid_output}" "source jobs must be a positive integer" \
  "invalid source jobs error was not printed"

set +e
bash "${source_builder}" --path "${missing_path}" --source-slug missing-direct > "${tmp_dir}/direct.out" 2>&1
direct_status=$?
set -e

[ "${direct_status}" -eq 1 ] ||
  fail "direct missing source did not fail with status 1: ${direct_status}"
assert_file_contains "${tmp_dir}/direct.out" "path not found missing-direct" \
  "direct source helper did not fail before Docker"

set +e
ZMK_EXTERNAL_CLONE_ATTEMPTS=0 \
  bash "${source_builder}" --path "${missing_path}" --source-slug invalid-clone-attempts > "${tmp_dir}/invalid-clone-attempts.out" 2>&1
invalid_clone_attempts_status=$?
set -e

[ "${invalid_clone_attempts_status}" -eq 1 ] ||
  fail "invalid clone attempts did not fail with status 1: ${invalid_clone_attempts_status}"
assert_file_contains "${tmp_dir}/invalid-clone-attempts.out" "clone attempts must be a positive integer" \
  "invalid clone attempts error was not printed"

fake_builder="${tmp_dir}/fake-source-builder.sh"
fake_log="${tmp_dir}/fake-builder.log"
cat > "${fake_builder}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

slug=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-slug)
      slug="$2"
      shift
      ;;
  esac
  shift
done

printf 'start %s\n' "${slug}" >> "${FAKE_LOG}"
case "${slug}" in
  slow) sleep 2 ;;
  killed) kill -KILL "${PPID}"; exit 0 ;;
  failed) exit 7 ;;
esac
printf 'end %s\n' "${slug}" >> "${FAKE_LOG}"
EOF

ZMK_EXTERNAL_SOURCE_BUILDER="${fake_builder}" \
  FAKE_LOG="${fake_log}" \
  bash "${builder}" \
    --path "${local_one}" --source-slug slow \
    --path "${local_two}" --source-slug fast \
    --path "${local_three}" --source-slug third \
    --source-jobs 02 \
    --mode validate \
    --jobs 01 > "${tmp_dir}/rolling.out" 2>&1

third_start_line="$(grep -n '^start third$' "${fake_log}" | sed -n '1s/:.*//p')"
slow_end_line="$(grep -n '^end slow$' "${fake_log}" | sed -n '1s/:.*//p')"
[ -n "${third_start_line}" ] && [ -n "${slow_end_line}" ] ||
  fail "rolling source log was incomplete: $(cat "${fake_log}")"
[ "${third_start_line}" -lt "${slow_end_line}" ] ||
  fail "source queue waited for the slow batch instead of filling an open slot: $(cat "${fake_log}")"

# All-zero decimal spellings must be rejected, including queue width and clone attempts.
for option in --jobs --source-jobs; do
  if run_bounded bash "${builder}" --path "${missing_path}" "${option}" 00 >"${tmp_dir}/zero.out" 2>&1; then
    fail "${option} 00 was accepted"
  fi
  assert_file_contains "${tmp_dir}/zero.out" 'must be a positive integer: 00' "all-zero ${option} was not rejected"
done
if ZMK_EXTERNAL_CLONE_ATTEMPTS=00 bash "${source_builder}" --path "${missing_path}" >"${tmp_dir}/clone-zero.out" 2>&1; then
  fail 'all-zero clone attempts were accepted'
fi
assert_file_contains "${tmp_dir}/clone-zero.out" 'clone attempts must be a positive integer: 00' 'all-zero clone attempts were not rejected'

# A source worker killed before it can publish a status must fail promptly and release its queue slot.
set +e
ZMK_EXTERNAL_SOURCE_BUILDER="${fake_builder}" FAKE_LOG="${fake_log}" \
  run_bounded bash "${builder}" \
    --path "${local_one}" --source-slug killed \
    --path "${local_two}" --source-slug failed \
    --path "${local_three}" --source-slug after-kill \
    --source-jobs 1 >"${tmp_dir}/killed.out" 2>&1
killed_status=$?
set -e
[ "${killed_status}" -eq 1 ] || fail "worker death did not finish with failure status: ${killed_status}"
assert_file_contains "${tmp_dir}/killed.out" 'killed: failure' 'killed source was not recorded'
assert_file_contains "${tmp_dir}/killed.out" 'failed: failure' 'ordinary child failure was not preserved'
assert_file_contains "${tmp_dir}/killed.out" 'after-kill: success' 'queue did not continue after worker death'
assert_file_contains "${tmp_dir}/killed.out" '=== Done: 2 failure(s) ===' 'worker failure total was incorrect'

# Clone setup must never remove a pre-existing name after create fails. Later failures
# must remove only containers created by this process, including each failed retry.
clone_bin="${tmp_dir}/clone-bin"
mkdir -p "${clone_bin}"
cat > "${clone_bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CLONE_TEST_LOG}"
case "$1" in
  info|rm) exit 0 ;;
  create)
    [ "${CLONE_TEST_PHASE}" != create ] || exit 23
    counter="${CLONE_TEST_LOG}.count"
    attempt=0
    [ ! -f "${counter}" ] || read -r attempt < "${counter}"
    attempt=$((attempt + 1))
    printf '%s\n' "${attempt}" > "${counter}"
    printf '%064d\n' "${attempt}" ;;
  start) [ "${CLONE_TEST_PHASE}" != start ] || exit 23 ;;
  cp)
    [ "${CLONE_TEST_PHASE}" = success ] || exit 23
    mkdir -p "$3"
    printf 'fresh source\n' > "$3/fresh.txt" ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${clone_bin}/docker"
for phase in create start copy; do
  clone_log="${tmp_dir}/clone-${phase}.commands"
  if PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE="${phase}" \
      ZMK_EXTERNAL_CLONE_ATTEMPTS=2 bash "${source_builder}" \
      --repo https://example.invalid/zmk-config.git --source-slug "test-clone-${phase}-$$" >"${tmp_dir}/clone-${phase}.out" 2>&1; then
    fail "injected clone ${phase} failure was accepted"
  fi
  if [ "${phase}" = create ]; then
    if grep -q '^rm ' "${clone_log}"; then fail 'a failed clone create removed an unowned container'; fi
  else
    expected=2
    [ "${phase}" != copy ] || expected=1
    actual="$(grep -c '^rm ' "${clone_log}")"
    [ "${actual}" -eq "${expected}" ] || fail "clone ${phase} cleanup count: expected ${expected}, got ${actual}"
    for ((attempt=1; attempt<=expected; attempt++)); do
      expected_id="$(printf '%064d' "${attempt}")"
      grep -qx "rm -f ${expected_id}" "${clone_log}" || fail "clone ${phase} cleanup used a replaceable name: $(cat "${clone_log}")"
      grep -qx "start -a ${expected_id}" "${clone_log}" || fail "clone ${phase} start used a replaceable name: $(cat "${clone_log}")"
    done
    if [ "${phase}" = copy ]; then
      grep -q "^cp ${expected_id}:/tmp/source/\. " "${clone_log}" || fail "clone copy used a replaceable name: $(cat "${clone_log}")"
    fi
  fi
  if [ "${phase}" != copy ]; then
    actual="$(grep -c '^create ' "${clone_log}")"
    [ "${actual}" -eq 2 ] || fail "clone ${phase} retry count: ${actual}"
  fi
done

# A failed removal must not merge a fresh clone into stale host content.
clone_parent="${tmp_dir}/clone-clear"
clone_target="${clone_parent}/blocked"
mkdir -p "${clone_target}"
printf 'stale source\n' > "${clone_target}/stale.txt"
clone_real_rm="$(command -v rm)"
cat > "${clone_bin}/rm" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "${arg}" = "${CLONE_FAIL_RM_TARGET}" ]; then
    echo 'injected clone cleanup failure' >&2
    exit 23
  fi
done
exec "${CLONE_REAL_RM}" "$@"
EOF
chmod +x "${clone_bin}/rm"
clone_log="${tmp_dir}/clone-clear.commands"
if PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE=copy \
    CLONE_FAIL_RM_TARGET="${clone_target}" CLONE_REAL_RM="${clone_real_rm}" \
    bash -c 'source "$1"; WORK_DIR="$2"; main --repo https://example.invalid/config.git --source-slug blocked' \
    _ "${source_builder}" "${clone_parent}" >"${tmp_dir}/clone-clear.out" 2>&1; then
  fail 'failed clone destination cleanup was accepted'
fi
assert_file_contains "${tmp_dir}/clone-clear.out" 'injected clone cleanup failure' 'cleanup injection did not run'
[ -f "${clone_target}/stale.txt" ] || fail 'cleanup injection did not preserve stale source'
if grep -q '^create ' "${clone_log}"; then
  fail "clone started after destination cleanup failed: $(cat "${clone_log}")"
fi

# Once cleanup works again, no stale file may reach the builder.
rm "${clone_bin}/rm"
clone_probe="${tmp_dir}/clone-probe.sh"
cat > "${clone_probe}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ ! -e "$1/stale.txt" ]
grep -qx 'fresh source' "$1/fresh.txt"
EOF
chmod +x "${clone_probe}"
if ! PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE=success \
    bash -c 'source "$1"; WORK_DIR="$2"; BUILD_SCRIPT="$3"; main --repo https://example.invalid/config.git --source-slug blocked --mode build' \
    _ "${source_builder}" "${clone_parent}" "${clone_probe}" >"${tmp_dir}/clone-recovered.out" 2>&1; then
  fail "clone did not recover after destination cleanup was repaired: $(cat "${tmp_dir}/clone-recovered.out")"
fi
[ ! -e "${clone_target}" ] || fail 'successful clone left its host copy behind'
[ "$(grep -c '^create ' "${clone_log}")" = 1 ] || fail 'failed cleanup started an extra clone'
expected_id="$(printf '%064d' 1)"
grep -qx "rm -f ${expected_id}" "${clone_log}" || fail 'recovered clone lost container ownership'

echo "[test-auto-build-external] ok"
