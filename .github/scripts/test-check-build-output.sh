#!/usr/bin/env bash
set -euo pipefail
# Synthetic coordinator fixtures choose their cache policy explicitly.
export ZMK_TEST_CACHE_PREFIX=

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
checker="${repo_root}/.github/scripts/check-build-output.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zmk-output-check.XXXXXX")"
tmp_dir="$(cd "${tmp_dir}" && pwd -P)"
case_root="${tmp_dir}/case"
run_name="run-2026-05-23_00-00-00-ci-zmk-config"
run_path="${case_root}/.build/${run_name}"

cleanup() {
  for file in "${tmp_dir}"/'scheduler fixture'/trace-*/descendant.pid; do
    [ -f "${file}" ] || continue
    : > "${file%/*}/descendant.release"
  done
  if [ -n "${scheduler_pid:-}" ]; then
    kill -TERM -- "-${scheduler_pid}" 2>/dev/null || true
    wait "${scheduler_pid}" 2>/dev/null || true
  fi
  for file in "${tmp_dir}"/'scheduler fixture'/trace-*/descendant.pid; do
    [ -f "${file}" ] || continue
    IFS= read -r child < "${file}" || continue
    while kill -0 "${child}" 2>/dev/null; do sleep 1; done
  done
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

reset_case() {
  rm -rf "${case_root}"
  mkdir -p "${run_path}"
  printf 'synthetic build log\n' > "${run_path}/build.log"
}

write_summary() {
  cat > "${run_path}/build-summary.txt"
}

run_ok() {
  local mode="$1" run_arg="${2:-}" expected_file="${3:-}"
  if [ -n "${expected_file}" ]; then
    (cd "${case_root}" && bash "${checker}" "${mode}" "${run_arg}" --expect "${expected_file}" >/dev/null)
    return
  fi
  if [ -n "${run_arg}" ]; then
    (cd "${case_root}" && bash "${checker}" "${mode}" "${run_arg}" >/dev/null)
  else
    (cd "${case_root}" && bash "${checker}" "${mode}" >/dev/null)
  fi
}

run_fail() {
  local mode="$1" expected="$2" run_arg="${3:-}" expected_file="${4:-}"
  if [ -n "${run_arg}" ]; then
    check_cmd=(bash "${checker}" "${mode}" "${run_arg}")
  else
    check_cmd=(bash "${checker}" "${mode}")
  fi
  [ -z "${expected_file}" ] || check_cmd+=(--expect "${expected_file}")
  if (cd "${case_root}" && "${check_cmd[@]}" >"${tmp_dir}/stdout" 2>"${tmp_dir}/stderr"); then
    echo "check-build-output.sh ${mode} unexpectedly succeeded" >&2
    exit 1
  fi
  grep -q "${expected}" "${tmp_dir}/stderr"
}

rm -rf "${case_root}"
mkdir -p "${case_root}"
run_fail validate ".build directory was not created"

rm -rf "${case_root}"
mkdir -p "${run_path}"
run_fail validate "build-summary.txt was not produced"

reset_case
write_summary <<'EOF'
ZMK Build Summary
=================

Status: SUCCESS
Mode: validate
EOF
run_ok validate

# Partial enumeration is unavailable evidence, never an older successful run.
# Drain each real producer before injecting its final failure, independently of
# metadata parsing; an explicit run must remain usable without discovery.
discovery_bin="${tmp_dir}/discovery-bin"
mkdir "${discovery_bin}"
for discovery_command in find sort; do
  discovery_real="$(command -v "${discovery_command}")"
  cat > "${discovery_bin}/${discovery_command}" <<'EOF'
#!/usr/bin/env bash
"${DISCOVERY_REAL}" "$@" || exit "$?"
exit 23
EOF
  chmod +x "${discovery_bin}/${discovery_command}"
  PATH="${discovery_bin}:${PATH}" DISCOVERY_REAL="${discovery_real}" \
    run_fail validate 'Failed to enumerate build summaries'
  PATH="${discovery_bin}:${PATH}" DISCOVERY_REAL="${discovery_real}" \
    run_ok validate "${run_path}"
  rm "${discovery_bin}/${discovery_command}"
done

# The config label follows the timestamp; collision suffixes use hyphens.
for suffix in -2 -10; do
  renamed="${run_path}${suffix}"
  mv "${run_path}" "${renamed}"
  run_ok validate "${renamed}"
  mv "${renamed}" "${run_path}"
done
for suffix in .0 .00 .1 .01 .2x . .2.3; do
  run_fail validate 'run directory' "${run_path}${suffix}"
done
for historical_name in run-2026-05-23_00-00-00 run-2026-05-23_00-00-00-2 run-2026-05-23_00-00-00-pid-1 run-2026-05-23_00-00-00-ci-zmk-config.2; do
  historical_path="${case_root}/.build/${historical_name}"
  mv "${run_path}" "${historical_path}"
  run_ok validate "${historical_path}"
  mv "${historical_path}" "${run_path}"
done

reset_case
write_summary <<'EOF'
ZMK Build Summary
=================

Status: FAILED
Mode: validate
EOF
run_fail validate "does not report success"

reset_case
write_summary <<'EOF'
ZMK Build Summary
=================

Status: FAILED
Mode: build
Built targets: 1
EOF
touch "${run_path}/partial.uf2"
run_fail build "does not report success"

reset_case
rm -f "${run_path}/build.log"
write_summary <<'EOF'
ZMK Build Summary
=================

Status: SUCCESS
Mode: validate
EOF
run_fail validate "build.log was not produced"

reset_case
write_summary <<'EOF'
ZMK Build Summary
=================

Status: SUCCESS
Mode: build
Built targets: 2
EOF
touch "${run_path}/left.uf2" "${run_path}/right.hex"
run_ok build

# Every run is self-contained; other runs and nested outputs do not change its count.
for name in left.uf2 right.hex; do
  printf 'synthetic firmware\n' > "${run_path}/${name}"
done
mkdir -p "${run_path}/nested" "${case_root}/.build/unrelated-output/${run_name}"
printf 'unrelated nested firmware\n' > "${run_path}/nested/extra.bin"
printf 'unrelated firmware\n' > "${case_root}/.build/unrelated-output/${run_name}/extra.bin"
printf '%s\0' image synthetic/build artifact left.uf2 artifact right.hex > "${tmp_dir}/layout.expect"
printf 'Docker image: synthetic/build\n' >> "${run_path}/build-summary.txt"
run_ok build "${run_path}" "${tmp_dir}/layout.expect"
legacy_run="${case_root}/.build/run-2026-05-23_00-00-00-pid-1"
mv "${run_path}" "${legacy_run}"
run_ok build "${legacy_run}" "${tmp_dir}/layout.expect"
mv "${legacy_run}" "${run_path}"

# The summary disambiguates a collision from a numeric repository-name suffix.
reset_case
write_summary <<'EOF'
Status: FAILED
Mode: validate
Run sequence: 1
EOF
for sequence in 9 10; do
  mkdir -p "${run_path}-${sequence}"
  printf 'synthetic log\n' > "${run_path}-${sequence}/build.log"
  printf 'Status: FAILED\nMode: validate\nRun sequence: %s\n' "${sequence}" > "${run_path}-${sequence}/build-summary.txt"
done
printf 'Status: SUCCESS\nMode: validate\nRun sequence: 10\n' > "${run_path}-10/build-summary.txt"
run_ok validate

# A numeric repository suffix belongs to its label, never to the collision number.
reset_case
write_summary <<'EOF'
Status: FAILED
Mode: validate
Run sequence: 1
EOF
numeric_path="${case_root}/.build/run-2026-05-23_00-00-00-numeric-10"
mv "${run_path}" "${numeric_path}"
mkdir -p "${numeric_path}-2"
printf 'synthetic log\n' > "${numeric_path}-2/build.log"
printf 'Status: SUCCESS\nMode: validate\nRun sequence: 2\n' > "${numeric_path}-2/build-summary.txt"
run_ok validate

# New sequence metadata is optional for legacy evidence, but must be valid and match when present.
reset_case
for sequence in '' 0 00 01 -1 bad; do
  printf 'Status: SUCCESS\nMode: validate\nRun sequence: %s\n' "${sequence}" > "${run_path}/build-summary.txt"
  run_fail validate 'Invalid run sequence' "${run_path}"
done
printf 'Status: SUCCESS\nMode: validate\nRun sequence: 2\n' > "${run_path}/build-summary.txt"
run_fail validate 'Run sequence does not match' "${run_path}"
printf 'Status: SUCCESS\nMode: validate\nRun sequence: 1\nRun sequence: 2\n' > "${run_path}/build-summary.txt"
run_fail validate 'duplicate summary field: Run sequence' "${run_path}"

# Failed log excerpts are raw evidence, not sequence metadata for later run selection.
for metadata in current legacy; do
  reset_case
  case "${metadata}" in current) sequence_line='Run sequence: 1' ;; legacy) sequence_line='' ;; esac
  write_summary <<EOF
Status: FAILED
Mode: validate
${sequence_line}

Files
-----
- build.log

Failure excerpt
---------------
Run sequence: 7
EOF
  later_run="${case_root}/.build/run-2026-05-24_00-00-00-ci-zmk-config"
  mkdir -p "${later_run}"
  printf 'synthetic later log\n' > "${later_run}/build.log"
  printf 'Status: SUCCESS\nMode: validate\nRun sequence: 1\n' > "${later_run}/build-summary.txt"
  run_ok validate
  run_fail validate 'does not report success' "${run_path}"
done

reset_case
write_summary <<'EOF'
ZMK Build Summary
=================

Status: SUCCESS
Mode: build
Built targets: 1
EOF
touch "${run_path}/selected.uf2"
stale_run="${case_root}/.build/run-2026-05-22_00-00-00-pid-1"
mkdir -p "${stale_run}"
printf 'synthetic stale log\n' > "${stale_run}/build.log"
cat > "${stale_run}/build-summary.txt" <<'EOF'
ZMK Build Summary
=================

Status: SUCCESS
Mode: validate
EOF
run_ok build
run_ok build "${run_path}"

mkdir -p "${case_root}/.build/not-a-run"
printf 'synthetic bad log\n' > "${case_root}/.build/not-a-run/build.log"
cat > "${case_root}/.build/not-a-run/build-summary.txt" <<'EOF'
ZMK Build Summary
=================

Status: SUCCESS
Mode: build
Built targets: 1
EOF
run_fail build "build summary directory"
run_fail build "run directory" "${case_root}/.build/not-a-run"

reset_case
write_summary <<'EOF'
ZMK Build Summary
=================

Status: SUCCESS
Mode: build
Built targets: 1
EOF
run_fail build "No firmware artifact"

reset_case
write_summary <<'EOF'
ZMK Build Summary
=================

Status: SUCCESS
Mode: validate
Built targets: 1
EOF
touch "${run_path}/only.uf2"
run_fail build "expected build"

reset_case
write_summary <<'EOF'
ZMK Build Summary
=================

Status: SUCCESS
Mode: build
EOF
touch "${run_path}/only.uf2"
run_fail build "does not include Built targets"

reset_case
write_summary <<'EOF'
ZMK Build Summary
=================

Status: SUCCESS
Mode: build
Built targets: 2
EOF
touch "${run_path}/only.uf2"
run_fail build "lower than built target count"

# Exactly one selected artifact per target, including an explicitly recorded custom extension.
# Large successful counts do not require hundreds of Docker copy subprocesses.
reset_case
write_summary <<'EOF'
Status: SUCCESS
Mode: build
Built targets: 512
EOF
for ((number=1; number<=512; number++)); do
  printf 'synthetic firmware\n' > "${run_path}/bulk-${number}.bin"
done
run_ok build "${run_path}"

reset_case
write_summary <<'EOF'
Status: SUCCESS
Mode: build
Built targets: 1
Fallback binary: img
EOF
touch "${run_path}/selected.img"
run_ok build
touch "${run_path}/unexpected.uf2"
run_fail build "exceeds built target count"

reset_case
write_summary <<'EOF'
Status: SUCCESS
Mode: build
Built targets: 0
EOF
touch "${run_path}/unexpected.bin"
run_fail build "Built targets must be positive"

reset_case
write_summary <<'EOF'
Status: SUCCESS
Mode: build
Built targets: 1
Fallback binary: ../escape
EOF
touch "${run_path}/unexpected.bin"
run_fail build "Invalid fallback firmware extension"

# Logs and summaries are never firmware, even when their suffix is selected as fallback.
for extension in log txt; do
  reset_case
  write_summary <<EOF
Status: SUCCESS
Mode: build
Built targets: 1
Fallback binary: ${extension}
EOF
  touch "${run_path}/selected.${extension}"
  run_ok build
done

# Required metadata cannot be supplied by raw output in the failure excerpt.
echo '[output-contract] metadata header boundary'
reset_case
write_summary <<'EOF'
Mode: validate
Run sequence: 1

Files
-----
- build.log

Failure excerpt
---------------
Status: SUCCESS
EOF
run_fail validate 'does not report success' "${run_path}"

reset_case
write_summary <<'EOF'
Status: SUCCESS

Failure excerpt
---------------
Mode: validate
EOF
run_fail validate 'mode is <missing>' "${run_path}"

reset_case
write_summary <<'EOF'
Status: SUCCESS
Mode: build

Failure excerpt
---------------
Built targets: 1
EOF
printf 'synthetic firmware\n' > "${run_path}/selected.bin"
run_fail build 'does not include Built targets' "${run_path}"

# Expected image/input/cache values must also appear in metadata, even when raw output matches.
for missing in image target cache; do
  reset_case
  case "${missing}" in
    image) field='Docker image'; field_value=synthetic/build:stable ;;
    target) field=Target; field_value=/synthetic/config ;;
    cache) field='Docker cache volume'; field_value=synthetic-cache ;;
  esac
  {
    printf 'Status: SUCCESS\nMode: build\nBuilt targets: 1\n'
    [ "${missing}" = image ] || printf 'Docker image: synthetic/build:stable\n'
    [ "${missing}" = target ] || printf 'Target: /synthetic/config\n'
    [ "${missing}" = cache ] || printf 'Docker cache volume: synthetic-cache\n'
    printf '\nFailure excerpt\n---------------\n'
    printf '%s: %s\n' "${field}" "${field_value}"
  } > "${run_path}/build-summary.txt"
  printf 'synthetic firmware\n' > "${run_path}/selected.bin"
  printf '%s\0' image synthetic/build:stable target /synthetic/config cache synthetic-cache \
    artifact selected.bin > "${tmp_dir}/header.expect"
  run_fail build "missing or duplicate expected summary field: ${field}" "${run_path}" "${tmp_dir}/header.expect"
done

# Real header fields are unaffected by misleading excerpt lines.
reset_case
write_summary <<'EOF'
Status: SUCCESS
Mode: build
Built targets: 1
Fallback binary: img

Failure excerpt
---------------
Status: FAILED
Mode: validate
Built targets: 99
Fallback binary: other
EOF
printf 'synthetic firmware\n' > "${run_path}/selected.img"
run_ok build "${run_path}"

# Reading a large metadata section must drain its producers instead of failing through SIGPIPE.
reset_case
write_summary <<'EOF'
Status: SUCCESS
Mode: validate
Module inputs:
EOF
awk 'BEGIN { for (i=0; i<20000; i++) print "  - synthetic/module-with-a-long-and-clearly-synthetic-name-" i }' \
  >> "${run_path}/build-summary.txt"
run_ok validate "${run_path}"

# Reject contradictory/duplicate summary fields instead of accepting one matching line.
printf 'Status: SU\0CCESS\nMode: validate\n' > "${run_path}/build-summary.txt"
run_fail validate 'Failed to read summary metadata' "${run_path}"
printf 'Status: SUCCESS\nMode: validate\nFailure excerpt\nraw\0output\n' > "${run_path}/build-summary.txt"
run_ok validate "${run_path}"

for field in Status Reason Mode Target 'Docker image' 'Docker cache volume' Elapsed \
    'Built targets' Pristine 'Build jobs' 'Compiler jobs' 'Fallback binary' 'Extra snippets' 'Module inputs'; do
  reset_case
  write_summary <<'EOF'
Status: SUCCESS
Mode: build
Built targets: 1
Fallback binary: bin
EOF
  touch "${run_path}/selected.bin"
  case "${field}" in
    Status|Mode|'Built targets'|'Fallback binary') ;;
    *) printf '%s: original\n' "${field}" >> "${run_path}/build-summary.txt" ;;
  esac
  printf '%s: conflicting\n' "${field}" >> "${run_path}/build-summary.txt"
  run_fail build "duplicate summary field: ${field}"
done

# Old summaries without compiler metadata remain valid; explicit values are strict.
for compiler in auto 2 10 '' 0 00 02 -1 1.5 ' 2' bad; do
  reset_case
  printf 'Status: SUCCESS\nMode: validate\nCompiler jobs: %s\n' "${compiler}" > "${run_path}/build-summary.txt"
  case "${compiler}" in
    auto|2|10) run_ok validate "${run_path}" ;;
    *) run_fail validate 'invalid Compiler jobs' "${run_path}" ;;
  esac
done

# Caller-owned expectations catch wrong outputs even when their count is unchanged.
# Keep these values independent of the summary and of the production target parser.
reset_case
expected_file="${tmp_dir}/expected output"
printf '%s\0' image synthetic/build:stable target /synthetic/config cache synthetic-cache \
  artifact left.uf2 artifact right.bin > "${expected_file}"
strict_summary() {
  write_summary <<EOF
Status: SUCCESS
Mode: build
Built targets: 2
Docker image: ${1:-synthetic/build:stable}
Target: ${2:-/synthetic/config}
Docker cache volume: ${3:-synthetic-cache}
EOF
}
strict_summary
printf 'synthetic firmware\n' > "${run_path}/left.uf2"
printf 'synthetic firmware\n' > "${run_path}/right.bin"
run_ok build "${run_path}" "${expected_file}"
# A complete explicit-run check, including expectations, needs at most one metadata parse.
echo '[output-contract] metadata read budget'
metadata_bin="${tmp_dir}/metadata-bin"
mkdir "${metadata_bin}"
cat > "${metadata_bin}/awk" <<'EOF'
#!/usr/bin/env bash
printf 'read\n' >> "${SUMMARY_READ_CALLS}"
[ "${SUMMARY_AWK_EMPTY:-0}" != 1 ] || exit 0
"${SUMMARY_REAL_AWK}" "$@" || exit "$?"
exit "${SUMMARY_AWK_EXIT:-0}"
EOF
chmod +x "${metadata_bin}/awk"
metadata_real_awk="$(command -v awk)"
metadata_real_od="$(command -v od)"
cat > "${metadata_bin}/od" <<'EOF'
#!/usr/bin/env bash
"${SUMMARY_REAL_OD}" "$@" || exit "$?"
exit "${SUMMARY_OD_EXIT:-0}"
EOF
chmod +x "${metadata_bin}/od"
: > "${tmp_dir}/metadata-reads"
PATH="${metadata_bin}:${PATH}" SUMMARY_REAL_AWK="${metadata_real_awk}" SUMMARY_REAL_OD="${metadata_real_od}" \
  SUMMARY_READ_CALLS="${tmp_dir}/metadata-reads" \
  run_ok build "${run_path}" "${expected_file}"
metadata_reads=0
while IFS= read -r metadata_read; do metadata_reads=$((metadata_reads + 1)); done < "${tmp_dir}/metadata-reads"
if [ "${metadata_reads}" -gt 1 ]; then
  echo 'summary metadata was parsed repeatedly' >&2; exit 1
fi
echo "[output-contract] metadata parses: ${metadata_reads}"
# Complete output from a failing producer and successful-but-empty output are both errors.
for metadata_failure in exit empty; do
  metadata_exit=0 metadata_empty=0
  if [ "${metadata_failure}" = exit ]; then metadata_exit=23; else metadata_empty=1; fi
  PATH="${metadata_bin}:${PATH}" SUMMARY_REAL_AWK="${metadata_real_awk}" SUMMARY_REAL_OD="${metadata_real_od}" \
    SUMMARY_READ_CALLS="${tmp_dir}/metadata-reads" \
    SUMMARY_AWK_EXIT="${metadata_exit}" SUMMARY_AWK_EMPTY="${metadata_empty}" \
    run_fail build 'Failed to read summary metadata' "${run_path}" "${expected_file}"
done
PATH="${metadata_bin}:${PATH}" SUMMARY_REAL_AWK="${metadata_real_awk}" SUMMARY_REAL_OD="${metadata_real_od}" \
  SUMMARY_READ_CALLS="${tmp_dir}/metadata-reads" SUMMARY_OD_EXIT=23 \
  run_fail build 'Failed to read summary metadata' "${run_path}" "${expected_file}"
literal_target=$'/synthetic/path with spaces\tback\\slash $value; [x] '
literal_cache='synthetic cache with spaces '
strict_summary synthetic/build:stable "${literal_target}" "${literal_cache}"
printf '%s\0' image synthetic/build:stable target "${literal_target}" cache "${literal_cache}" \
  artifact left.uf2 artifact right.bin > "${tmp_dir}/literal.expect"
run_ok build "${run_path}" "${tmp_dir}/literal.expect"
strict_summary synthetic/build:wrong
run_fail build 'expected Docker image' "${run_path}" "${expected_file}"
strict_summary
mv "${run_path}/left.uf2" "${run_path}/wrong-target.uf2"
run_fail build 'unexpected firmware name' "${run_path}" "${expected_file}"
mv "${run_path}/wrong-target.uf2" "${run_path}/left.uf2"
strict_summary synthetic/build:stable /synthetic/wrong
run_fail build 'expected Target' "${run_path}" "${expected_file}"
strict_summary synthetic/build:stable /synthetic/config wrong-cache
run_fail build 'expected Docker cache volume' "${run_path}" "${expected_file}"
strict_summary
printf 'Docker image: synthetic/build:stable\n' >> "${run_path}/build-summary.txt"
run_fail build 'duplicate summary field: Docker image' "${run_path}" "${expected_file}"
strict_summary
: > "${run_path}/left.uf2"
run_fail build 'empty expected firmware' "${run_path}" "${expected_file}"
printf 'synthetic firmware\n' > "${run_path}/left.uf2"

strict_summary
printf 'Build jobs: 2\nCompiler jobs: 2\n' >> "${run_path}/build-summary.txt"
cp "${expected_file}" "${tmp_dir}/parallel.expect"
printf '%s\0' jobs 2 compiler-jobs 2 >> "${tmp_dir}/parallel.expect"
run_ok build "${run_path}" "${tmp_dir}/parallel.expect"
for key in jobs compiler-jobs; do
  printf '%s\0' image synthetic/build:stable artifact left.uf2 artifact right.bin "${key}" 3 > "${tmp_dir}/jobs.expect"
  run_fail build 'does not match summary' "${run_path}" "${tmp_dir}/jobs.expect"
  printf '%s\0' image synthetic/build:stable artifact left.uf2 artifact right.bin "${key}" 2 "${key}" 2 > "${tmp_dir}/jobs.expect"
  run_fail build "Invalid output expectations: duplicate ${key}" "${run_path}" "${tmp_dir}/jobs.expect"
done

for invalid in duplicate-image duplicate-artifact unknown-key truncated-value truncated-key no-image no-artifact path-artifact reserved-artifact; do
  case "${invalid}" in
    duplicate-image) printf '%s\0' image synthetic/build:stable image synthetic/build:stable artifact left.uf2 ;;
    duplicate-artifact) printf '%s\0' image synthetic/build:stable artifact left.uf2 artifact left.uf2 ;;
    unknown-key) printf '%s\0' image synthetic/build:stable unknown value ;;
    truncated-value) printf 'image\0synthetic/build:stable' ;;
    truncated-key) printf 'image' ;;
    no-image) printf '%s\0' artifact left.uf2 ;;
    no-artifact) printf '%s\0' image synthetic/build:stable ;;
    path-artifact) printf '%s\0' image synthetic/build:stable artifact ../left.uf2 ;;
    reserved-artifact) printf '%s\0' image synthetic/build:stable artifact build.log ;;
  esac > "${tmp_dir}/invalid expectation"
  run_fail build 'Invalid output expectations' "${run_path}" "${tmp_dir}/invalid expectation"
done
printf '%s\0' image synthetic/build:stable artifact left.uf2 > "${tmp_dir}/too-few.expect"
run_fail build 'expected artifact count' "${run_path}" "${tmp_dir}/too-few.expect"
run_fail build 'Cannot read output expectations' "${run_path}" "${tmp_dir}/missing.expect"

# Metadata-only checks can use the same contract without expecting firmware.
write_summary <<'EOF'
Status: SUCCESS
Mode: validate
Docker image: synthetic/build:stable
Target: /synthetic/config
Docker cache volume: synthetic-cache
EOF
printf '%s\0' image synthetic/build:stable target /synthetic/config > "${tmp_dir}/validate.expect"
run_ok validate "${run_path}" "${tmp_dir}/validate.expect"
run_fail validate 'Invalid output expectations' "${run_path}" "${expected_file}"

# Dots inside a directory name are legal; only a complete parent-traversal component is rejected.
reset_case
write_summary <<'EOF'
Status: SUCCESS
Mode: validate
EOF
old_case_root="${case_root}"
case_root="${tmp_dir}/case..name"
mv "${old_case_root}" "${case_root}"
run_path="${case_root}/.build/${run_name}"
run_ok validate "${run_path}"
run_fail validate 'run directory' "${case_root}/../case..name/.build/${run_name}"

# Publication copies contain only fixed labels/statuses, never raw identities or binaries.
mkdir -p "${case_root}/raw evidence"
printf 'case\tstatus\tseconds\nsyntax\tPASS\t1\nfirmware\tFAIL(23)\t2\nsynthetic-private-host\tPASS\t3\n' \
  > "${case_root}/raw evidence/results.tsv"
printf 'synthetic-private-host /synthetic/private/path secret=value\n' \
  > "${case_root}/raw evidence/environment.txt"
(cd "${case_root}" && bash "${checker}" publish clear)
(cd "${case_root}" && bash "${checker}" publish tests-shell 23 'raw evidence')
public_report="${case_root}/.build/public/tests-shell.txt"
grep -qx 'Outcome: FAILED' "${public_report}"
grep -qx 'syntax: PASS' "${public_report}"
grep -qx 'firmware: FAIL(23)' "${public_report}"
if grep -Eq 'synthetic-private-host|/synthetic/private|secret=|seconds' "${public_report}"; then
  echo 'publication report disclosed raw evidence' >&2; exit 1
fi
for mode in build validate; do
  (cd "${case_root}" && bash "${checker}" publish "${mode}" 0)
  grep -qx 'Outcome: SUCCESS' "${case_root}/.build/public/${mode}.txt"
done
[ "$(find "${case_root}/.build/public" -type f | wc -l | tr -d '[:space:]')" = 3 ]
(cd "${case_root}" && bash "${checker}" publish verify)
printf 'synthetic-private-host\n' >> "${public_report}"
if (cd "${case_root}" && bash "${checker}" publish verify) >/dev/null 2>&1; then
  echo 'publication verification accepted an unreviewed field' >&2; exit 1
fi
(cd "${case_root}" && bash "${checker}" publish tests-shell 23 'raw evidence')
if find "${case_root}/.build/public" -type f | grep -Eq '\.(uf2|hex|bin)$'; then exit 1; fi
if (cd "${case_root}" && bash "${checker}" publish tests-shell invalid 'raw evidence') >/dev/null 2>&1; then
  echo 'publication accepted an invalid exit status' >&2; exit 1
fi
(cd "${case_root}" && bash "${checker}" publish clear)
[ "$(find "${case_root}/.build/public" -type f | wc -l | tr -d '[:space:]')" = 0 ]

# Timing publication has its own complete numeric-only contract; raw traces stay private.
echo '[output-contract] fixed timing aggregates'
timing_fixture="${tmp_dir}/timing.tsv"
cat > "${timing_fixture}" <<'EOF'
metric	status	samples	seconds
source-before	0	1	0.125
syntax	0	1	0.125
lf	0	1	0.125
whitespace	0	1	0.125
lf-contract	0	1	0.125
output-contract	0	1	0.125
external-contract	0	1	0.125
host-contract	0	1	0.125
host-help	0	1	0.125
container-help	0	1	0.125
probe-shell-spawn	0	20	0.125
probe-git-version	0	20	0.125
probe-file-write-read	0	100	0.125
source-after	0	1	0.125
EOF
bash "${checker}" timings shell "${timing_fixture}" > "${tmp_dir}/timing-public"
[ "$(wc -l < "${tmp_dir}/timing-public" | tr -d '[:space:]')" = 14 ]
grep -qx 'Timing shell probe-file-write-read: samples=100 milliseconds=125 status=0' "${tmp_dir}/timing-public"
sed 's/0\.125/0,000/g' "${timing_fixture}" > "${tmp_dir}/timing-comma.tsv"
bash "${checker}" timings shell "${tmp_dir}/timing-comma.tsv" > "${tmp_dir}/timing-public"
grep -qx 'Timing shell syntax: samples=1 milliseconds=0 status=0' "${tmp_dir}/timing-public"
cat > "${tmp_dir}/timing-docker.tsv" <<'EOF'
metric	status	samples	seconds
source-before	0	1	0.125
tools	0	1	0.125
probe-docker-exec	0	5	0.125
docker-contract	0	1	0.125
probe-shell-spawn	0	20	0.125
probe-git-version	0	20	0.125
probe-file-write-read	0	100	0.125
probe-docker-client	0	5	0.125
source-after	0	1	0.125
EOF
bash "${checker}" timings docker "${tmp_dir}/timing-docker.tsv" > "${tmp_dir}/timing-public"
[ "$(wc -l < "${tmp_dir}/timing-public" | tr -d '[:space:]')" = 9 ]
grep -qx 'Timing docker probe-docker-exec: samples=5 milliseconds=125 status=0' "${tmp_dir}/timing-public"
sed '/^probe-docker-exec/d; /^docker-contract/d' "${tmp_dir}/timing-docker.tsv" > "${tmp_dir}/timing-build.tsv"
printf 'firmware\t0\t1\t0.125\n' >> "${tmp_dir}/timing-build.tsv"
bash "${checker}" timings build "${tmp_dir}/timing-build.tsv" > "${tmp_dir}/timing-public"
[ "$(wc -l < "${tmp_dir}/timing-public" | tr -d '[:space:]')" = 8 ]
cp "${timing_fixture}" "${tmp_dir}/timing-all.tsv"
for metric in tools docker-contract firmware probe-docker-client probe-docker-exec; do
  samples=1
  case "${metric}" in probe-*) samples=5 ;; esac
  printf '%s\t0\t%s\t0.125\n' "${metric}" "${samples}" >> "${tmp_dir}/timing-all.tsv"
done
bash "${checker}" timings all "${tmp_dir}/timing-all.tsv" > "${tmp_dir}/timing-public"
[ "$(wc -l < "${tmp_dir}/timing-public" | tr -d '[:space:]')" = 19 ]
for invalid in private duplicate missing truncated nul cr negative samples status leading-zero; do
  cp "${timing_fixture}" "${tmp_dir}/timing-invalid.tsv"
  case "${invalid}" in
    private) printf 'synthetic-private-host /synthetic/private secret=value\n' >> "${tmp_dir}/timing-invalid.tsv" ;;
    duplicate) printf 'syntax\t0\t1\t0.125\n' >> "${tmp_dir}/timing-invalid.tsv" ;;
    missing) sed '/^source-after/d' "${timing_fixture}" > "${tmp_dir}/timing-invalid.tsv" ;;
    truncated) printf 'syntax\t0\t1\t0.125' >> "${tmp_dir}/timing-invalid.tsv" ;;
    nul) printf '\0' >> "${tmp_dir}/timing-invalid.tsv" ;;
    cr) printf '\r' >> "${tmp_dir}/timing-invalid.tsv" ;;
    negative) sed 's/0\.125/-0.125/g' "${timing_fixture}" > "${tmp_dir}/timing-invalid.tsv" ;;
    samples) sed $'s/\t100\t/\t99\t/' "${timing_fixture}" > "${tmp_dir}/timing-invalid.tsv" ;;
    status) sed $'s/\t0\t/\t256\t/' "${timing_fixture}" > "${tmp_dir}/timing-invalid.tsv" ;;
    leading-zero) sed $'s/\t0\t/\t00\t/' "${timing_fixture}" > "${tmp_dir}/timing-invalid.tsv" ;;
  esac
  if bash "${checker}" timings shell "${tmp_dir}/timing-invalid.tsv" > "${tmp_dir}/timing-public" 2>&1; then
    echo 'timing publication accepted invalid data' >&2; exit 1
  fi
  [ ! -s "${tmp_dir}/timing-public" ]
done
# Named unsafe control discloses the sentinel; the numeric renderer rejects it before output.
printf 'synthetic-private-host /synthetic/private secret=value\n' >> "${tmp_dir}/timing-invalid.tsv"
cat "${tmp_dir}/timing-invalid.tsv" > "${tmp_dir}/unsafe-timing-public"
grep -q 'secret=value' "${tmp_dir}/unsafe-timing-public"
if bash "${checker}" timings shell "${tmp_dir}/timing-invalid.tsv" > "${tmp_dir}/timing-public" 2>&1; then exit 1; fi
[ ! -s "${tmp_dir}/timing-public" ]
echo '[output-contract] control raw timing disclosure rejected'

# Unexpected host assertions expose only a numeric source line in public reports.
diagnostic_bin="${tmp_dir}/diagnostic-bin"
diagnostic_evidence="${case_root}/diagnostic evidence"
mkdir -p "${diagnostic_bin}"
cat > "${diagnostic_bin}/grep" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -q ] && [ "${2:-}" = 'tar must support --exclude' ]; then
  echo 'synthetic-private-host /synthetic/private/path secret=value' >&2
  exit 1
fi
exec "${DIAGNOSTIC_REAL_GREP}" "$@"
EOF
chmod +x "${diagnostic_bin}/grep"
if PATH="${diagnostic_bin}:${PATH}" DIAGNOSTIC_REAL_GREP="$(command -v grep)" \
    ZMK_TEST_ARTIFACT_DIR="${diagnostic_evidence}/host-evidence" \
    bash "${repo_root}/.github/scripts/test-build.sh" host > "${tmp_dir}/diagnostic-raw.log" 2>&1; then
  echo 'controlled host assertion did not fail' >&2; exit 1
fi
grep -q 'synthetic-private-host' "${tmp_dir}/diagnostic-raw.log"
failure_receipt="${diagnostic_evidence}/host-evidence/host-failure-line.txt"
if [ ! -f "${failure_receipt}" ]; then
  echo 'host failure did not record its assertion line' >&2; exit 1
fi
expected_line="$(awk '/^grep -q .*tar must support --exclude/ {print NR; exit}' "${repo_root}/.github/scripts/test-build.sh")"
[ -n "${expected_line}" ] && [ "$(cat "${failure_receipt}")" = "${expected_line}" ]
printf 'case\tstatus\tseconds\nhost-contract\tFAIL(1)\t1\n' > "${diagnostic_evidence}/results.tsv"
for report_mode in tests-shell tests-all; do
  (cd "${case_root}"; bash "${checker}" publish "${report_mode}" 1 'diagnostic evidence')
  diagnostic_report="${case_root}/.build/public/${report_mode}.txt"
  grep -qx "Host contract failure line: ${expected_line}" "${diagnostic_report}"
  if grep -Eq 'synthetic-private-host|/synthetic/private|secret=' "${diagnostic_report}"; then
    echo 'host failure location disclosed raw evidence' >&2; exit 1
  fi
done
(cd "${case_root}"; bash "${checker}" publish verify)
for invalid_line in 0 00 01 -1 bad 1000000 '/synthetic/private/path' '1\nsecret=value' '12\000'; do
  printf '%b\n' "${invalid_line}" > "${failure_receipt}"
  if (cd "${case_root}"; bash "${checker}" publish tests-shell 1 'diagnostic evidence') >/dev/null 2>&1; then
    echo 'publication accepted an invalid host failure line' >&2; exit 1
  fi
done
printf '%s\n' "${expected_line}" > "${failure_receipt}"
mv "${failure_receipt}" "${failure_receipt}.saved"
MSYS=winsymlinks:sys ln -s "${failure_receipt}.saved" "${failure_receipt}"
[ -L "${failure_receipt}" ] || { echo 'diagnostic receipt fixture is not a symlink' >&2; exit 1; }
if (cd "${case_root}"; bash "${checker}" publish tests-shell 1 'diagnostic evidence') >/dev/null 2>&1; then
  echo 'publication followed a host failure receipt symlink' >&2; exit 1
fi
rm "${failure_receipt}"
mv "${failure_receipt}.saved" "${failure_receipt}"
diagnostic_report="${case_root}/.build/public/tests-shell.txt"
printf 'Host contract failure line: %s\n' "${expected_line}" >> "${diagnostic_report}"
if (cd "${case_root}"; bash "${checker}" publish verify) >/dev/null 2>&1; then
  echo 'publication accepted duplicate host failure locations' >&2; exit 1
fi
printf 'case\tstatus\tseconds\nhost-contract\tPASS\t1\n' > "${diagnostic_evidence}/results.tsv"
(cd "${case_root}"; bash "${checker}" publish clear)
(cd "${case_root}"; bash "${checker}" publish tests-shell 0 'diagnostic evidence')
if grep '^Host contract failure line:' "${diagnostic_report}" >/dev/null; then
  echo 'successful host tests published a stale failure line' >&2; exit 1
fi
printf 'Host contract failure line: %s\n' "${expected_line}" >> "${diagnostic_report}"
if (cd "${case_root}"; bash "${checker}" publish verify) >/dev/null 2>&1; then
  echo 'publication accepted a failure location without a failed host test' >&2; exit 1
fi
(cd "${case_root}"; bash "${checker}" publish clear)

# Docker/build reports cannot acquire the host-only diagnostic field.
printf 'case\tstatus\tseconds\nhost-contract\tFAIL(1)\t1\n' > "${diagnostic_evidence}/results.tsv"
for report_mode in tests-docker tests-build; do
  (cd "${case_root}"; bash "${checker}" publish "${report_mode}" 1 'diagnostic evidence')
  diagnostic_report="${case_root}/.build/public/${report_mode}.txt"
  if grep '^Host contract failure line:' "${diagnostic_report}" >/dev/null; then
    echo 'non-host report published a host failure location' >&2; exit 1
  fi
  (cd "${case_root}"; bash "${checker}" publish verify)
  printf 'Host contract failure line: %s\n' "${expected_line}" >> "${diagnostic_report}"
  if (cd "${case_root}"; bash "${checker}" publish verify) >/dev/null 2>&1; then
    echo 'non-host report accepted a host failure location' >&2; exit 1
  fi
  (cd "${case_root}"; bash "${checker}" publish clear)
done

# CI wrappers retain raw data locally and preserve the actual failure status.
ci_root="${tmp_dir}/ci fixture"
mkdir -p "${ci_root}/.github/scripts" "${ci_root}/scripts" "${ci_root}/.build/${run_name}"
cp "${checker}" "${ci_root}/.github/scripts/check-build-output.sh"
cat > "${ci_root}/scripts/build-external-source.sh" <<'EOF'
#!/usr/bin/env bash
echo 'synthetic-private-host /synthetic/private/source secret=value'
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo 'private source identity' >> "${GITHUB_STEP_SUMMARY}"
exit "${PUBLIC_PROBE_EXIT}"
EOF
printf 'Status: SUCCESS\nMode: build\nBuilt targets: 1\n' > "${ci_root}/.build/${run_name}/build-summary.txt"
printf 'synthetic private build log\n' > "${ci_root}/.build/${run_name}/build.log"
printf 'synthetic private firmware\n' > "${ci_root}/.build/${run_name}/private-device.bin"
for expected in 23 0; do
  if (cd "${ci_root}"; PUBLIC_PROBE_EXIT="${expected}" GITHUB_STEP_SUMMARY="${tmp_dir}/public-summary" \
      bash .github/scripts/check-build-output.sh ci-source --path /synthetic/private/source) \
      >"${tmp_dir}/ci-stdout" 2>"${tmp_dir}/ci-stderr"; then status=0; else status=$?; fi
  [ "${status}" = "${expected}" ]
  source_log="$(cat "${ci_root}/.build/ci-source.record")"
  grep -q 'synthetic-private-host' "${ci_root}/${source_log}"
  [ ! -e "${tmp_dir}/public-summary" ]
  if grep -Eq 'synthetic-private-host|/synthetic/private|secret=' "${tmp_dir}/ci-stdout" "${tmp_dir}/ci-stderr"; then exit 1; fi
  if (cd "${ci_root}"; bash .github/scripts/check-build-output.sh ci-check build) \
      >"${tmp_dir}/ci-stdout" 2>"${tmp_dir}/ci-stderr"; then status=0; else status=$?; fi
  if [ "${expected}" = 0 ]; then
    [ "${status}" = 0 ]
    grep -qx 'Outcome: SUCCESS' "${ci_root}/.build/public/build.txt"
  else
    [ "${status}" != 0 ]
    grep -qx 'Outcome: FAILED' "${ci_root}/.build/public/build.txt"
  fi
  if grep -Eq 'synthetic-private-host|/synthetic/private|private-device|secret=' "${ci_root}/.build/public/build.txt"; then exit 1; fi
done
[ "$(find "${ci_root}/.build" -name command.log -type f | wc -l | tr -d '[:space:]')" = 4 ]

cat > "${ci_root}/.github/scripts/test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir "${ZMK_TEST_RESULTS}"
cp "${TIMING_FIXTURE}" "${ZMK_TEST_RESULTS}/profile.tsv"
printf 'case\tstatus\tseconds\n' > "${ZMK_TEST_RESULTS}/results.tsv"
for label in syntax lf whitespace lf-contract output-contract external-contract host-contract host-help container-help; do
  printf '%s\tPASS\t1\n' "${label}" >> "${ZMK_TEST_RESULTS}/results.tsv"
done
bash .github/scripts/check-build-output.sh publish "tests-$1" "${PUBLIC_PROBE_EXIT}" "${ZMK_TEST_RESULTS}"
echo 'synthetic-private-host /synthetic/private secret=value'
exit "${PUBLIC_PROBE_EXIT}"
EOF
for expected in 23 0; do
  if (cd "${ci_root}"; ZMK_TEST_RESULTS= ZMK_TEST_PROFILE=1 TIMING_FIXTURE="${timing_fixture}" PUBLIC_PROBE_EXIT="${expected}" \
      bash .github/scripts/check-build-output.sh ci-tests shell) > "${tmp_dir}/profile-ci-console" 2>&1; then status=0; else status=$?; fi
  [ "${status}" = "${expected}" ]
  timing_rows="$(grep -c '^Timing shell ' "${tmp_dir}/profile-ci-console" || true)"
  if [ "${expected}" = 0 ]; then [ "${timing_rows}" = 14 ]; else [ "${timing_rows}" = 0 ]; fi
  if grep -Eq 'synthetic-private|secret=' "${tmp_dir}/profile-ci-console"; then exit 1; fi
done
if (cd "${ci_root}"; ZMK_TEST_RESULTS= ZMK_TEST_PROFILE=1 TIMING_FIXTURE="${tmp_dir}/timing-invalid.tsv" PUBLIC_PROBE_EXIT=0 \
    bash .github/scripts/check-build-output.sh ci-tests shell) > "${tmp_dir}/profile-ci-console" 2>&1; then
  echo 'CI accepted invalid timing publication' >&2; exit 1
fi
if grep -Eq '^Timing |synthetic-private|secret=' "${tmp_dir}/profile-ci-console"; then exit 1; fi
if ! grep -qx 'Outcome: FAILED' "${ci_root}/.build/public/tests-shell.txt" ||
    ! grep -qx 'CI exit status: 1' "${ci_root}/.build/public/tests-shell.txt"; then
  echo 'timing validation failure left a successful publication report' >&2; exit 1
fi
(cd "${ci_root}"; bash .github/scripts/check-build-output.sh publish verify)

# Rejection diagnostics identify a fixed reason and a recognized metric only.
awk 'BEGIN {FS=OFS="\t"} NR==2 {$4="synthetic-private-host /synthetic/private secret=value"} {print}' \
  "${timing_fixture}" > "${tmp_dir}/timing-private-duration.tsv"
if (cd "${ci_root}"; ZMK_TEST_RESULTS= ZMK_TEST_PROFILE=1 TIMING_FIXTURE="${tmp_dir}/timing-private-duration.tsv" \
    PUBLIC_PROBE_EXIT=0 bash .github/scripts/check-build-output.sh ci-tests shell) > "${tmp_dir}/profile-ci-console" 2>&1; then
  echo 'CI accepted an invalid duration' >&2; exit 1
fi
grep -qx 'Profile report validation failed (reason=duration metric=source-before); detailed evidence remains private.' \
  "${tmp_dir}/profile-ci-console"
if grep -Eq '^Timing |synthetic-private|secret=' "${tmp_dir}/profile-ci-console"; then exit 1; fi
grep -qx 'Outcome: FAILED' "${ci_root}/.build/public/tests-shell.txt"

# A failed replacement must block publication of the producer's earlier SUCCESS.
publication_bin="${tmp_dir}/publication-bin"
mkdir "${publication_bin}"
cat > "${publication_bin}/mv" <<'EOF'
#!/usr/bin/env bash
for argument do destination="${argument}"; done
if [ "${destination}" = .build/public/tests-shell.txt ]; then
  if [ -e "${PROFILE_PUBLICATION_MOVED}" ]; then
    echo 'synthetic-private-host /synthetic/private secret=value' >&2
    exit 23
  fi
  : > "${PROFILE_PUBLICATION_MOVED}"
fi
exec "${PROFILE_REAL_MV}" "$@"
EOF
chmod +x "${publication_bin}/mv"
publication_real_mv="$(command -v mv)"
if (cd "${ci_root}"; PATH="${publication_bin}:${PATH}" PROFILE_REAL_MV="${publication_real_mv}" \
    PROFILE_PUBLICATION_MOVED="${tmp_dir}/publication-moved" ZMK_TEST_RESULTS= ZMK_TEST_PROFILE=1 \
    TIMING_FIXTURE="${tmp_dir}/timing-private-duration.tsv" PUBLIC_PROBE_EXIT=0 \
    bash .github/scripts/check-build-output.sh ci-tests shell) > "${tmp_dir}/profile-ci-console" 2>&1; then
  echo 'CI accepted a failed outcome replacement' >&2; exit 1
fi
grep -qx 'Outcome: SUCCESS' "${ci_root}/.build/public/tests-shell.txt"
if (cd "${ci_root}"; bash .github/scripts/check-build-output.sh publish verify) > "${tmp_dir}/publication-guard.log" 2>&1; then
  echo 'publication accepted an unfinalized profiling outcome' >&2; exit 1
fi
grep -qx 'Publication status was not finalized.' "${tmp_dir}/publication-guard.log"
if grep -Eq '^Timing |synthetic-private|secret=' "${tmp_dir}/profile-ci-console"; then exit 1; fi
IFS= read -r saved_source_status < "${ci_root}/.build/ci-source.status"
IFS= read -r saved_source_record < "${ci_root}/.build/ci-source.record"
(cd "${ci_root}"; bash .github/scripts/check-build-output.sh publish clear)
printf '%s\n' "${saved_source_status}" > "${ci_root}/.build/ci-source.status"
printf '%s\n' "${saved_source_record}" > "${ci_root}/.build/ci-source.record"

# A rejected existing result directory cannot turn old measurements into a fresh run.
mkdir "${ci_root}/.build/old-profile"
cp "${timing_fixture}" "${ci_root}/.build/old-profile/profile.tsv"
if (cd "${ci_root}"; ZMK_TEST_RESULTS="${ci_root}/.build/old-profile" ZMK_TEST_PROFILE=1 \
    TIMING_FIXTURE="${timing_fixture}" PUBLIC_PROBE_EXIT=0 bash .github/scripts/check-build-output.sh ci-tests shell) \
    > "${tmp_dir}/profile-ci-console" 2>&1; then
  echo 'CI accepted stale profile results' >&2; exit 1
fi
if grep -Eq '^Timing |synthetic-private|secret=' "${tmp_dir}/profile-ci-console"; then exit 1; fi
profile_bin="${tmp_dir}/profile-bin"
mkdir "${profile_bin}"
cat > "${profile_bin}/od" <<'EOF'
#!/usr/bin/env bash
echo 'synthetic-private-host /synthetic/private secret=value' >&2
exit 23
EOF
chmod +x "${profile_bin}/od"
if (cd "${ci_root}"; PATH="${profile_bin}:${PATH}" ZMK_TEST_RESULTS= ZMK_TEST_PROFILE=1 \
    TIMING_FIXTURE="${timing_fixture}" PUBLIC_PROBE_EXIT=0 bash .github/scripts/check-build-output.sh ci-tests shell) \
    > "${tmp_dir}/profile-ci-console" 2>&1; then
  echo 'CI accepted failed timing validation' >&2; exit 1
fi
if grep -Eq '^Timing |synthetic-private|secret=' "${tmp_dir}/profile-ci-console"; then exit 1; fi
grep -l 'synthetic-private-host' "${ci_root}"/.build/ci-execution.*/timing-validation.log > "${tmp_dir}/private-validation-log"
[ -s "${tmp_dir}/private-validation-log" ]

# A byte producer can fail after complete-looking output; its exit still matters.
profile_real_byte_tool="$(command -v od)"
cat > "${profile_bin}/od" <<'EOF'
#!/usr/bin/env bash
"${PROFILE_REAL_BYTE_TOOL}" "$@" || exit "$?"
echo 'synthetic-private-host /synthetic/private secret=value' >&2
exit 23
EOF
if (cd "${ci_root}"; PATH="${profile_bin}:${PATH}" PROFILE_REAL_BYTE_TOOL="${profile_real_byte_tool}" \
    ZMK_TEST_RESULTS= ZMK_TEST_PROFILE=1 TIMING_FIXTURE="${timing_fixture}" PUBLIC_PROBE_EXIT=0 \
    bash .github/scripts/check-build-output.sh ci-tests shell) > "${tmp_dir}/profile-ci-console" 2>&1; then
  echo 'CI accepted a byte producer failure after full output' >&2; exit 1
fi
if grep -Eq '^Timing |synthetic-private|secret=' "${tmp_dir}/profile-ci-console"; then exit 1; fi
for byte_output in empty truncated; do
  cat > "${profile_bin}/od" <<'EOF'
#!/usr/bin/env bash
[ "${PROFILE_BYTE_OUTPUT}" != truncated ] || printf ' 109\n'
exit 0
EOF
  if (cd "${ci_root}"; PATH="${profile_bin}:${PATH}" PROFILE_BYTE_OUTPUT="${byte_output}" \
      ZMK_TEST_RESULTS= ZMK_TEST_PROFILE=1 TIMING_FIXTURE="${timing_fixture}" PUBLIC_PROBE_EXIT=0 \
      bash .github/scripts/check-build-output.sh ci-tests shell) > "${tmp_dir}/profile-ci-console" 2>&1; then
    echo 'CI accepted incomplete byte validation' >&2; exit 1
  fi
  if grep -Eq '^Timing |synthetic-private|secret=' "${tmp_dir}/profile-ci-console"; then exit 1; fi
  grep -qx 'Outcome: FAILED' "${ci_root}/.build/public/tests-shell.txt"
done

# The runner may print every configured env value. Only numeric indices cross that boundary.
cp "${repo_root}/scripts/auto-build-external.sh" "${repo_root}/scripts/source-common.sh" "${ci_root}/scripts/"
printf 'path:/synthetic/private/first\npath:/synthetic/private/second\n' > "${ci_root}/sources.txt"
printf 'sources.txt\n' > "${ci_root}/.build/ci-source-file"
(cd "${ci_root}"; GITHUB_OUTPUT="${tmp_dir}/matrix-output" GITHUB_STEP_SUMMARY="${tmp_dir}/matrix-summary" \
  bash .github/scripts/check-build-output.sh ci-matrix) >"${tmp_dir}/matrix-console" 2>&1
grep -qx 'matrix={"include":\[{"index":1},{"index":2}\]}' "${tmp_dir}/matrix-output"
grep -qx 'Resolved source count: 2' "${tmp_dir}/matrix-summary"
if grep -Eq '/synthetic/private|first|second' "${tmp_dir}/matrix-output" "${tmp_dir}/matrix-summary" "${tmp_dir}/matrix-console"; then exit 1; fi
# A selector is always a list file, never an inferred source or a URL.
for selector in missing-list.txt https://example.invalid/sources.txt; do
  printf '%s\n' "${selector}" > "${ci_root}/.build/ci-source-file"
  rm -f "${tmp_dir}/invalid-matrix-output"
  if (cd "${ci_root}"; GITHUB_OUTPUT="${tmp_dir}/invalid-matrix-output" GITHUB_STEP_SUMMARY="${tmp_dir}/matrix-summary" \
      bash .github/scripts/check-build-output.sh ci-matrix) >"${tmp_dir}/invalid-matrix-console" 2>&1; then
    echo 'CI matrix accepted a missing list or URL selector' >&2; exit 1
  fi
  [ ! -e "${tmp_dir}/invalid-matrix-output" ]
done
printf 'sources.txt\n' > "${ci_root}/.build/ci-source-file"
# CI helpers use their repository root even when invoked from another directory.
(cd "${tmp_dir}"; GITHUB_OUTPUT="${tmp_dir}/outside-matrix-output" GITHUB_STEP_SUMMARY="${tmp_dir}/matrix-summary" \
  bash "${ci_root}/.github/scripts/check-build-output.sh" ci-matrix) >"${tmp_dir}/outside-matrix-console" 2>&1
grep -qx 'matrix={"include":\[{"index":1},{"index":2}\]}' "${tmp_dir}/outside-matrix-output"
(cd "${ci_root}/.github"; bash scripts/check-build-output.sh ci-check build) \
  >"${tmp_dir}/relative-check-console" 2>&1
grep -qx 'Outcome: SUCCESS' "${ci_root}/.build/public/build.txt"
for invalid in '' 0 3 bad; do
  if (cd "${ci_root}"; PUBLIC_PROBE_EXIT=0 bash .github/scripts/check-build-output.sh ci-source-index "${invalid}") \
    >"${tmp_dir}/index-console" 2>&1; then echo 'invalid CI source index accepted' >&2; exit 1; fi
done
printf '# empty\n' > "${ci_root}/sources.txt"
if (cd "${ci_root}"; GITHUB_OUTPUT="${tmp_dir}/empty-output" GITHUB_STEP_SUMMARY="${tmp_dir}/empty-summary" \
    bash .github/scripts/check-build-output.sh ci-matrix) >/dev/null 2>&1; then exit 1; fi
[ ! -e "${tmp_dir}/empty-output" ]
foreign="${tmp_dir}/foreign-publication"
# Private evidence must survive the cleanup performed by the next checkout.
echo '[output-contract] private evidence retention'
archive_root="${tmp_dir}/private archives"
(cd "${ci_root}"; bash .github/scripts/check-build-output.sh ci-archive "${archive_root}") \
  >"${tmp_dir}/archive-console" 2>&1
archive="$(cat "${ci_root}/.build/ci-evidence.record")"
grep -qx COMPLETE "${archive}/archive-status.txt"
test -f "${archive}/.build/${run_name}/private-device.bin"
grep -qx 'synthetic private build log' "${archive}/.build/${run_name}/build.log"
if grep -Eq 'private archives|synthetic-private|private-device|secret=' "${tmp_dir}/archive-console"; then
  echo 'private archive details reached the CI console' >&2; exit 1
fi
if (cd "${ci_root}"; bash .github/scripts/check-build-output.sh ci-archive .build/nested-archive) \
    >"${tmp_dir}/archive-rejected-console" 2>&1; then
  echo 'private evidence was archived inside checkout' >&2; exit 1
fi
[ ! -e "${ci_root}/.build/nested-archive" ]
archive_bin="${tmp_dir}/archive-bin"
mkdir "${archive_bin}"
cat > "${archive_bin}/tar" <<'EOF'
#!/usr/bin/env bash
case "${ARCHIVE_FAILURE_SIDE}:$1" in
  both:*) ;;
  pack:cf|unpack:xf) "${ARCHIVE_REAL_TAR}" "$@" || exit "$?" ;;
  *) exec "${ARCHIVE_REAL_TAR}" "$@" ;;
esac
echo 'injected archive copy failure' >&2
exit 23
EOF
chmod +x "${archive_bin}/tar"
archive_real_tar="$(command -v tar)"
for archive_failure_side in both pack unpack; do
  if (cd "${ci_root}"; PATH="${archive_bin}:${PATH}" \
      ARCHIVE_REAL_TAR="${archive_real_tar}" ARCHIVE_FAILURE_SIDE="${archive_failure_side}" \
      bash .github/scripts/check-build-output.sh ci-archive "${archive_root}") \
      >"${tmp_dir}/archive-${archive_failure_side}-failure-console" 2>&1; then
    echo "private archive ${archive_failure_side} failure was accepted" >&2; exit 1
  else
    archive_failure_status=$?
  fi
  [ "${archive_failure_status}" = 23 ] || { echo 'private archive lost the copy failure status' >&2; exit 1; }
  partial_archive="$(cat "${ci_root}/.build/ci-evidence.record")"
  [ "${partial_archive}" != "${archive}" ]
  grep -qx FAILED "${partial_archive}/archive-status.txt"
  grep -qx COMPLETE "${archive}/archive-status.txt"
  if grep -Eq 'injected|private archives|synthetic-private|secret=' "${tmp_dir}/archive-${archive_failure_side}-failure-console"; then
    echo 'private archive failure diagnostics reached the CI console' >&2; exit 1
  fi
done
git -C "${ci_root}" init -q
git -C "${ci_root}" clean -ffdx -- .build >"${tmp_dir}/archive-checkout-clean.log"
[ ! -e "${ci_root}/.build" ]
grep -qx 'synthetic private build log' "${archive}/.build/${run_name}/build.log"
test -f "${archive}/.build/${run_name}/private-device.bin"
mkdir -p "${ci_root}/.build"
mkdir -p "${foreign}"
printf 'preserve\n' > "${foreign}/keep.txt"
rm -rf "${ci_root}/.build/public"
# Git Bash defaults to copying symlink targets. Use its unprivileged MSYS link
# format for this Bash-only fixture; POSIX ln ignores the scoped setting.
MSYS=winsymlinks:sys ln -s "${foreign}" "${ci_root}/.build/public"
[ -L "${ci_root}/.build/public" ] || {
  echo 'publication fixture is not a symlink' >&2; exit 1
}
if (cd "${ci_root}"; bash .github/scripts/check-build-output.sh publish clear) >/dev/null 2>&1; then exit 1; fi
grep -qx preserve "${foreign}/keep.txt"

# Exercise the real profiling entry with synthetic metadata/daemon dispatchers.
# This is a timer-transport control, not evidence of Docker execution.
snapshot_root="${tmp_dir}/snapshot capture fixture"
mkdir -p "${snapshot_root}/.github/scripts" "${snapshot_root}/bin"
cp "${repo_root}/.github/scripts/test.sh" "${checker}" "${snapshot_root}/.github/scripts/"
cat > "${snapshot_root}/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ls-files)
    echo 'synthetic-private-host /synthetic/private snapshot warning' >&2
    if [ -n "${SNAPSHOT_FILE_LIST:-}" ]; then cat "${SNAPSHOT_FILE_LIST}"
    else printf '%s\0' .github/scripts/test.sh .github/scripts/check-build-output.sh .github/scripts/check-runner-tools.sh .github/scripts/test-build.sh; fi
    exit "${SNAPSHOT_GIT_EXIT:-0}" ;;
  rev-parse) printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  status|check-ignore) ;;
  --version) printf '%s\n' 'git version synthetic' ;;
  hash-object) "${SNAPSHOT_REAL_GIT:?}" "$@" || exit "$?"; exit "${SNAPSHOT_HASH_EXIT:-0}" ;;
  -c) [ "$#" = 4 ] && [ "$2" = core.autocrlf=false ] && [ "$3" = diff ] && [ "$4" = --check ] ;;
  *) exit 99 ;;
esac
EOF
cat > "${snapshot_root}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  volume) case "$2" in inspect) exit 1 ;; create|rm) ;; *) exit 99 ;; esac ;;
  --version|version) printf '%s\n' 'Docker synthetic' ;;
  image) printf '{}\n' ;;
  *) exit 99 ;;
esac
EOF
cat > "${snapshot_root}/.github/scripts/check-runner-tools.sh" <<'EOF'
#!/usr/bin/env bash
[ "${SNAPSHOT_MUTATE_OPTION:-0}" != 1 ] || printf 'changed\n' > ./--help
printf 'snapshot tools control\n'
EOF
cat > "${snapshot_root}/.github/scripts/test-build.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = docker ] || exit 99
[ "${ZMK_TEST_PROFILE:-0}" != 1 ] || printf 'probe-docker-exec\t0\t5\t0.125\n' >> "${ZMK_TEST_RESULTS}/profile.tsv"
printf 'snapshot Docker dispatcher control\n'
EOF
cat > "${snapshot_root}/bin/cksum" <<'EOF'
#!/usr/bin/env bash
if [ -n "${SNAPSHOT_CHECKSUM_CALLS:-}" ]; then
  { printf '%s\0' "$#"; printf '%s\0' "$@"; } >> "${SNAPSHOT_CHECKSUM_CALLS}"
fi
"${SNAPSHOT_REAL_CKSUM}" "$@" || exit "$?"
exit "${SNAPSHOT_CHECKSUM_EXIT:-0}"
EOF
snapshot_real_cksum="$(command -v cksum)"
chmod +x "${snapshot_root}/bin/git" "${snapshot_root}/bin/docker" "${snapshot_root}/bin/cksum"
(cd "${snapshot_root}"; PATH="${snapshot_root}/bin:${PATH}" ZMK_DOCKER_CACHE_VOLUME= ZMK_TEST_PROFILE=1 \
  SNAPSHOT_REAL_CKSUM="${snapshot_real_cksum}" SNAPSHOT_CHECKSUM_CALLS="${tmp_dir}/snapshot-checksum.calls" \
  ZMK_TEST_RESULTS="${snapshot_root}/.build/results" bash .github/scripts/test.sh docker) \
  > "${tmp_dir}/snapshot-capture.log" 2>&1
if ! bash "${checker}" timings docker "${snapshot_root}/.build/results/profile.tsv" > "${tmp_dir}/snapshot-timings"; then
  echo 'snapshot stderr contaminated timing records' >&2; exit 1
fi
[ "$(wc -l < "${tmp_dir}/snapshot-timings" | tr -d '[:space:]')" = 9 ]
for side in before after; do
  grep -qx 'synthetic-private-host /synthetic/private snapshot warning' "${snapshot_root}/.build/results/source-${side}.log"
  if grep -Eq 'synthetic-private|/synthetic/private' "${snapshot_root}/.build/results/source-${side}.time" \
      "${snapshot_root}/.build/results/profile.tsv" "${tmp_dir}/snapshot-timings"; then
    echo 'snapshot warning reached numeric evidence' >&2; exit 1
  fi
done
cmp "${snapshot_root}/.build/results/source-before.txt" "${snapshot_root}/.build/results/source-after.txt"
if (cd "${snapshot_root}"; PATH="${snapshot_root}/bin:${PATH}" SNAPSHOT_GIT_EXIT=23 \
    ZMK_DOCKER_CACHE_VOLUME= ZMK_TEST_PROFILE=1 ZMK_TEST_RESULTS="${snapshot_root}/.build/failed-results" \
    bash .github/scripts/test.sh docker) > "${tmp_dir}/snapshot-failure.log" 2>&1; then
  echo 'snapshot producer failure was accepted' >&2; exit 1
else snapshot_status=$?; fi
[ "${snapshot_status}" = 23 ] || { echo 'snapshot failure status changed' >&2; exit 1; }
if ! grep -qx 'CI exit status: 23' "${snapshot_root}/.build/public/tests-docker.txt"; then
  echo 'publication changed an early producer failure status' >&2; exit 1
fi
[ ! -e "${snapshot_root}/.build/failed-results/source-after.txt" ]
echo '[output-contract] snapshot warning/failure controls passed'

# Literal option-like inputs must participate in the source drift check.
printf '%s\0' .github/scripts/test.sh .github/scripts/check-build-output.sh .github/scripts/check-runner-tools.sh \
  .github/scripts/test-build.sh --help > "${tmp_dir}/snapshot-option.files"
printf 'initial\n' > "${snapshot_root}/--help"
if (cd "${snapshot_root}"; PATH="${snapshot_root}/bin:${PATH}" ZMK_DOCKER_CACHE_VOLUME= ZMK_TEST_PROFILE=0 \
    SNAPSHOT_FILE_LIST="${tmp_dir}/snapshot-option.files" SNAPSHOT_REAL_CKSUM="${snapshot_real_cksum}" \
    SNAPSHOT_MUTATE_OPTION=1 ZMK_TEST_RESULTS="${snapshot_root}/.build/option-results" \
    bash .github/scripts/test.sh docker) > "${tmp_dir}/snapshot-option.log" 2>&1; then
  if [ -n "${ZMK_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "${ZMK_TEST_ARTIFACT_DIR}"
    cp "${tmp_dir}/snapshot-checksum.calls" "${tmp_dir}/snapshot-option.log" \
      "${snapshot_root}/.build/option-results/source-before.txt" "${snapshot_root}/.build/option-results/source-after.txt" \
      "${ZMK_TEST_ARTIFACT_DIR}/"
  fi
  echo 'option-like source mutation was ignored' >&2; exit 1
else snapshot_status=$?; fi
[ "${snapshot_status}" = 1 ]
grep -q 'Source changed during verification' "${tmp_dir}/snapshot-option.log"

assert_checksum_calls() {
  local receipt="$1" expected="$2" budget="$3" count= argument= number bytes calls=0
  local LC_ALL=C
  : > "${tmp_dir}/snapshot-observed-argv"
  while IFS= read -r -d '' count; do
    case "${count}" in ''|*[!0-9]*) return 1 ;; esac
    [ "${count}" -gt 0 ] && [ "${count}" -le 16 ] || return 1
    calls=$((calls + 1)); bytes=0
    for ((number=0; number<count; number++)); do
      IFS= read -r -d '' argument || return 1
      bytes=$((bytes + ${#argument} + 1))
      printf '%s\0' "${argument}" >> "${tmp_dir}/snapshot-observed-argv"
    done
    [ "${bytes}" -le 1024 ] || [ "${count}" = 1 ] || return 1
  done < "${receipt}"
  [ -z "${count}" ] && [ "${calls}" = "${budget}" ] || return 1
  cmp "${expected}" "${tmp_dir}/snapshot-observed-argv"
}
for side in before after; do
  printf '%s\0' ./.github/scripts/test.sh ./.github/scripts/check-build-output.sh \
    ./.github/scripts/check-runner-tools.sh ./.github/scripts/test-build.sh
done > "${tmp_dir}/snapshot-basic-argv"
assert_checksum_calls "${tmp_dir}/snapshot-checksum.calls" "${tmp_dir}/snapshot-basic-argv" 2

# Empty and single eligible selections also exercise Bash 3.2 array guards.
for selection in empty single; do
  if [ "${selection}" = empty ]; then
    printf '%s\0' deleted-source.txt > "${tmp_dir}/snapshot-edge.files"
    : > "${tmp_dir}/snapshot-edge-expected.txt"
    : > "${tmp_dir}/snapshot-edge-argv"
    snapshot_call_budget=0
  else
    printf '%s\0' --help > "${tmp_dir}/snapshot-edge.files"
    checksum="$("${snapshot_real_cksum}" < "${snapshot_root}/--help")"
    printf '%s ./--help\n' "${checksum}" > "${tmp_dir}/snapshot-edge-expected.txt"
    printf '%s\0' ./--help ./--help > "${tmp_dir}/snapshot-edge-argv"
    snapshot_call_budget=2
  fi
  : > "${tmp_dir}/snapshot-edge.calls"
  (cd "${snapshot_root}"; PATH="${snapshot_root}/bin:${PATH}" ZMK_DOCKER_CACHE_VOLUME= ZMK_TEST_PROFILE=0 \
    SNAPSHOT_FILE_LIST="${tmp_dir}/snapshot-edge.files" SNAPSHOT_REAL_CKSUM="${snapshot_real_cksum}" \
    SNAPSHOT_CHECKSUM_CALLS="${tmp_dir}/snapshot-edge.calls" ZMK_TEST_RESULTS="${snapshot_root}/.build/${selection}-results" \
    bash .github/scripts/test.sh docker) > "${tmp_dir}/snapshot-${selection}.log" 2>&1
  for side in before after; do
    cmp "${tmp_dir}/snapshot-edge-expected.txt" "${snapshot_root}/.build/${selection}-results/source-${side}.txt"
  done
  assert_checksum_calls "${tmp_dir}/snapshot-edge.calls" "${tmp_dir}/snapshot-edge-argv" "${snapshot_call_budget}"
done

# Count and byte boundaries, a remainder, literal operands and a deleted selection.
cp "${tmp_dir}/snapshot-option.files" "${tmp_dir}/snapshot-batch.files"
for file in 'source with spaces 名前.txt' 'literal $() ; &.txt'; do
  printf 'payload\n\r\000\032\377\n' > "${snapshot_root}/${file}"
  printf '%s\0' "${file}" >> "${tmp_dir}/snapshot-batch.files"
done
for ((number=1; number<=9; number++)); do
  file="checksum-short-${number}.txt"
  printf 'payload %s\n' "${number}" > "${snapshot_root}/${file}"
  printf '%s\0' "${file}" >> "${tmp_dir}/snapshot-batch.files"
done
printf -v snapshot_padding '%100s' ''; snapshot_padding="${snapshot_padding// /x}"
for ((number=1; number<=12; number++)); do
  file="checksum-long-${number}-${snapshot_padding}.txt"
  printf 'long payload %s\n' "${number}" > "${snapshot_root}/${file}"
  printf '%s\0' "${file}" >> "${tmp_dir}/snapshot-batch.files"
done
printf '%s\0' deleted-source.txt >> "${tmp_dir}/snapshot-batch.files"
: > "${tmp_dir}/snapshot-batch.calls"
(cd "${snapshot_root}"; PATH="${snapshot_root}/bin:${PATH}" ZMK_DOCKER_CACHE_VOLUME= ZMK_TEST_PROFILE=0 \
  SNAPSHOT_FILE_LIST="${tmp_dir}/snapshot-batch.files" SNAPSHOT_REAL_CKSUM="${snapshot_real_cksum}" \
  SNAPSHOT_CHECKSUM_CALLS="${tmp_dir}/snapshot-batch.calls" ZMK_TEST_RESULTS="${snapshot_root}/.build/batch-results" \
  bash .github/scripts/test.sh docker) > "${tmp_dir}/snapshot-batch.log" 2>&1
: > "${tmp_dir}/snapshot-expected.txt"
while IFS= read -r -d '' file; do
  [ -f "${snapshot_root}/${file}" ] || continue
  checksum="$("${snapshot_real_cksum}" < "${snapshot_root}/${file}")"
  printf '%s ./%s\n' "${checksum}" "${file}" >> "${tmp_dir}/snapshot-expected.txt"
done < "${tmp_dir}/snapshot-batch.files"
for side in before after; do
  cmp "${tmp_dir}/snapshot-expected.txt" "${snapshot_root}/.build/batch-results/source-${side}.txt"
done
for side in before after; do
  while IFS= read -r -d '' file; do
    [ ! -f "${snapshot_root}/${file}" ] || printf './%s\0' "${file}"
  done < "${tmp_dir}/snapshot-batch.files"
done > "${tmp_dir}/snapshot-batch-argv"
assert_checksum_calls "${tmp_dir}/snapshot-batch.calls" "${tmp_dir}/snapshot-batch-argv" 6
if (cd "${snapshot_root}"; PATH="${snapshot_root}/bin:${PATH}" ZMK_DOCKER_CACHE_VOLUME= ZMK_TEST_PROFILE=0 \
    SNAPSHOT_FILE_LIST="${tmp_dir}/snapshot-batch.files" SNAPSHOT_REAL_CKSUM="${snapshot_real_cksum}" \
    SNAPSHOT_CHECKSUM_EXIT=23 ZMK_TEST_RESULTS="${snapshot_root}/.build/checksum-failed-results" \
    bash .github/scripts/test.sh docker) > "${tmp_dir}/snapshot-checksum-failure.log" 2>&1; then
  echo 'checksum producer failure was accepted' >&2; exit 1
else snapshot_status=$?; fi
[ "${snapshot_status}" = 23 ]
grep -qx 'CI exit status: 23' "${snapshot_root}/.build/public/tests-docker.txt"
echo '[output-contract] bounded checksum/content/order/failure controls passed'

# Real coordinator, synthetic commands: prove independent cases overlap while the
# Docker chain stays ordered. This does not establish real Docker acceptance.
scheduler_root="${tmp_dir}/scheduler fixture"
mkdir -p "${scheduler_root}/.github/scripts" "${scheduler_root}/scripts" "${scheduler_root}/bin" "${scheduler_root}/trace"
scheduler_root="$(cd "${scheduler_root}" && pwd -P)"
cp "${repo_root}/.github/scripts/test.sh" "${checker}" "${scheduler_root}/.github/scripts/"
cp "${snapshot_root}/bin/git" "${scheduler_root}/bin/"
cat > "${scheduler_root}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  volume)
    case "$2" in
      inspect) exit 1 ;;
      create) ;;
      rm)
        for file in "${SCHEDULER_TRACE}"/*.pid; do
          [ -f "${file}" ] || continue
          IFS= read -r child < "${file}" || exit 99
          if kill -0 "${child}" 2>/dev/null; then
            : > "${SCHEDULER_TRACE}/unsafe-cache-cleanup"; exit 99
          fi
        done
        : > "${SCHEDULER_TRACE}/cache-cleaned"
        exit "${SCHEDULER_CACHE_FAIL:-0}" ;;
      *) exit 99 ;;
    esac ;;
  --version|version) printf '%s\n' 'Docker synthetic' ;;
  image) printf '{}\n' ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${scheduler_root}/bin/docker"
cat > "${scheduler_root}/scripts/observe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="$1"
trap 'printf "%s\n" "$?" > "${SCHEDULER_TRACE}/${name}.cleanup"' EXIT
printf '%s\n' "$$" > "${SCHEDULER_TRACE}/${name}.pid"
if [ "${SCHEDULER_CASE_MODE:-}:${name}" = signal:host-contract ]; then
  bash scripts/cleanup-descendant.sh &
  attempt=0
  while [ ! -f "${SCHEDULER_TRACE}/descendant.ready" ]; do
    attempt=$((attempt + 1)); [ "${attempt}" -lt 30 ] || exit 99
    sleep 1
  done
fi
: > "${SCHEDULER_TRACE}/${name}.started"
case "${SCHEDULER_CASE_MODE:-overlap}:${name}" in
  overlap:host-contract) peer=docker-contract ;;
  overlap:docker-contract) peer=host-contract ;;
  *) peer= ;;
esac
if [ -n "${peer}" ]; then
  attempt=0
  while [ ! -f "${SCHEDULER_TRACE}/${peer}.started" ]; do
    attempt=$((attempt + 1))
    if [ "${attempt}" -ge 30 ]; then
      echo 'independent verification cases did not overlap' >&2; exit 1
    fi
    sleep 1
  done
fi
if [ "${SCHEDULER_CASE_MODE:-}" = serial ]; then
  for file in "${SCHEDULER_TRACE}"/*.started; do
    [ "${file}" = "${SCHEDULER_TRACE}/${name}.started" ] || [ -f "${file%.started}.ended" ] || {
      echo 'serial test budget overlapped cases' >&2; exit 1
    }
  done
fi
case "${name}" in
  docker-contract)
    [ -f "${SCHEDULER_TRACE}/tools.ended" ]
    [ "${ZMK_TEST_PROFILE:-0}" != 1 ] || printf 'probe-docker-exec\t0\t5\t0.125\n' >> "${ZMK_TEST_RESULTS}/profile.tsv" ;;
  firmware) [ -f "${SCHEDULER_TRACE}/docker-contract.ended" ] ;;
esac
case "${SCHEDULER_CASE_MODE:-}:${name}" in
  cap:host-contract|cap:output-contract|cap:external-contract|signal:host-contract|signal:docker-contract)
    attempt=0
    while [ ! -f "${SCHEDULER_TRACE}/${name}.release" ]; do
      attempt=$((attempt + 1)); [ "${attempt}" -lt 30 ] || exit 99
      sleep 1
    done ;;
  missing:external-contract) kill -KILL "${PPID}"; exit 0 ;;
  tools-failure:tools) exit 23 ;;
esac
: > "${SCHEDULER_TRACE}/${name}.ended"
[ "${SCHEDULER_CASE_MODE:-}:${name}" != failure:external-contract ] || exit 23
EOF
cat > "${scheduler_root}/scripts/cleanup-descendant.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'trap "" TERM; : > "${SCHEDULER_TRACE}/descendant.stopping"; while [ ! -f "${SCHEDULER_TRACE}/descendant.release" ]; do sleep 1; done; : > "${SCHEDULER_TRACE}/descendant.cleanup"; exit 143' TERM
printf '%s\n' "$$" > "${SCHEDULER_TRACE}/descendant.pid"
: > "${SCHEDULER_TRACE}/descendant.ready"
while :; do sleep 1; done
EOF
for entry in check-lf:lf test-check-lf:lf-contract test-check-build-output:output-contract \
    test-auto-build-external:external-contract check-runner-tools:tools test-build-fixtures:firmware; do
  printf '#!/usr/bin/env bash\nexec bash scripts/observe.sh %s\n' "${entry#*:}" \
    > "${scheduler_root}/.github/scripts/${entry%:*}.sh"
done
cat > "${scheduler_root}/.github/scripts/test-build.sh" <<'EOF'
#!/usr/bin/env bash
exec bash scripts/observe.sh "$1-contract"
EOF
cat > "${scheduler_root}/build.sh" <<'EOF'
#!/usr/bin/env bash
case "${ZMK_IN_CONTAINER:-0}" in 1) name=container-help ;; *) name=host-help ;; esac
exec bash scripts/observe.sh "${name}"
EOF
if ! (cd "${scheduler_root}"; PATH="${scheduler_root}/bin:${PATH}" ZMK_DOCKER_CACHE_VOLUME= \
    ZMK_TEST_JOBS=2 ZMK_TEST_PROFILE=1 SCHEDULER_TRACE="${scheduler_root}/trace" \
    ZMK_TEST_RESULTS="${scheduler_root}/.build/overlap" bash .github/scripts/test.sh all) \
    > "${tmp_dir}/scheduler-overlap.log" 2>&1; then
  cat "${tmp_dir}/scheduler-overlap.log" >&2
  echo 'independent verification overlap control failed' >&2; exit 1
fi
bash "${checker}" timings all "${scheduler_root}/.build/overlap/profile.tsv" > "${tmp_dir}/scheduler-timings"
[ "$(wc -l < "${tmp_dir}/scheduler-timings" | tr -d '[:space:]')" = 19 ]
echo '[output-contract] independent verification overlap/order control passed'

real_hash_git="$(command -v git)"
cache_image="synthetic.invalid/sdk@sha256:1111111111111111111111111111111111111111111111111111111111111111"
for cache_case in immutable other-image other-platform explicit floating no-platform; do
  cache_platform=linux/amd64; cache_selected=; selected_image="${cache_image}"
  selected_prefix=zmk-build-script-test-control
  case "${cache_case}" in
    other-image) selected_image=synthetic.invalid/sdk@sha256:2222222222222222222222222222222222222222222222222222222222222222 ;;
    other-platform) cache_platform=linux/arm64 ;;
    explicit) cache_selected=zmk-build-script-test-explicit; selected_prefix='../unused prefix' ;;
    floating) selected_image=synthetic.invalid/sdk:stable ;;
    no-platform) cache_platform= ;;
  esac
  mkdir "${scheduler_root}/trace-cache-${cache_case}"
  (cd "${scheduler_root}"; PATH="${scheduler_root}/bin:${PATH}" ZMK_DOCKER_CACHE_VOLUME="${cache_selected}" \
    ZMK_TEST_CACHE_PREFIX="${selected_prefix}" ZMK_BUILD_IMAGE="${selected_image}" \
    ZMK_DOCKER_PLATFORM="${cache_platform}" SNAPSHOT_REAL_GIT="${real_hash_git}" \
    ZMK_TEST_JOBS=2 ZMK_TEST_PROFILE=0 SCHEDULER_CASE_MODE=plain \
    SCHEDULER_TRACE="${scheduler_root}/trace-cache-${cache_case}" \
    ZMK_TEST_RESULTS="${scheduler_root}/.build/cache-${cache_case}" bash .github/scripts/test.sh docker) \
    > "${tmp_dir}/cache-${cache_case}.log" 2>&1
  case "${cache_case}" in
    immutable|other-image|other-platform)
      cache_key="$(printf '%s\0%s\0' "${selected_image}" "${cache_platform}" | "${real_hash_git}" hash-object --stdin)"
      if ! grep -qx "Cache volume: zmk-build-script-test-control-${cache_key}" \
          "${scheduler_root}/.build/cache-${cache_case}/environment.txt" ||
          [ -e "${scheduler_root}/trace-cache-${cache_case}/cache-cleaned" ]; then
        echo 'immutable managed test cache was not retained' >&2; exit 1
      fi ;;
    explicit)
      grep -qx "Cache volume: ${cache_selected}" "${scheduler_root}/.build/cache-${cache_case}/environment.txt"
      [ ! -e "${scheduler_root}/trace-cache-${cache_case}/cache-cleaned" ] ;;
    floating|no-platform)
      test -f "${scheduler_root}/trace-cache-${cache_case}/cache-cleaned"
      grep -q '^Cache volume: zmk-test-' "${scheduler_root}/.build/cache-${cache_case}/environment.txt" ;;
  esac
done
for bad_prefix in zmk-production '../zmk-build-script-test-escape' 'zmk-build-script-test-has space' 'zmk-build-script-test-x:/host'; do
  if (cd "${scheduler_root}"; ZMK_DOCKER_CACHE_VOLUME= ZMK_TEST_CACHE_PREFIX="${bad_prefix}" \
      ZMK_BUILD_IMAGE="${cache_image}" ZMK_DOCKER_PLATFORM=linux/amd64 \
      ZMK_TEST_RESULTS="${scheduler_root}/.build/cache-invalid" bash .github/scripts/test.sh docker) \
      > "${tmp_dir}/cache-invalid.log" 2>&1; then exit 1; else snapshot_status=$?; fi
  [ "${snapshot_status}" = 2 ]
  grep -qx 'Invalid managed test cache prefix.' "${tmp_dir}/cache-invalid.log"
  [ ! -e "${scheduler_root}/.build/cache-invalid" ]
done
if (cd "${scheduler_root}"; PATH="${scheduler_root}/bin:${PATH}" ZMK_DOCKER_CACHE_VOLUME= \
    ZMK_TEST_CACHE_PREFIX=zmk-build-script-test-control ZMK_BUILD_IMAGE="${cache_image}" ZMK_DOCKER_PLATFORM=linux/amd64 \
    SNAPSHOT_REAL_GIT="${real_hash_git}" SNAPSHOT_HASH_EXIT=23 ZMK_TEST_RESULTS="${scheduler_root}/.build/cache-hash-failed" \
    bash .github/scripts/test.sh docker) > "${tmp_dir}/cache-hash-failed.log" 2>&1; then exit 1; else snapshot_status=$?; fi
[ "${snapshot_status}" = 23 ]
grep -qx 'Failed to derive managed test cache identity.' "${tmp_dir}/cache-hash-failed.log"
[ ! -e "${scheduler_root}/.build/cache-hash-failed" ]
echo '[output-contract] managed cache identity/retention/override controls passed'

printf '%s\n' syntax lf whitespace lf-contract output-contract external-contract host-contract \
  host-help container-help tools docker-contract firmware > "${tmp_dir}/scheduler-expected-order"
assert_scheduler_order() {
  awk -F '\t' 'NR>1 {print $1}' "$1/results.tsv" > "${tmp_dir}/scheduler-actual-order"
  cmp "${tmp_dir}/scheduler-expected-order" "${tmp_dir}/scheduler-actual-order"
}
assert_scheduler_order "${scheduler_root}/.build/overlap"
scheduler_run() {
  local label="$1" budget="$2" scenario="$3" expected="$4" status
  mkdir "${scheduler_root}/trace-${label}"
  if (cd "${scheduler_root}" || exit "$?"
      export PATH="${scheduler_root}/bin:${PATH}" ZMK_DOCKER_CACHE_VOLUME= ZMK_TEST_PROFILE=0
      export SCHEDULER_TRACE="${scheduler_root}/trace-${label}" SCHEDULER_CASE_MODE="${scenario}"
      export ZMK_TEST_RESULTS="${scheduler_root}/.build/${label}"
      if [ "${budget}" = default ]; then unset ZMK_TEST_JOBS; else export ZMK_TEST_JOBS="${budget}"; fi
      bash .github/scripts/test.sh all) > "${tmp_dir}/scheduler-${label}.log" 2>&1; then status=0; else status=$?; fi
  if [ "${status}" != "${expected}" ]; then
    cat "${tmp_dir}/scheduler-${label}.log" >&2
    echo 'scheduler returned an unexpected exit status' >&2; exit 1
  fi
  assert_scheduler_order "${scheduler_root}/.build/${label}"
  [ ! -e "${scheduler_root}/trace-${label}/unsafe-cache-cleanup" ]
}
scheduler_run serial 0001 serial 0
grep -qx 'Test jobs: 1' "${scheduler_root}/.build/serial/environment.txt"
scheduler_run default default plain 0
grep -qx 'Test jobs: 4' "${scheduler_root}/.build/default/environment.txt"
scheduler_run failure 16 failure 1
grep -q $'^external-contract\tFAIL(23)\t' "${scheduler_root}/.build/failure/results.tsv"
scheduler_run missing 2 missing 1
grep -q $'^external-contract\tFAIL(137)\t' "${scheduler_root}/.build/missing/results.tsv"
grep -q 'external-contract: missing or invalid completion record' "${tmp_dir}/scheduler-missing.log"

mkdir "${scheduler_root}/trace-tools-failure"
if (cd "${scheduler_root}"; PATH="${scheduler_root}/bin:${PATH}" ZMK_DOCKER_CACHE_VOLUME= \
    ZMK_TEST_JOBS=4 ZMK_TEST_PROFILE=0 SCHEDULER_CASE_MODE=tools-failure \
    SCHEDULER_TRACE="${scheduler_root}/trace-tools-failure" ZMK_TEST_RESULTS="${scheduler_root}/.build/tools-failure" \
    bash .github/scripts/test.sh all) > "${tmp_dir}/scheduler-tools-failure.log" 2>&1; then exit 1; else snapshot_status=$?; fi
[ "${snapshot_status}" = 1 ]
grep -q $'^tools\tFAIL(23)\t' "${scheduler_root}/.build/tools-failure/results.tsv"
grep -qx $'docker-dependent\tBLOCKED(tools)\t0' "${scheduler_root}/.build/tools-failure/results.tsv"
awk -F '\t' 'NR>1 && $2=="PASS" {n++} END {exit n!=9}' "${scheduler_root}/.build/tools-failure/results.tsv"
[ ! -e "${scheduler_root}/trace-tools-failure/docker-contract.started" ]
[ ! -e "${scheduler_root}/trace-tools-failure/firmware.started" ]

scheduler_wait_marker() {
  local attempt=0
  while [ ! -f "$1" ]; do
    attempt=$((attempt + 1))
    [ "${attempt}" -lt 30 ] || { echo 'scheduler marker did not arrive' >&2; exit 1; }
    sleep 1
  done
}
scheduler_start() {
  local label="$1" scenario="$2" cache_status="${3:-0}" monitor=0
  mkdir "${scheduler_root}/trace-${label}"
  case $- in *m*) monitor=1 ;; esac
  set -m
  (cd "${scheduler_root}" || exit "$?"
    PATH="${scheduler_root}/bin:${PATH}" ZMK_DOCKER_CACHE_VOLUME= ZMK_TEST_JOBS=2 ZMK_TEST_PROFILE=0 \
      SCHEDULER_CASE_MODE="${scenario}" SCHEDULER_TRACE="${scheduler_root}/trace-${label}" \
      SCHEDULER_CACHE_FAIL="${cache_status}" ZMK_TEST_RESULTS="${scheduler_root}/.build/${label}" \
      exec bash .github/scripts/test.sh "${SCHEDULER_TEST_MODE:-all}") > "${tmp_dir}/scheduler-${label}.log" 2>&1 &
  scheduler_pid=$!
  [ "${monitor}" = 1 ] || set +m
}
SCHEDULER_TEST_MODE=shell scheduler_start cap cap
scheduler_wait_marker "${scheduler_root}/trace-cap/host-contract.started"
scheduler_wait_marker "${scheduler_root}/trace-cap/output-contract.started"
[ ! -e "${scheduler_root}/trace-cap/external-contract.started" ]
: > "${scheduler_root}/trace-cap/output-contract.release"
scheduler_wait_marker "${scheduler_root}/trace-cap/external-contract.started"
[ ! -e "${scheduler_root}/trace-cap/host-contract.ended" ]
: > "${scheduler_root}/trace-cap/host-contract.release"
: > "${scheduler_root}/trace-cap/external-contract.release"
wait "${scheduler_pid}"; scheduler_pid=

for signal in TERM INT; do
  case "${signal}" in TERM) expected=143; cache_status=0 ;; INT) expected=130; cache_status=23 ;; esac
  scheduler_start "signal-${signal}" signal "${cache_status}"
  scheduler_wait_marker "${scheduler_root}/trace-signal-${signal}/host-contract.started"
  scheduler_wait_marker "${scheduler_root}/trace-signal-${signal}/docker-contract.started"
  kill -"${signal}" "${scheduler_pid}"
  scheduler_wait_marker "${scheduler_root}/trace-signal-${signal}/descendant.stopping"
  attempt=0
  while [ ! -e "${scheduler_root}/.build/signal-${signal}/host-contract.group-waiting" ] &&
      [ ! -e "${scheduler_root}/trace-signal-${signal}/unsafe-cache-cleanup" ]; do
    attempt=$((attempt + 1)); [ "${attempt}" -lt 30 ] || break
    sleep 1
  done
  : > "${scheduler_root}/trace-signal-${signal}/descendant.release"
  if wait "${scheduler_pid}"; then snapshot_status=0; else snapshot_status=$?; fi
  scheduler_pid=
  if [ -e "${scheduler_root}/trace-signal-${signal}/unsafe-cache-cleanup" ] ||
      [ ! -f "${scheduler_root}/trace-signal-${signal}/descendant.cleanup" ]; then
    echo 'owned descendant cleanup was not awaited' >&2; exit 1
  fi
  [ "${snapshot_status}" = "${expected}" ]
  grep -qx "CI exit status: ${expected}" "${scheduler_root}/.build/public/tests-all.txt"
  for name in host-contract docker-contract; do
    test -f "${scheduler_root}/trace-signal-${signal}/${name}.cleanup"
  done
  test -f "${scheduler_root}/trace-signal-${signal}/cache-cleaned"
  [ ! -e "${scheduler_root}/trace-signal-${signal}/unsafe-cache-cleanup" ]
done
number=0
for budget in '' 0 00 -1 1.5 17 999999999999999 '$(exit 99)'; do
  number=$((number + 1))
  if (cd "${scheduler_root}"; ZMK_TEST_JOBS="${budget}" ZMK_TEST_RESULTS="${scheduler_root}/.build/invalid-${number}" \
      bash .github/scripts/test.sh shell) > "${tmp_dir}/scheduler-invalid.log" 2>&1; then exit 1; else snapshot_status=$?; fi
  [ "${snapshot_status}" = 2 ]
  grep -qx 'ZMK_TEST_JOBS must be an integer from 1 to 16.' "${tmp_dir}/scheduler-invalid.log"
  [ ! -e "${scheduler_root}/.build/invalid-${number}" ]
done
echo '[output-contract] scheduler budgets/refill/order/failure/interruption controls passed'

echo "check-build-output.sh behavior tests passed."
