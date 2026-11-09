#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
run_dir="${2:-}"
PUBLIC_REPORT_KINDS=(tests-shell tests-docker tests-build tests-all build validate)

public_report_kind() {
  local candidate
  for candidate in "${PUBLIC_REPORT_KINDS[@]}"; do
    [ "$1" != "${candidate}" ] || return 0
  done
  return 1
}

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

public_source_line() {
  case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 6 ]
}

test_timing_report() {
  local suite="$1" file="$2" line metric status samples seconds whole fraction milliseconds expected_samples candidate found seen='|' rows=0
  local LC_ALL=C checked_bytes actual_bytes
  local expected=(source-before source-after probe-shell-spawn probe-git-version probe-file-write-read)
  local output=()
  TIMING_FAILURE_CODE=mode
  TIMING_FAILURE_METRIC=
  case "${suite}" in shell|docker|build|all) ;; *) return 1 ;; esac
  case "${suite}" in shell|all)
    expected+=(syntax lf whitespace lf-contract output-contract external-contract host-contract host-help container-help) ;;
  esac
  case "${suite}" in docker|build|all) expected+=(tools probe-docker-client) ;; esac
  case "${suite}" in docker|all) expected+=(docker-contract probe-docker-exec) ;; esac
  case "${suite}" in build|all) expected+=(firmware) ;; esac
  TIMING_FAILURE_CODE=file
  [ -f "${file}" ] && [ ! -L "${file}" ] || return 1
  # Read the complete file before publishing anything, including NUL/CR rejection.
  TIMING_FAILURE_CODE=bytes
  checked_bytes="$(od -An -v -t u1 < "${file}" | awk '
    {
      for (i=1; i<=NF; i++) {
        bytes++
        if ($i !~ /^[0-9]+$/ || $i == 0 || $i == 13 || $i > 255) invalid=1
      }
    }
    END {if (invalid || !bytes) exit 1; printf "%.0f\n", bytes}
  ')" || return 1
  case "${checked_bytes}" in ''|0|*[!0-9]*) return 1 ;; esac
  {
    TIMING_FAILURE_CODE=header
    IFS= read -r line || return 1
    [ "${line}" = $'metric\tstatus\tsamples\tseconds' ] || return 1
    actual_bytes=$(( ${#line} + 1 ))
    while IFS= read -r line; do
      actual_bytes=$(( actual_bytes + ${#line} + 1 ))
      TIMING_FAILURE_CODE=columns
      TIMING_FAILURE_METRIC=
      IFS=$'\t' read -r metric status samples seconds <<< "${line}"
      [ "${line}" = "${metric}"$'\t'"${status}"$'\t'"${samples}"$'\t'"${seconds}" ] || return 1
      found=0
      TIMING_FAILURE_CODE=metric
      for candidate in "${expected[@]}"; do [ "${metric}" != "${candidate}" ] || found=1; done
      [ "${found}" = 1 ] || return 1
      TIMING_FAILURE_METRIC="${metric}"
      TIMING_FAILURE_CODE=duplicate
      case "${seen}" in *"|${metric}|"*) return 1 ;; esac
      seen="${seen}${metric}|"
      TIMING_FAILURE_CODE=status
      case "${status}" in ''|*[!0-9]*) return 1 ;; esac
      case "${status}" in 0) ;; 0*) return 1 ;; esac
      [ "${#status}" -le 3 ] && [ "${status}" -le 255 ] || return 1
      expected_samples=1
      case "${metric}" in
        probe-shell-spawn|probe-git-version) expected_samples=20 ;;
        probe-file-write-read) expected_samples=100 ;;
        probe-docker-client|probe-docker-exec) expected_samples=5 ;;
      esac
      TIMING_FAILURE_CODE=samples
      [ "${samples}" = "${expected_samples}" ] || return 1
      TIMING_FAILURE_CODE=duration
      seconds="${seconds/,/.}"
      case "${seconds}" in -*) TIMING_FAILURE_CODE=negative-duration; return 1 ;; esac
      case "${seconds}" in ''|*[!0-9.]*|*.*.*) return 1 ;; esac
      whole="${seconds%.*}"; fraction="${seconds#*.}"
      TIMING_FAILURE_CODE=duration-format
      [ "${whole}.${fraction}" = "${seconds}" ] && [ -n "${whole}" ] || return 1
      TIMING_FAILURE_CODE=duration-range
      [ "${#whole}" -le 8 ] || return 1
      TIMING_FAILURE_CODE=duration-precision
      [ "${#fraction}" = 3 ] || return 1
      milliseconds=$((10#${whole} * 1000 + 10#${fraction}))
      output+=("Timing ${suite} ${metric}: samples=${samples} milliseconds=${milliseconds} status=${status}")
      rows=$((rows + 1))
    done
    TIMING_FAILURE_CODE=incomplete
    TIMING_FAILURE_METRIC=
    [ -z "${line}" ] && [ "${rows}" = "${#expected[@]}" ] || return 1
    TIMING_FAILURE_CODE=byte-count
    [ "${actual_bytes}" = "${checked_bytes}" ] || return 1
  } < "${file}"
  TIMING_FAILURE_CODE=output
  TIMING_FAILURE_METRIC=
  printf '%s\n' "${output[@]}" || return 1
  TIMING_FAILURE_CODE=
}

publish_report() {
  local kind="$1" status="${2:-}" evidence="${3:-}" public_dir=.build/public file temporary label value rest number rows=0 outcome
  local host_failed=0 receipt
  [ ! -L .build ] && [ ! -L "${public_dir}" ] || { echo 'Publication directory must not be a symlink.' >&2; return 1; }
  mkdir -p "${public_dir}" || return 1
  if [ "${kind}" = clear ]; then
    for file in "${PUBLIC_REPORT_KINDS[@]}"; do
      rm -f "${public_dir}/${file}.txt" || return 1
    done
    rm -f .build/ci-source.status .build/ci-source.record .build/ci-publication-invalid || return 1
    return 0
  fi
  if [ "${kind}" = verify ]; then
    if [ -e .build/ci-publication-invalid ] || [ -L .build/ci-publication-invalid ]; then
      echo 'Publication status was not finalized.' >&2
      return 1
    fi
    local reports=0 header modes outcomes codes notices locations line report_status report_outcome has_failure
    for label in "${PUBLIC_REPORT_KINDS[@]}"; do
      file="${public_dir}/${label}.txt"
      [ ! -L "${file}" ] || { echo 'Publication report must not be a symlink.' >&2; return 1; }
      [ ! -e "${file}" ] || [ -f "${file}" ] || return 1
      [ -f "${file}" ] || continue
      reports=$((reports + 1))
      header=0 modes=0 outcomes=0 codes=0 notices=0 locations=0 host_failed=0 has_failure=0 report_status= report_outcome=
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
          'Host contract failure line: '*)
            public_source_line "${line#Host contract failure line: }" || return 1
            locations=$((locations + 1)) ;;
          *)
            value="${line#*: }"; number="${line%%: *}"
            public_case_label "${number}" && public_case_status "${value}" || return 1
            case "${number}:${value}" in host-contract:FAIL*) host_failed=1 ;; esac
            [ "${value}" = PASS ] || has_failure=1 ;;
        esac
      done < "${file}"
      [ "${header}" = 1 ] && [ "${modes}" = 1 ] && [ "${outcomes}" = 1 ] && [ "${codes}" = 1 ] && [ "${notices}" = 1 ] || return 1
      [ "${locations}" -le 1 ] || return 1
      if [ "${locations}" = 1 ]; then
        case "${label}" in tests-shell|tests-all) ;; *) return 1 ;; esac
        [ "${host_failed}" = 1 ] || return 1
      fi
      if [ "${report_outcome}" = SUCCESS ]; then [ "${report_status}" = 0 ] && [ "${has_failure}" = 0 ] || return 1; fi
    done
    [ "${reports}" -gt 0 ] || { echo 'No publication reports were produced.' >&2; return 1; }
    return 0
  fi
  public_report_kind "${kind}" || { echo 'Invalid publication mode.' >&2; return 1; }
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
        case "${label}:${value}" in host-contract:FAIL*) host_failed=1 ;; esac
        printf '%s: %s\n' "${label}" "${value}" >> "${temporary}" || return 1
        rows=$((rows + 1))
      done < "${evidence}/results.tsv"
    fi
    [ "${rows}" -gt 0 ] || status=1
  fi
  case "${kind}" in
    tests-shell|tests-all)
      receipt="${evidence}/host-evidence/host-failure-line.txt"
      if [ "${host_failed}" = 1 ] && { [ -e "${receipt}" ] || [ -L "${receipt}" ]; }; then
        [ -f "${receipt}" ] && [ ! -L "${receipt}" ] || { echo 'Invalid host failure receipt.' >&2; return 1; }
        if ! IFS= read -r value < "${receipt}" || ! public_source_line "${value}" ||
            ! cmp -s "${receipt}" <(printf '%s\n' "${value}"); then
          echo 'Invalid host failure source line.' >&2
          return 1
        fi
        printf 'Host contract failure line: %s\n' "${value}" >> "${temporary}" || return 1
      fi ;;
  esac
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

archive_private_evidence() (
  set -euo pipefail
  umask 077
  local root="$1" parent base archive=""
  # Resolve the existing parent before creating anything; never archive into checkout.
  root="${root%/}"
  parent="$(cd "$(dirname "${root}")" && pwd -P)" || exit "$?"
  base="$(basename "${root}")"
  case "${base}" in ''|.|..) echo 'Invalid private evidence directory.' >&2; exit 1 ;; esac
  root="${parent}/${base}"
  case "${root}/" in "${repo_root}/"*) echo 'Private evidence must be outside checkout.' >&2; exit 1 ;; esac
  [ ! -L "${root}" ] || { echo 'Private evidence root must not be a symlink.' >&2; exit 1; }
  mkdir -p "${root}" || exit "$?"
  root="$(cd "${root}" && pwd -P)" || exit "$?"
  case "${root}/" in "${repo_root}/"*) echo 'Private evidence must be outside checkout.' >&2; exit 1 ;; esac
  archive="$(mktemp -d "${root}/execution-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")" || exit "$?"
  trap 'status=$?; if [ "$status" != 0 ]; then printf "FAILED\n" > "$archive/archive-status.txt"; fi; exit "$status"' EXIT
  # Explicitly propagate failures: Bash 3.2 can continue past a failed pipeline
  # in this subshell function when its EXIT trap is installed.
  printf 'INCOMPLETE\n' > "${archive}/archive-status.txt" || exit "$?"
  {
    printf 'Run: %s\nAttempt: %s\nJob: %s\n' "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-1}" "${GITHUB_JOB:-local}" || exit "$?"
    printf 'Source revision: ' || exit "$?"
    git rev-parse HEAD 2>/dev/null || printf 'unavailable\n' || exit "$?"
  } > "${archive}/context.txt" || exit "$?"
  printf '%s\n' "${archive}" > .build/ci-evidence.record || exit "$?"
  tar cf - .build | (cd "${archive}" && tar xf -) || exit "$?"
  printf 'COMPLETE\n' > "${archive}/archive-status.txt" || exit "$?"
)

if [ "${mode}" = ci-archive ]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
  cd "${repo_root}"
  [ ! -L .build ] || { echo 'Private evidence source must not be a symlink.' >&2; exit 1; }
  mkdir -p .build
  set +e
  archive_private_evidence "${2:-${repo_root}/../.zmk-build-evidence}" > .build/ci-archive.log 2>&1
  archive_status=$?
  set -e
  if [ "${archive_status}" = 0 ]; then
    echo 'Private evidence preserved outside checkout.'
  else
    echo 'Private evidence preservation failed; detailed diagnostics remain local.' >&2
  fi
  exit "${archive_status}"
fi

if [ "${mode}" = publish ]; then
  publish_report "${2:-}" "${3:-}" "${4:-}"
  exit "$?"
fi

if [ "${mode}" = timings ]; then
  test_timing_report "${2:-}" "${3:-}"
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
    cd "${repo_root}"
    mkdir -p .build
    ci_execution="$(mktemp -d .build/ci-execution.XXXXXX)"
    status=0
    case "${mode}" in
      ci-matrix)
        (
          source_file="$(cat .build/ci-source-file)" || exit 1
          [ -n "${source_file}" ] || exit 1
          bash "${repo_root}/scripts/auto-build-external.sh" --list-indices-json --sources-file "${source_file}" \
            > "${ci_execution}/matrix.json" || exit "$?"
          matrix="$(cat "${ci_execution}/matrix.json")" || exit 1
          [ "${matrix}" != '{"include":[]}' ] || exit 1
          printf 'matrix=%s\n' "${matrix}" >> "${GITHUB_OUTPUT:?}"
          count="$(grep -o '"index":' "${ci_execution}/matrix.json" | wc -l | tr -d '[:space:]')"
          printf 'Resolved source count: %s\n' "${count}" >> "${GITHUB_STEP_SUMMARY:?}"
        ) > "${ci_execution}/command.log" 2>&1 || status=$? ;;
      ci-tests)
        case "${2:-}" in shell|docker|build|all) ;; *) echo 'Invalid test mode.' >&2; exit 2 ;; esac
        if [ "${ZMK_TEST_PROFILE:-0}" = 1 ]; then
          profile_results="${ZMK_TEST_RESULTS:-${ci_execution}/tests}"
          ZMK_TEST_RESULTS="${profile_results}" bash "${repo_root}/.github/scripts/test.sh" "$2" \
            > "${ci_execution}/command.log" 2>&1 || status=$?
          if [ "${status}" = 0 ]; then
            if test_timing_report "$2" "${profile_results}/profile.tsv" \
                2> "${ci_execution}/timing-validation.log" > "${ci_execution}/timing-report.txt"; then
              cat "${ci_execution}/timing-report.txt" 2>> "${ci_execution}/timing-validation.log" || status=1
            else
              # Both fields are assigned only from constants/recognized metric names.
              printf 'Profile report validation failed (reason=%s metric=%s); detailed evidence remains private.\n' \
                "${TIMING_FAILURE_CODE}" "${TIMING_FAILURE_METRIC:-none}" >&2
              status=1
            fi
            if [ "${status}" != 0 ]; then
              # The test producer already published its outcome. Invalidate it
              # before replacing SUCCESS after a later profiling/publication error.
              if (set -C; : > .build/ci-publication-invalid) 2>> "${ci_execution}/timing-validation.log"; then
                if publish_report "tests-$2" "${status}" "${profile_results}" \
                    2>> "${ci_execution}/timing-validation.log"; then
                  rm -f .build/ci-publication-invalid || status=1
                else
                  echo 'Failed to finalize profiling failure status.' >&2
                  status=1
                fi
              else
                echo 'Failed to invalidate profiling publication status.' >&2
                status=1
              fi
            fi
          fi
        else
          bash "${repo_root}/.github/scripts/test.sh" "$2" > "${ci_execution}/command.log" 2>&1 || status=$?
        fi ;;
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
          # Capture direct-script notices privately; CI publishes only fixed reports.
          GITHUB_STEP_SUMMARY= GITHUB_ACTIONS= run_indexed_source "${1:-}" \
            > "${ci_execution}/command.log" 2>&1 || status=$?
        else
          GITHUB_STEP_SUMMARY= GITHUB_ACTIONS= bash "${repo_root}/scripts/build-external-source.sh" "$@" \
            > "${ci_execution}/command.log" 2>&1 || status=$?
        fi
        printf '%s\n' "${status}" > .build/ci-source.status ;;
      ci-check)
        case "${2:-}" in build|validate) ;; *) echo 'Invalid output mode.' >&2; exit 2 ;; esac
        bash "${repo_root}/.github/scripts/check-build-output.sh" "$2" > "${ci_execution}/command.log" 2>&1 || status=$?
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

SUMMARY_KEYS=(Status Reason Mode Target 'Docker image' 'Docker cache volume' Elapsed
  'Built targets' 'Run sequence' Pristine 'Build jobs' 'Compiler jobs' 'Fallback binary'
  'Extra snippets' 'Module inputs')
SUMMARY_COUNTS=()
SUMMARY_VALUES=()

read_summary_metadata() {
  local file="$1" fields item= record_count=0 index count
  local records=()
  SUMMARY_COUNTS=() SUMMARY_VALUES=()
  printf -v fields '%s|' "${SUMMARY_KEYS[@]}"
  # One header snapshot. NUL records preserve empty values and literal whitespace;
  # the separate producer status detects failures even after complete-looking output.
  while IFS= read -r -d '' item; do
    records+=("${item}")
    record_count=$((record_count + 1))
  done < <(
    metadata_status=0
    # Decimal bytes avoid awk implementations that truncate embedded NUL strings.
    LC_ALL=C od -An -v -t u1 < "${file}" |
    LC_ALL=C awk -v fields="${fields%|}" '
      function header_line(text, colon, key, position) {
        if (text == "Failure excerpt") {ended = 1; return}
        colon = index(text, ":")
        if (colon > 0) {
          key = substr(text, 1, colon - 1)
          if (key in positions) {
            position = positions[key]
            counts[position]++
            if (substr(text, 1, length(key) + 2) == key ": ")
              values[position] = substr(text, length(key) + 3)
          }
        }
      }
      BEGIN {
        n = split(fields, keys, "[|]")
        for (i = 1; i <= n; i++) positions[keys[i]] = i
      }
      {
        # Drain the byte producer even after the header boundary or invalid data.
        if (ended || invalid) next
        for (byte_index = 1; byte_index <= NF; byte_index++) {
          if (ended) break
          if ($byte_index !~ /^[0-9]+$/) {invalid = 1; break}
          byte_value = $byte_index + 0
          if (byte_value > 255 || byte_value == 0) {
            invalid = 1; break
          }
          if (byte_value == 10) {header_line(line); line = ""}
          else line = line sprintf("%c", byte_value)
        }
      }
      END {
        if (invalid) exit 2
        if (!ended && line != "") header_line(line)
        for (i = 1; i <= n; i++) printf "%d%c%s%c", counts[i] + 0, 0, values[i], 0
      }
    ' || metadata_status=$?
    printf '%s\0' "${metadata_status}"
  )
  if [ -n "${item}" ] || [ "${record_count}" != "$(( ${#SUMMARY_KEYS[@]} * 2 + 1 ))" ] ||
      [ "${records[record_count - 1]}" != 0 ]; then
    echo 'Failed to read summary metadata.' >&2
    return 1
  fi
  for ((index=0; index<${#SUMMARY_KEYS[@]}; index++)); do
    count="${records[index * 2]}"
    case "${count}" in ''|*[!0-9]*) echo 'Failed to read summary metadata.' >&2; return 1 ;; esac
    SUMMARY_COUNTS+=("${count}")
    SUMMARY_VALUES+=("${records[index * 2 + 1]}")
  done
}

summary_field() {
  local index
  for ((index=0; index<${#SUMMARY_KEYS[@]}; index++)); do
    if [ "$1" = "${SUMMARY_KEYS[index]}" ]; then
      SUMMARY_COUNT="${SUMMARY_COUNTS[index]}"
      SUMMARY_VALUE="${SUMMARY_VALUES[index]}"
      return 0
    fi
  done
  return 1
}

is_run_sequence() {
  case "$1" in 1|[2-9]|[1-9][0-9]*) ;; *) return 1 ;; esac
  case "$1" in *[!0-9]*) return 1 ;; esac
}

is_valid_run_dir() {
  local candidate="${1%/}" parent base suffix label sequence
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
    run-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;;
    *) return 1 ;;
  esac
  suffix="${base:23}"
  case "${suffix}" in
    '') return 0 ;;
    -*) suffix="${suffix#-}" ;;
    *) return 1 ;;
  esac
  case "${suffix}" in
    pid-[0-9]*)
      label="${suffix#pid-}"
      case "${label}" in *[!0-9]*) ;; *) return 0 ;; esac ;;
  esac
  label="${suffix%%.*}"
  if [ "${#label}" -gt 80 ]; then
    sequence="${label##*-}"
    [ "${sequence}" != 1 ] && is_run_sequence "${sequence}" || return 1
    label="${label%-*}"
  fi
  case "${label}" in ''|-*|*-|*[!a-z0-9_-]*) return 1 ;; esac
  [ "${#label}" -le 80 ] || return 1
  # Also accept the earlier dotted suffix convention when checking retained evidence.
  case "${suffix}" in *.*) ;; *) return 0 ;; esac
  suffix="${suffix#*.}"
  [ "${suffix}" != 1 ] && is_run_sequence "${suffix}"
}

require_valid_run_dir() {
  local candidate="$1" label="$2"
  if ! is_valid_run_dir "${candidate}"; then
    echo "${label} does not match .build/run-YYYY-MM-DD_HH-MM-SS-CONFIG[-N] (or a legacy run name): ${candidate:-<empty>}" >&2
    exit 1
  fi
}

read_run_order() {
  local directory="$1" summary="$2" base count sequence key label
  base="${directory##*/}"
  RUN_ORDER_KEY="${base%%.*}" RUN_ORDER_NUMBER=1
  case "${base}" in *.*) RUN_ORDER_NUMBER="${base##*.}" ;; esac
  # Excerpts can contain arbitrary build output, including lines resembling metadata.
  read_summary_metadata "${summary}" || return 1
  summary_field 'Run sequence' || return 1
  count="${SUMMARY_COUNT}"
  case "${count}" in
    0) return 0 ;;
    1) ;;
    *) echo 'duplicate summary field: Run sequence' >&2; return 1 ;;
  esac
  sequence="${SUMMARY_VALUE}"
  is_run_sequence "${sequence}" || { echo 'Invalid run sequence in summary.' >&2; return 1; }
  key="${base}"
  if [ "${sequence}" != 1 ]; then
    case "${base}" in
      *-"${sequence}") key="${base%"-${sequence}"}" ;;
      *) echo 'Run sequence does not match run directory.' >&2; return 1 ;;
    esac
  fi
  label="${key:24}"
  case "${label}" in ''|-*|*-|*[!a-z0-9_-]*) echo 'Invalid config label in run directory.' >&2; return 1 ;; esac
  [ "${#label}" -le 80 ] || { echo 'Config label is too long.' >&2; return 1; }
  RUN_ORDER_KEY="${key}" RUN_ORDER_NUMBER="${sequence}"
}

case "${mode}" in
  validate|build) ;;
  *)
    echo "usage: $0 validate|build [run-dir] [--expect expectations-file]" >&2
    exit 2
    ;;
esac

expected_file=""
if [ "$#" -gt 2 ]; then
  if [ "$#" != 4 ] || [ "$3" != --expect ] || [ -z "${run_dir}" ]; then
    echo 'Output expectations require an explicit run directory and --expect file.' >&2
    exit 2
  fi
  expected_file="$4"
  [ -f "${expected_file}" ] && [ -r "${expected_file}" ] || {
    echo 'Cannot read output expectations.' >&2; exit 1;
  }
fi

if [ -n "${run_dir}" ]; then
  require_valid_run_dir "${run_dir}" "run directory"
  build_summary="${run_dir%/}/build-summary.txt"
else
  if [ ! -d .build ]; then
    echo ".build directory was not created." >&2
    exit 1
  fi

  build_summary=""
  latest_key="" latest_number=0
  while IFS= read -r summary; do
    candidate_dir="${summary%/*}"
    require_valid_run_dir "${candidate_dir}" "build summary directory"
    read_run_order "${candidate_dir}" "${summary}"
    candidate_key="${RUN_ORDER_KEY}" candidate_number="${RUN_ORDER_NUMBER}"
    # Compare decimal strings without octal interpretation or machine integer overflow.
    if [[ "${candidate_key}" > "${latest_key}" ]] ||
        { [ "${candidate_key}" = "${latest_key}" ] && {
          [ "${#candidate_number}" -gt "${#latest_number}" ] ||
          { [ "${#candidate_number}" = "${#latest_number}" ] && [[ "${candidate_number}" > "${latest_number}" || "${candidate_number}" = "${latest_number}" ]]; };
        }; }; then
      build_summary="${summary}"
      latest_key="${candidate_key}" latest_number="${candidate_number}"
    fi
  done < <(find .build -mindepth 2 -maxdepth 2 -type f -name build-summary.txt -print | sort)
fi

if [ -z "${build_summary}" ] || [ ! -f "${build_summary}" ]; then
  echo "build-summary.txt was not produced." >&2
  exit 1
fi

run_dir="${build_summary%/*}"
read_run_order "${run_dir}" "${build_summary}"
build_log="${run_dir}/build.log"

if [ ! -f "${build_log}" ]; then
  echo "build.log was not produced beside ${build_summary}." >&2
  exit 1
fi

# A summary has one value per field. A matching SUCCESS line must not hide a
# contradictory status or a second mode/count/fallback later in the file.
# All fields are read before the failure excerpt; sequence has already been checked.
for field in "${SUMMARY_KEYS[@]}"; do
  summary_field "${field}"
  if [ "${SUMMARY_COUNT}" -gt 1 ]; then
    echo "duplicate summary field: ${field}: ${build_summary}" >&2
    exit 1
  fi
done

# Older summaries omit this field. New ones record an explicit decimal cap or
# auto, which leaves the selected image/build tool in control.
summary_field 'Compiler jobs'
compiler_jobs="${SUMMARY_VALUE}"
case "${compiler_jobs}" in
  '')
    if [ "${SUMMARY_COUNT}" != 0 ]; then
      echo 'invalid Compiler jobs in summary' >&2; exit 1
    fi ;;
  auto) ;;
  *[!0-9]*|0*) echo 'invalid Compiler jobs in summary' >&2; exit 1 ;;
esac

summary_field Status
if [ "${SUMMARY_VALUE}" != SUCCESS ]; then
  echo "build-summary.txt does not report success: ${build_summary}" >&2
  exit 1
fi

summary_field Mode
summary_mode="${SUMMARY_VALUE}"
if [ "${summary_mode}" != "${mode}" ]; then
  echo "build-summary.txt mode is ${summary_mode:-<missing>}, expected ${mode}: ${build_summary}" >&2
  exit 1
fi

echo "[output] build log: ${build_log}"
echo "[output] build summary: ${build_summary}"

if [ "${mode}" = "build" ]; then
  summary_field 'Built targets'
  built_targets="${SUMMARY_VALUE}"
  case "${built_targets}" in ''|*[!0-9]*) built_targets= ;; esac
  if [ -z "${built_targets}" ]; then
    echo "build-summary.txt does not include Built targets for build mode: ${build_summary}" >&2
    exit 1
  fi

  summary_field 'Fallback binary'
  fallback="${SUMMARY_VALUE}"
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

  firmware_count=0
  while IFS= read -r firmware_file; do
    [ -z "${firmware_file}" ] || firmware_count=$((firmware_count + 1))
  done <<< "${firmware_list}"
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
  while IFS= read -r firmware_file; do
    printf '[output] firmware artifact: %s\n' "${firmware_file}"
  done <<< "${firmware_list}"
fi

check_expected_output() {
  local key value field actual count name previous file matched
  local expected_image=0 expected_target=0 expected_cache=0 expected_jobs=0 expected_compiler_jobs=0
  local artifacts=()
  # NUL-delimited key/value pairs preserve paths and literal shell characters.
  # The caller supplies the oracle before the run; do not learn it from outputs.
  while IFS= read -r -d '' key || [ -n "${key}" ]; do
    if ! IFS= read -r -d '' value; then
      echo 'Invalid output expectations: incomplete key/value pair.' >&2; return 1
    fi
    case "${key}" in
      image)
        [ "${expected_image}" = 0 ] || { echo 'Invalid output expectations: duplicate image.' >&2; return 1; }
        expected_image=1; field='Docker image' ;;
      target)
        [ "${expected_target}" = 0 ] || { echo 'Invalid output expectations: duplicate target.' >&2; return 1; }
        expected_target=1; field=Target ;;
      cache)
        [ "${expected_cache}" = 0 ] || { echo 'Invalid output expectations: duplicate cache.' >&2; return 1; }
        expected_cache=1; field='Docker cache volume' ;;
      jobs)
        [ "${expected_jobs}" = 0 ] || { echo 'Invalid output expectations: duplicate jobs.' >&2; return 1; }
        expected_jobs=1; field='Build jobs' ;;
      compiler-jobs)
        [ "${expected_compiler_jobs}" = 0 ] || { echo 'Invalid output expectations: duplicate compiler-jobs.' >&2; return 1; }
        expected_compiler_jobs=1; field='Compiler jobs' ;;
      artifact)
        case "${value}" in
          ''|.|..|*/*|*\\*|build.log|build-summary.txt)
            echo 'Invalid output expectations: artifact must be a firmware basename.' >&2; return 1 ;;
        esac
        for previous in ${artifacts[@]+"${artifacts[@]}"}; do
          [ "${previous}" != "${value}" ] || { echo 'Invalid output expectations: duplicate artifact.' >&2; return 1; }
        done
        artifacts+=("${value}")
        continue ;;
      *) echo 'Invalid output expectations: unknown key.' >&2; return 1 ;;
    esac
    [ -n "${value}" ] || { echo 'Invalid output expectations: empty value.' >&2; return 1; }
    summary_field "${field}" || return 1
    count="${SUMMARY_COUNT}"
    [ "${count}" = 1 ] || { echo "missing or duplicate expected summary field: ${field}" >&2; return 1; }
    actual="${SUMMARY_VALUE}"
    [ "${actual}" = "${value}" ] || { echo "expected ${field} does not match summary" >&2; return 1; }
  done < "${expected_file}"
  [ "${expected_image}" = 1 ] || { echo 'Invalid output expectations: image is required.' >&2; return 1; }
  if [ "${mode}" = validate ]; then
    [ "${#artifacts[@]}" = 0 ] || { echo 'Invalid output expectations: validate has no firmware.' >&2; return 1; }
    return 0
  fi
  [ "${#artifacts[@]}" -gt 0 ] || { echo 'Invalid output expectations: build artifacts are required.' >&2; return 1; }
  [ "${#artifacts[@]}" = "${built_targets}" ] || { echo 'expected artifact count does not match built target count' >&2; return 1; }
  while IFS= read -r file || [ -n "${file}" ]; do
    name="${file##*/}"; matched=0
    for value in "${artifacts[@]}"; do [ "${name}" != "${value}" ] || matched=1; done
    [ "${matched}" = 1 ] || { echo 'unexpected firmware name for output expectations' >&2; return 1; }
    [ -s "${file}" ] || { echo 'empty expected firmware' >&2; return 1; }
  done <<< "${firmware_list}"
}

[ -z "${expected_file}" ] || check_expected_output
