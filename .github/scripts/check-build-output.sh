#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
run_dir="${2:-}"

public_case_label() {
  case "$1" in syntax|lf|whitespace|lf-contract|output-contract|external-contract|host-contract|host-help|container-help|tools|docker-contract|firmware|docker-dependent) return 0 ;; esac
  return 1
}

public_case_status() {
  local number
  case "$1" in
    PASS|BLOCKED\(tools\)) return 0 ;;
    FAIL\(*\))
      number="${1#FAIL(}"; number="${number%)}"
      case "${number}" in ''|*[!0-9]*) return 1 ;; esac
      [ "${number}" -gt 0 ] && [ "${number}" -le 255 ] ;;
    *) return 1 ;;
  esac
}

publish_report() {
  local kind="$1" status="${2:-}" evidence="${3:-}" public_dir=.build/public file temporary label value rest number rows=0 outcome
  [ ! -L .build ] && [ ! -L "${public_dir}" ] || { echo 'Publication directory must not be a symlink.' >&2; return 1; }
  mkdir -p "${public_dir}" || return 1
  if [ "${kind}" = clear ]; then
    for file in tests-shell tests-docker tests-build tests-all build validate; do
      rm -f "${public_dir}/${file}.txt" || return 1
    done
    rm -f .build/ci-source.status .build/ci-source.record || return 1
    return 0
  fi
  if [ "${kind}" = verify ]; then
    local reports=0 header modes outcomes codes notices line report_status report_outcome has_failure
    for label in tests-shell tests-docker tests-build tests-all build validate; do
      file="${public_dir}/${label}.txt"
      [ ! -L "${file}" ] || { echo 'Publication report must not be a symlink.' >&2; return 1; }
      [ ! -e "${file}" ] || [ -f "${file}" ] || return 1
      [ -f "${file}" ] || continue
      reports=$((reports + 1))
      header=0 modes=0 outcomes=0 codes=0 notices=0 has_failure=0 report_status= report_outcome=
      while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
          'Sanitized publication report') header=$((header + 1)) ;;
          "Mode: ${label}") modes=$((modes + 1)) ;;
          'Outcome: SUCCESS'|'Outcome: FAILED') outcomes=$((outcomes + 1)); report_outcome="${line#Outcome: }" ;;
          'CI exit status: '*)
            report_status="${line#CI exit status: }"
            case "${report_status}" in ''|*[!0-9]*) return 1 ;; esac
            [ "${report_status}" -le 255 ] || return 1
            codes=$((codes + 1)) ;;
          'Detailed logs and firmware, when produced, are retained locally.') notices=$((notices + 1)) ;;
          *)
            value="${line#*: }"; number="${line%%: *}"
            public_case_label "${number}" && public_case_status "${value}" || return 1
            [ "${value}" = PASS ] || has_failure=1 ;;
        esac
      done < "${file}"
      [ "${header}" = 1 ] && [ "${modes}" = 1 ] && [ "${outcomes}" = 1 ] && [ "${codes}" = 1 ] && [ "${notices}" = 1 ] || return 1
      if [ "${report_outcome}" = SUCCESS ]; then [ "${report_status}" = 0 ] && [ "${has_failure}" = 0 ] || return 1; fi
    done
    [ "${reports}" -gt 0 ] || { echo 'No publication reports were produced.' >&2; return 1; }
    return 0
  fi
  case "${kind}" in tests-shell|tests-docker|tests-build|tests-all|build|validate) ;; *) echo 'Invalid publication mode.' >&2; return 1 ;; esac
  case "${status}" in ''|*[!0-9]*) echo 'Invalid publication exit status.' >&2; return 1 ;; esac
  [ "${status}" -le 255 ] || { echo 'Invalid publication exit status.' >&2; return 1; }
  temporary="$(mktemp "${public_dir}/.report.XXXXXX")" || return 1
  publication_temporary="${temporary}"
  trap 'rm -f "${publication_temporary}" "${publication_temporary}.ready"' EXIT
  if [[ "${kind}" == tests-* ]]; then
    if [ -f "${evidence}/results.tsv" ]; then
      while IFS=$'\t' read -r label value rest; do
        public_case_label "${label}" && public_case_status "${value}" || continue
        if [ "${value}" != PASS ] && [ "${status}" = 0 ]; then status=1; fi
        printf '%s: %s\n' "${label}" "${value}" >> "${temporary}" || return 1
        rows=$((rows + 1))
      done < "${evidence}/results.tsv"
    fi
    [ "${rows}" -gt 0 ] || status=1
  fi
  file="${public_dir}/${kind}.txt"
  outcome=FAILED
  [ "${status}" != 0 ] || outcome=SUCCESS
  printf '%s\n' 'Sanitized publication report' "Mode: ${kind}" "Outcome: ${outcome}" \
    "CI exit status: ${status}" 'Detailed logs and firmware, when produced, are retained locally.' \
    > "${temporary}.ready" || return 1
  cat "${temporary}" >> "${temporary}.ready" || return 1
  mv -f "${temporary}.ready" "${file}" || return 1
  rm -f "${temporary}" || return 1
  trap - EXIT
}

if [ "${mode}" = publish ]; then
  publish_report "${2:-}" "${3:-}" "${4:-}"
  exit "$?"
fi

run_indexed_source() {
  local index="$1" source_file
  local args=()
  source_file="$(cat .build/ci-source-file)" || return 1
  [ -n "${source_file}" ] || return 1
  args=(--sources-file "${source_file}" --source-index "${index}" \
    --mode "${EXTERNAL_MODE:-build}" --jobs "${EXTERNAL_BUILD_JOBS:-1}")
  [ "${EXTERNAL_PRISTINE:-false}" != true ] || args+=(--pristine)
  bash "${repo_root}/scripts/auto-build-external.sh" "${args[@]}"
}

case "${mode}" in
  ci-tests|ci-tools|ci-lf|ci-syntax|ci-source|ci-source-index|ci-matrix|ci-check)
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
    mkdir -p .build
    ci_execution="$(mktemp -d .build/ci-execution.XXXXXX)"
    status=0
    case "${mode}" in
      ci-matrix)
        (
          source_file="$(cat .build/ci-source-file)" || exit 1
          [ -n "${source_file}" ] || exit 1
          bash "${repo_root}/scripts/auto-build-external.sh" --list-indices-json "${source_file}" \
            > "${ci_execution}/matrix.json" || exit "$?"
          matrix="$(cat "${ci_execution}/matrix.json")" || exit 1
          [ "${matrix}" != '{"include":[]}' ] || exit 1
          printf 'matrix=%s\n' "${matrix}" >> "${GITHUB_OUTPUT:?}"
          count="$(grep -o '"index":' "${ci_execution}/matrix.json" | wc -l | tr -d '[:space:]')"
          printf 'Resolved source count: %s\n' "${count}" >> "${GITHUB_STEP_SUMMARY:?}"
        ) > "${ci_execution}/command.log" 2>&1 || status=$? ;;
      ci-tests)
        case "${2:-}" in shell|docker|build|all) ;; *) echo 'Invalid test mode.' >&2; exit 2 ;; esac
        bash "${repo_root}/.github/scripts/test.sh" "$2" > "${ci_execution}/command.log" 2>&1 || status=$? ;;
      ci-tools)
        bash "${repo_root}/.github/scripts/check-runner-tools.sh" > "${ci_execution}/command.log" 2>&1 || status=$? ;;
      ci-lf)
        bash "${repo_root}/.github/scripts/check-lf.sh" > "${ci_execution}/command.log" 2>&1 || status=$? ;;
      ci-syntax)
        (
          for file in "${repo_root}/build.sh" "${repo_root}"/scripts/*.sh "${repo_root}"/.github/scripts/*.sh; do
            bash -n "${file}" || exit "$?"
          done
        ) > "${ci_execution}/command.log" 2>&1 || status=$? ;;
      ci-source|ci-source-index)
        shift
        printf '1\n' > .build/ci-source.status
        printf '%s\n' "${ci_execution}/command.log" > .build/ci-source.record
        if [ "${mode}" = ci-source-index ]; then
          GITHUB_STEP_SUMMARY= GITHUB_ACTIONS= run_indexed_source "${1:-}" \
            > "${ci_execution}/command.log" 2>&1 || status=$?
        else
          GITHUB_STEP_SUMMARY= GITHUB_ACTIONS= bash "${repo_root}/scripts/build-external-source.sh" "$@" \
            > "${ci_execution}/command.log" 2>&1 || status=$?
        fi
        printf '%s\n' "${status}" > .build/ci-source.status ;;
      ci-check)
        case "${2:-}" in build|validate) ;; *) echo 'Invalid output mode.' >&2; exit 2 ;; esac
        bash "${BASH_SOURCE[0]}" "$2" > "${ci_execution}/command.log" 2>&1 || status=$?
        source_status="$(cat .build/ci-source.status 2>/dev/null || true)"
        [ "${source_status}" = 0 ] || status=1
        publish_report "$2" "${status}" || status=1 ;;
    esac
    printf '%s\n' "${status}" > "${ci_execution}/exit.status"
    if [ "${status}" = 0 ]; then
      echo 'Verification command completed successfully.'
    else
      echo 'Verification command failed; detailed evidence is retained locally.' >&2
    fi
    exit "${status}"
    ;;
esac

is_valid_run_dir() {
  local candidate="${1%/}" parent base pid
  case "/${candidate}/" in
    */../*) return 1 ;;
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

# A summary has one value per field. A matching SUCCESS line must not hide a
# contradictory status or a second mode/count/fallback later in the file.
for field in Status Mode 'Built targets' 'Fallback binary'; do
  field_count="$(grep -c "^${field}:" "${build_summary}" || true)"
  if [ "${field_count}" -gt 1 ]; then
    echo "duplicate summary field: ${field}: ${build_summary}" >&2
    exit 1
  fi
done

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

  fallback="$(sed -n 's/^Fallback binary: //p' "${build_summary}" | tail -n 1)"
  fallback="${fallback:-bin}"
  case "${fallback}" in
    .*|-*|*[!A-Za-z0-9._-]*) echo "Invalid fallback firmware extension in summary" >&2; exit 1 ;;
  esac
  [ "${built_targets}" -gt 0 ] || { echo "Built targets must be positive" >&2; exit 1; }

  firmware_list="$(
    find "${run_dir}" -maxdepth 1 -type f \( -name '*.uf2' -o -name '*.hex' -o -name '*.bin' -o -name "*.${fallback}" \) ! -iname build.log ! -iname build-summary.txt -print |
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

  if [ "${firmware_count}" -gt "${built_targets}" ]; then
    echo "Firmware artifact count (${firmware_count}) exceeds built target count (${built_targets})." >&2
    exit 1
  fi

  echo "[output] built targets: ${built_targets}"
  echo "[output] firmware artifacts: ${firmware_count}"
  printf '%s\n' "${firmware_list}" | sed 's/^/[output] firmware artifact: /'
fi
