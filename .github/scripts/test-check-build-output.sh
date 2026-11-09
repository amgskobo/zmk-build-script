#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
checker="${repo_root}/.github/scripts/check-build-output.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zmk-output-check.XXXXXX")"
case_root="${tmp_dir}/case"
run_name="run-2026-05-23_00-00-00-ci-zmk-config"
run_path="${case_root}/.build/${run_name}"

cleanup() {
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

echo "check-build-output.sh behavior tests passed."
