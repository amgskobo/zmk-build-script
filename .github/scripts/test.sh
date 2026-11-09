#!/usr/bin/env bash
# Canonical local and CI entry point. Each invocation owns a fresh evidence directory.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${repo_root}"
mode="${1:-shell}"
case "${mode}" in shell|docker|build|all) ;; *) echo "usage: $0 shell|docker|build|all" >&2; exit 2 ;; esac
profile="${ZMK_TEST_PROFILE:-0}"
case "${profile}" in 0|1) ;; *) echo 'ZMK_TEST_PROFILE must be 0 or 1.' >&2; exit 2 ;; esac
mkdir -p .build
if [ -n "${ZMK_TEST_RESULTS:-}" ]; then
  result_dir="${ZMK_TEST_RESULTS}"
  mkdir "${result_dir}" || { echo "Evidence directory must be new: ${result_dir}" >&2; exit 1; }
else
  result_dir="$(mktemp -d ".build/test-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
fi
result_dir="$(cd "${result_dir}" && pwd -P)"
case "${result_dir}/" in
  "${repo_root}/"*)
    if ! git check-ignore -q -- "${result_dir#"${repo_root}/"}/"; then
      echo "Evidence inside the repository must be Git-ignored: ${result_dir}" >&2
      rmdir "${result_dir}"
      exit 1
    fi ;;
esac
export ZMK_TEST_RESULTS="${result_dir}"
cache_supplied="${ZMK_DOCKER_CACHE_VOLUME:-}"
cache_owned=0
suite_complete=0
export ZMK_DOCKER_CACHE_VOLUME="${ZMK_DOCKER_CACHE_VOLUME:-zmk-test-$(date -u +%Y%m%d%H%M%S)-$$}"
cleanup_cache() {
  local status=$?
  if [ "${suite_complete}" != 1 ] && [ "${status}" = 0 ]; then status=1; fi
  if [ "${cache_owned}" = 1 ]; then
    if ! docker volume rm "${ZMK_DOCKER_CACHE_VOLUME}" > "${result_dir}/cache-cleanup.log" 2>&1; then
      echo "Test cache cleanup failed: ${ZMK_DOCKER_CACHE_VOLUME}; see cache-cleanup.log" >&2
      status=1
    fi
  fi
  if ! bash "${repo_root}/.github/scripts/check-build-output.sh" publish "tests-${mode}" "${status}" "${result_dir}"; then
    echo 'Publication report preparation failed.' >&2
    status=1
  fi
  exit "${status}"
}
trap cleanup_cache EXIT
failed=0
printf 'case\tstatus\tseconds\n' > "${result_dir}/results.tsv"
if [ "${profile}" = 1 ]; then
  TIMEFORMAT='%3R'
  printf 'metric\tstatus\tsamples\tseconds\n' > "${result_dir}/profile.tsv"
fi
record_profile() {
  local duration
  IFS= read -r duration < "${result_dir}/$1.time" || return 1
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${duration}" >> "${result_dir}/profile.tsv"
}
source_identity() {
  local file operand count=0 bytes=0
  local LC_ALL=C
  local batch=()
  git ls-files -z --cached --others --exclude-standard > "${result_dir}/file-list" || return "$?"
  while IFS= read -r -d '' file; do
    [ -f "${file}" ] || continue
    operand="./${file}"
    # Keep native Windows argv small; a single long operand retains its own limit.
    if [ "${count}" -gt 0 ] && { [ "${count}" -ge 16 ] ||
        [ "$((bytes + ${#operand} + 1))" -gt 1024 ]; }; then
      cksum "${batch[@]}" || return "$?"
      batch=(); count=0; bytes=0
    fi
    batch+=("${operand}")
    count=$((count + 1)); bytes=$((bytes + ${#operand} + 1))
  done < "${result_dir}/file-list"
  if [ "${count}" -gt 0 ]; then cksum "${batch[@]}" || return "$?"; fi
  return 0
}
if [ "${profile}" = 1 ]; then
  { time source_identity > "${result_dir}/source-before.txt" 2> "${result_dir}/source-before.log"; } 2> "${result_dir}/source-before.time"
  record_profile source-before 0 1
else
  source_identity > "${result_dir}/source-before.txt"
fi
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
  if [ "${profile}" = 1 ]; then
    { time "$@" > "${result_dir}/${name}.log" 2>&1; } 2> "${result_dir}/${name}.time"
    status=$?
    if ! record_profile "${name}" "${status}" 1; then [ "${status}" != 0 ] || status=1; fi
  else
    "$@" > "${result_dir}/${name}.log" 2>&1
    status=$?
  fi
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
profile_work() {
  local operation="$1" number value
  case "${operation}" in
    shell|git)
      for ((number=0; number<20; number++)); do
        if [ "${operation}" = shell ]; then bash -c ':' || return "$?"
        else git --version || return "$?"; fi
      done ;;
    files)
      for ((number=0; number<100; number++)); do
        printf 'synthetic probe\n' > "${result_dir}/file-probe/${number}" || return "$?"
        IFS= read -r value < "${result_dir}/file-probe/${number}" || return "$?"
        [ "${value}" = 'synthetic probe' ] || return 1
      done ;;
    docker)
      for ((number=0; number<5; number++)); do docker --version || return "$?"; done ;;
    *) return 1 ;;
  esac
}
profile_probe() {
  local name="$1" samples="$2" status
  shift 2
  set +e
  { time profile_work "$@" > "${result_dir}/${name}.log" 2>&1; } 2> "${result_dir}/${name}.time"
  status=$?
  if ! record_profile "${name}" "${status}" "${samples}"; then [ "${status}" != 0 ] || status=1; fi
  set -e
  [ "${status}" = 0 ] || failed=1
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
if [ "${profile}" = 1 ]; then
  profile_probe probe-shell-spawn 20 shell
  profile_probe probe-git-version 20 git
  mkdir "${result_dir}/file-probe"
  profile_probe probe-file-write-read 100 files
  rm -rf "${result_dir}/file-probe"
  if [ "${mode}" != shell ]; then profile_probe probe-docker-client 5 docker; fi
  { time source_identity > "${result_dir}/source-after.txt" 2> "${result_dir}/source-after.log"; } 2> "${result_dir}/source-after.time"
  record_profile source-after 0 1
else
  source_identity > "${result_dir}/source-after.txt"
fi
if ! cmp -s "${result_dir}/source-before.txt" "${result_dir}/source-after.txt"; then
  echo 'Source changed during verification; results do not describe one source tree.' >&2
  failed=1
fi
rm "${result_dir}/file-list"
printf '[test] Evidence: %s\n' "${result_dir}"
suite_complete=1
exit "${failed}"
