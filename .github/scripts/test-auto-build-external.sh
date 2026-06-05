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
esac
printf 'end %s\n' "${slug}" >> "${FAKE_LOG}"
EOF

ZMK_EXTERNAL_SOURCE_BUILDER="${fake_builder}" \
  FAKE_LOG="${fake_log}" \
  bash "${builder}" \
    --path "${local_one}" --source-slug slow \
    --path "${local_two}" --source-slug fast \
    --path "${local_three}" --source-slug third \
    --source-jobs 2 \
    --mode validate \
    --jobs 1 > "${tmp_dir}/rolling.out" 2>&1

third_start_line="$(grep -n '^start third$' "${fake_log}" | sed -n '1s/:.*//p')"
slow_end_line="$(grep -n '^end slow$' "${fake_log}" | sed -n '1s/:.*//p')"
[ -n "${third_start_line}" ] && [ -n "${slow_end_line}" ] ||
  fail "rolling source log was incomplete: $(cat "${fake_log}")"
[ "${third_start_line}" -lt "${slow_end_line}" ] ||
  fail "source queue waited for the slow batch instead of filling an open slot: $(cat "${fake_log}")"

echo "[test-auto-build-external] ok"
