#!/usr/bin/env bash
# Canonical local and CI entry point. Each invocation owns a fresh evidence directory.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${repo_root}"
mode="${1:-shell}"
case "${mode}" in shell|docker|build|all) ;; *) echo "usage: $0 shell|docker|build|all" >&2; exit 2 ;; esac
profile="${ZMK_TEST_PROFILE:-0}"
case "${profile}" in 0|1) ;; *) echo 'ZMK_TEST_PROFILE must be 0 or 1.' >&2; exit 2 ;; esac
test_jobs="${ZMK_TEST_JOBS-4}"
case "${test_jobs}" in ''|*[!0-9]*) echo 'ZMK_TEST_JOBS must be an integer from 1 to 16.' >&2; exit 2 ;; esac
while [ "${test_jobs#0}" != "${test_jobs}" ]; do test_jobs="${test_jobs#0}"; done
if [ -z "${test_jobs}" ] || [ "${#test_jobs}" -gt 2 ] || [ "${test_jobs}" -gt 16 ]; then
  echo 'ZMK_TEST_JOBS must be an integer from 1 to 16.' >&2; exit 2
fi
cache_request="${ZMK_DOCKER_CACHE_VOLUME:-}"
cache_prefix="${ZMK_TEST_CACHE_PREFIX:-}"
cache_policy=fresh
[ -z "${cache_request}" ] || cache_policy=explicit
if [ -z "${cache_request}" ] && [ -n "${cache_prefix}" ] && [ "${mode}" != shell ]; then
  case "${cache_prefix}" in zmk-build-script-test-*) ;; *) echo 'Invalid managed test cache prefix.' >&2; exit 2 ;; esac
  case "${cache_prefix}" in *[!a-zA-Z0-9_.-]*) echo 'Invalid managed test cache prefix.' >&2; exit 2 ;; esac
  [ "${#cache_prefix}" -le 128 ] || { echo 'Invalid managed test cache prefix.' >&2; exit 2; }
  cache_digest=
  case "${ZMK_BUILD_IMAGE:-}" in *@sha256:*) cache_digest="${ZMK_BUILD_IMAGE##*@sha256:}" ;; esac
  case "${cache_digest}" in *[!0-9a-fA-F]*) cache_digest= ;; esac
  if [ "${#cache_digest}" = 64 ] && [ -n "${ZMK_DOCKER_PLATFORM:-}" ]; then
    cache_key="$(printf '%s\0%s\0' "${ZMK_BUILD_IMAGE}" "${ZMK_DOCKER_PLATFORM}" | git hash-object --stdin)" || {
      cache_status=$?; echo 'Failed to derive managed test cache identity.' >&2; exit "${cache_status}";
    }
    case "${cache_key}" in ''|*[!0-9a-fA-F]*) echo 'Invalid managed test cache identity.' >&2; exit 1 ;; esac
    case "${#cache_key}" in 40|64) ;; *) echo 'Invalid managed test cache identity.' >&2; exit 1 ;; esac
    cache_request="${cache_prefix}-${cache_key}"
    cache_policy=managed
  fi
fi
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
cache_supplied="${cache_request}"
cache_owned=0
suite_complete=0
case_names=(); case_states=(); case_pids=(); case_exits=()
active_cases=0; interrupted=0; closing=0; cases_recorded=0; docker_ready=0; tools_failed=0
trap 'interrupted=130' INT
trap 'interrupted=143' TERM
export ZMK_DOCKER_CACHE_VOLUME="${cache_request:-zmk-test-$(date -u +%Y%m%d%H%M%S)-$$}"
wait_case() {
  local index="$1" status
  if wait "${case_pids[$index]}"; then status=0; else status=$?; fi
  # A trapped signal can interrupt wait before the worker finishes its cleanup.
  if [ "${interrupted}" != 0 ] && [ "${closing}" = 0 ] && kill -0 "${case_pids[$index]}" 2>/dev/null; then return 0; fi
  # A leader can exit while descendants are still running EXIT/signal cleanup.
  # Drain the acquired group before accepting completion or releasing its cache.
  kill -TERM -- "-${case_pids[$index]}" 2>/dev/null || true
  if kill -0 -- "-${case_pids[$index]}" 2>/dev/null; then
    if ! printf '%s\n' "$(date +%s)" > "${result_dir}/${case_names[$index]}.group-waiting"; then
      [ "${status}" != 0 ] || status=1
    fi
    while kill -0 -- "-${case_pids[$index]}" 2>/dev/null; do sleep 1; done
  fi
  case_exits[$index]="${status}"; case_states[$index]=done
  active_cases=$((active_cases - 1))
  if [ "${case_names[$index]}" = tools ] && [ "${closing}" = 0 ] && [ "${interrupted}" = 0 ]; then
    if [ "${status}" = 0 ]; then prepare_docker; else tools_failed=1; fi
  fi
}
stop_cases() {
  local index
  for index in ${case_names[@]+"${!case_names[@]}"}; do
    [ "${case_states[$index]}" != running ] || kill -TERM -- "-${case_pids[$index]}" 2>/dev/null || true
  done
  for index in ${case_names[@]+"${!case_names[@]}"}; do
    [ "${case_states[$index]}" != running ] || wait_case "${index}"
  done
}
finish_cases() {
  local index name status stored elapsed rest valid
  [ "${cases_recorded}" = 0 ] || return 0
  cases_recorded=1
  for index in ${case_names[@]+"${!case_names[@]}"}; do
    [ "${case_states[$index]}" = done ] || continue
    name="${case_names[$index]}"; status="${case_exits[$index]}"; valid=0; elapsed=0
    if [ -f "${result_dir}/${name}.status" ] && [ ! -L "${result_dir}/${name}.status" ] &&
        IFS=$'\t' read -r stored elapsed rest < "${result_dir}/${name}.status"; then
      if [ -n "${stored}" ] && [ "${stored}" = "${status}" ] && [ -z "${rest}" ]; then
        case "${elapsed}" in ''|*[!0-9]*) ;; *)
          if cmp -s "${result_dir}/${name}.status" <(printf '%s\t%s\n' "${stored}" "${elapsed}"); then valid=1; fi ;;
        esac
      fi
    fi
    if [ "${valid}" != 1 ]; then
      echo "[test] ${name}: missing or invalid completion record" >&2
      [ "${status}" != 0 ] || status=1
      elapsed=0
    fi
    if [ "${profile}" = 1 ] && ! record_profile "${name}" "${status}" 1; then [ "${status}" != 0 ] || status=1; fi
    if [ "${status}" = 0 ]; then
      printf '%s\tPASS\t%s\n' "${name}" "${elapsed}" | tee -a "${result_dir}/results.tsv"
    else
      printf '%s\tFAIL(%s)\t%s\n' "${name}" "${status}" "${elapsed}" | tee -a "${result_dir}/results.tsv"
      tail -n 80 "${result_dir}/${name}.log" >&2 || true
      failed=1
    fi
  done
  if [ "${tools_failed}" = 1 ]; then
    printf 'docker-dependent\tBLOCKED(tools)\t0\n' | tee -a "${result_dir}/results.tsv"
  fi
}
cleanup_cache() {
  local status=$?
  trap '' INT TERM
  closing=1
  stop_cases
  finish_cases
  [ "${interrupted}" = 0 ] || status="${interrupted}"
  if [ "${suite_complete}" != 1 ] && [ "${status}" = 0 ]; then status=1; fi
  if [ "${cache_owned}" = 1 ]; then
    if ! docker volume rm "${ZMK_DOCKER_CACHE_VOLUME}" > "${result_dir}/cache-cleanup.log" 2>&1; then
      echo "Test cache cleanup failed: ${ZMK_DOCKER_CACHE_VOLUME}; see cache-cleanup.log" >&2
      [ "${status}" != 0 ] || status=1
    fi
  fi
  if ! bash "${repo_root}/.github/scripts/check-build-output.sh" publish "tests-${mode}" "${status}" "${result_dir}"; then
    echo 'Publication report preparation failed.' >&2
    [ "${status}" != 0 ] || status=1
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
  printf 'Cache policy: %s\n' "${cache_policy}"
  printf 'Test jobs: %s\n' "${test_jobs}"
} > "${result_dir}/environment.txt" 2>&1
case_worker() {
  local name="$1" start status
  # The coordinator owns cache cleanup/publication and each worker's process group.
  trap - EXIT
  trap ':' INT TERM
  set +m
  case "${name}" in
    syntax) set -- bash -c 'set -e; for file in build.sh scripts/*.sh .github/scripts/*.sh; do bash -n "$file"; done' ;;
    lf) set -- bash .github/scripts/check-lf.sh ;;
    whitespace) set -- git -c core.autocrlf=false diff --check ;;
    lf-contract) set -- bash .github/scripts/test-check-lf.sh ;;
    output-contract) set -- bash .github/scripts/test-check-build-output.sh ;;
    external-contract) set -- bash .github/scripts/test-auto-build-external.sh ;;
    host-contract) set -- env ZMK_TEST_ARTIFACT_DIR="${result_dir}/host-evidence" bash .github/scripts/test-build.sh host ;;
    host-help) set -- bash build.sh --help ;;
    container-help) set -- env ZMK_IN_CONTAINER=1 bash build.sh help ;;
    tools) set -- bash .github/scripts/check-runner-tools.sh ;;
    docker-contract) set -- env ZMK_TEST_ARTIFACT_DIR="${result_dir}/docker-evidence" bash .github/scripts/test-build.sh docker ;;
    firmware) set -- bash .github/scripts/test-build-fixtures.sh ;;
    *) return 2 ;;
  esac
  start="$(date +%s)"
  printf '%s\n' "${start}" > "${result_dir}/${name}.started"
  printf '%q ' "$@" > "${result_dir}/${name}.command"
  printf '\n' >> "${result_dir}/${name}.command"
  # Execute normally, outside an if/function errexit exception, then capture its status.
  set +e
  if [ "${profile}" = 1 ]; then
    { time "$@" > "${result_dir}/${name}.log" 2>&1; } 2> "${result_dir}/${name}.time"
    status=$?
  else
    "$@" > "${result_dir}/${name}.log" 2>&1
    status=$?
  fi
  printf '%s\t%s\n' "${status}" "$(( $(date +%s) - start ))" > "${result_dir}/${name}.status" || return "$?"
  return "${status}"
}
prepare_docker() {
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
  docker_ready=1
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
  case_names+=(syntax lf whitespace lf-contract output-contract external-contract host-contract host-help container-help)
fi
[ "${mode}" = shell ] || case_names+=(tools)
if [ "${mode}" = docker ] || [ "${mode}" = all ]; then case_names+=(docker-contract); fi
if [ "${mode}" = build ] || [ "${mode}" = all ]; then case_names+=(firmware); fi
for index in "${!case_names[@]}"; do case_states[$index]=pending; done
# Start the dependency chain and long independent cases first. Evidence is merged
# in case_names order, independently of launch/completion order.
priority=(tools docker-contract firmware host-contract output-contract external-contract syntax lf whitespace lf-contract host-help container-help)
[ "${test_jobs}" != 1 ] || priority=("${case_names[@]}")
monitor_was_set=0
case $- in *m*) monitor_was_set=1 ;; esac
while :; do
  [ "${interrupted}" = 0 ] || exit "${interrupted}"
  for name in "${priority[@]}"; do
    [ "${active_cases}" -lt "${test_jobs}" ] || break
    for index in "${!case_names[@]}"; do
      [ "${case_names[$index]}" = "${name}" ] && [ "${case_states[$index]}" = pending ] || continue
      case "${name}" in
        docker-contract|firmware)
          if [ "${tools_failed}" = 1 ]; then case_states[$index]=blocked; continue; fi
          [ "${docker_ready}" = 1 ] || continue
          if [ "${name}" = firmware ] && [ "${mode}" = all ]; then
            chain_done=0
            for chain_index in "${!case_names[@]}"; do
              if [ "${case_names[$chain_index]}" = docker-contract ] && [ "${case_states[$chain_index]}" = done ]; then chain_done=1; fi
            done
            [ "${chain_done}" = 1 ] || continue
          fi ;;
      esac
      [ "${interrupted}" = 0 ] || exit "${interrupted}"
      printf '[test] %s\n' "${name}"
      # Bash 3.2 supplies an owned process group without a setsid dependency.
      set -m
      case_worker "${name}" &
      case_pids[$index]=$!
      [ "${monitor_was_set}" = 1 ] || set +m
      case_states[$index]=running; active_cases=$((active_cases + 1))
    done
  done
  pending=0; collected=0
  for index in "${!case_names[@]}"; do
    if [ "${case_states[$index]}" = running ] && ! kill -0 "${case_pids[$index]}" 2>/dev/null; then
      wait_case "${index}"; collected=1
    fi
    [ "${case_states[$index]}" != pending ] || pending=1
  done
  [ "${active_cases}" != 0 ] || [ "${pending}" != 0 ] || break
  [ "${interrupted}" = 0 ] || exit "${interrupted}"
  # A completed prerequisite or freed slot can make another case ready now.
  [ "${collected}" = 0 ] || continue
  # With nothing else ready to launch, wait without repeatedly spawning sleep.
  if [ "${active_cases}" -gt 0 ] && { [ "${pending}" = 0 ] || [ "${active_cases}" = 1 ]; }; then
    for index in "${!case_names[@]}"; do
      [ "${case_states[$index]}" != running ] || { wait_case "${index}"; break; }
    done
  elif [ "${collected}" = 0 ]; then sleep 1; fi
done
finish_cases
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
