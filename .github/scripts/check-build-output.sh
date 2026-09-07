#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
run_dir="${2:-}"

is_valid_run_dir() {
  local candidate="${1%/}" parent base pid
  case "${candidate}" in
    *..*) return 1 ;;
  esac
  parent="${candidate%/*}"
  base="${candidate##*/}"
  [ "${parent}" != "${candidate}" ] || return 1
  case "${parent}" in
    .build|*/.build) ;;
    *) return 1 ;;
  esac
  case "${base}" in
    run-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-pid-[0-9]*) ;;
    *) return 1 ;;
  esac
  pid="${base##*-pid-}"
  case "${pid}" in
    ""|*[!0-9]*) return 1 ;;
  esac
}

require_valid_run_dir() {
  local candidate="$1" label="$2"
  if ! is_valid_run_dir "${candidate}"; then
    echo "${label} does not match .build/run-YYYY-MM-DD_HH-MM-SS-pid-PID: ${candidate:-<empty>}" >&2
    exit 1
  fi
}

case "${mode}" in
  validate|build) ;;
  *)
    echo "usage: $0 validate|build [run-dir]" >&2
    exit 2
    ;;
esac

if [ -n "${run_dir}" ]; then
  require_valid_run_dir "${run_dir}" "run directory"
  build_summary="${run_dir%/}/build-summary.txt"
else
  if [ ! -d .build ]; then
    echo ".build directory was not created." >&2
    exit 1
  fi

  build_summary=""
  while IFS= read -r summary; do
    candidate_dir="$(dirname "${summary}")"
    require_valid_run_dir "${candidate_dir}" "build summary directory"
    build_summary="${summary}"
  done < <(find .build -mindepth 2 -maxdepth 2 -type f -name build-summary.txt -print | sort)
fi

if [ -z "${build_summary}" ] || [ ! -f "${build_summary}" ]; then
  echo "build-summary.txt was not produced." >&2
  exit 1
fi

run_dir="$(dirname "${build_summary}")"
build_log="${run_dir}/build.log"

if [ ! -f "${build_log}" ]; then
  echo "build.log was not produced beside ${build_summary}." >&2
  exit 1
fi

if ! grep -qx 'Status: SUCCESS' "${build_summary}"; then
  echo "build-summary.txt does not report success: ${build_summary}" >&2
  exit 1
fi

summary_mode="$(sed -n 's/^Mode: //p' "${build_summary}" | tail -n 1)"
if [ "${summary_mode}" != "${mode}" ]; then
  echo "build-summary.txt mode is ${summary_mode:-<missing>}, expected ${mode}: ${build_summary}" >&2
  exit 1
fi

echo "[output] build log: ${build_log}"
echo "[output] build summary: ${build_summary}"

if [ "${mode}" = "build" ]; then
  built_targets="$(sed -n 's/^Built targets: \([0-9][0-9]*\)$/\1/p' "${build_summary}" | tail -n 1)"
  if [ -z "${built_targets}" ]; then
    echo "build-summary.txt does not include Built targets for build mode: ${build_summary}" >&2
    exit 1
  fi

  firmware_list="$(
    find "${run_dir}" -maxdepth 1 -type f \( -name '*.uf2' -o -name '*.hex' -o -name '*.bin' \) -print |
      sort
  )"
  if [ -z "${firmware_list}" ]; then
    echo "No firmware artifact was produced for build mode." >&2
    exit 1
  fi

  firmware_count="$(printf '%s\n' "${firmware_list}" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  if [ "${firmware_count}" -lt "${built_targets}" ]; then
    echo "Firmware artifact count (${firmware_count}) is lower than built target count (${built_targets})." >&2
    exit 1
  fi

  echo "[output] built targets: ${built_targets}"
  echo "[output] firmware artifacts: ${firmware_count}"
  printf '%s\n' "${firmware_list}" | sed 's/^/[output] firmware artifact: /'
fi
