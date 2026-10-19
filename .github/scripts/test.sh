#!/usr/bin/env bash
# Canonical local and CI entry point. Each invocation owns a fresh evidence directory.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${repo_root}"
mode="${1:-shell}"
case "${mode}" in shell|docker|build|all) ;; *) echo "usage: $0 shell|docker|build|all" >&2; exit 2 ;; esac
mkdir -p .build
result_dir="${ZMK_TEST_RESULTS:-.build/test-$(date -u +%Y%m%dT%H%M%SZ)-pid-$$}"
mkdir "${result_dir}" || { echo "Evidence directory must be new: ${result_dir}" >&2; exit 1; }
result_dir="$(cd "${result_dir}" && pwd -P)"
export ZMK_TEST_RESULTS="${result_dir}"
cache_supplied="${ZMK_DOCKER_CACHE_VOLUME:-}"
cache_owned=0
export ZMK_DOCKER_CACHE_VOLUME="${ZMK_DOCKER_CACHE_VOLUME:-zmk-test-$(date -u +%Y%m%d%H%M%S)-$$}"
cleanup_cache() {
  local status=$?
  if [ "${cache_owned}" = 1 ]; then
    if ! docker volume rm "${ZMK_DOCKER_CACHE_VOLUME}" > "${result_dir}/cache-cleanup.log" 2>&1; then
      echo "Test cache cleanup failed: ${ZMK_DOCKER_CACHE_VOLUME}; see cache-cleanup.log" >&2
      status=1
    fi
  fi
  exit "${status}"
}
trap cleanup_cache EXIT
failed=0
printf 'case\tstatus\tseconds\n' > "${result_dir}/results.tsv"
source_identity() {
  local file
  git ls-files -z --cached --others --exclude-standard > "${result_dir}/file-list"
  while IFS= read -r -d '' file; do
    [ ! -f "${file}" ] || cksum "${file}"
  done < "${result_dir}/file-list"
}
source_identity > "${result_dir}/source-before.txt"
{
  git rev-parse HEAD
  git status --short
  uname -a
  bash --version
  printf 'Cache volume: %s\n' "${ZMK_DOCKER_CACHE_VOLUME}"
} > "${result_dir}/environment.txt" 2>&1
run_case() {
  local name="$1" start status
  shift
  start="$(date +%s)"
  printf '[test] %s\n' "${name}"
  printf '%q ' "$@" > "${result_dir}/${name}.command"
  printf '\n' >> "${result_dir}/${name}.command"
  # Execute normally, outside an if/function errexit exception, then capture its status.
  set +e
  "$@" > "${result_dir}/${name}.log" 2>&1
  status=$?
  last_status="${status}"
  set -e
  if [ "${status}" = 0 ]; then
    printf '%s\tPASS\t%s\n' "${name}" "$(( $(date +%s) - start ))" | tee -a "${result_dir}/results.tsv"
  else
    printf '%s\tFAIL(%s)\t%s\n' "${name}" "${status}" "$(( $(date +%s) - start ))" | tee -a "${result_dir}/results.tsv"
    tail -n 80 "${result_dir}/${name}.log" >&2
    failed=1
  fi
}
if [ "${mode}" = shell ] || [ "${mode}" = all ]; then
  run_case syntax bash -c 'set -e; for file in build.sh scripts/*.sh .github/scripts/*.sh; do bash -n "$file"; done'
  run_case lf bash .github/scripts/check-lf.sh
  run_case whitespace git -c core.autocrlf=false diff --check
  run_case lf-contract bash .github/scripts/test-check-lf.sh
  run_case output-contract bash .github/scripts/test-check-build-output.sh
  run_case external-contract bash .github/scripts/test-auto-build-external.sh
  run_case host-contract env ZMK_TEST_ARTIFACT_DIR="${result_dir}/host-evidence" bash .github/scripts/test-build.sh host
  run_case host-help bash build.sh --help
  run_case container-help env ZMK_IN_CONTAINER=1 bash build.sh help
fi
if [ "${mode}" != shell ]; then
  run_case tools bash .github/scripts/check-runner-tools.sh
  if [ "${last_status}" = 0 ]; then
    if [ -z "${cache_supplied}" ]; then
      if docker volume inspect "${ZMK_DOCKER_CACHE_VOLUME}" >/dev/null 2>&1; then
        echo "Fresh test cache already exists: ${ZMK_DOCKER_CACHE_VOLUME}" >&2
        exit 1
      fi
      docker volume create --label zmk-build-script-test=temporary "${ZMK_DOCKER_CACHE_VOLUME}" > "${result_dir}/cache-create.log"
      cache_owned=1
    fi
    docker version > "${result_dir}/docker-version.txt" 2>&1
    docker image inspect "${ZMK_BUILD_IMAGE:-zmkfirmware/zmk-build-arm:stable}" > "${result_dir}/image.json" 2>&1 || true
    if [ "${mode}" = docker ] || [ "${mode}" = all ]; then
      run_case docker-contract env ZMK_TEST_ARTIFACT_DIR="${result_dir}/docker-evidence" bash .github/scripts/test-build.sh docker
    fi
    if [ "${mode}" = build ] || [ "${mode}" = all ]; then
      run_case firmware bash .github/scripts/test-build-fixtures.sh
    fi
  else
    printf 'docker-dependent\tBLOCKED(tools)\t0\n' | tee -a "${result_dir}/results.tsv"
  fi
fi
source_identity > "${result_dir}/source-after.txt"
if ! cmp -s "${result_dir}/source-before.txt" "${result_dir}/source-after.txt"; then
  echo 'Source changed during verification; results do not describe one source tree.' >&2
  failed=1
fi
rm "${result_dir}/file-list"
printf '[test] Evidence: %s\n' "${result_dir}"
exit "${failed}"
