#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
checker="${repo_root}/.github/scripts/check-build-output.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zmk-output-check.XXXXXX")"
case_root="${tmp_dir}/case"
run_name="run-2026-05-23_00-00-00-pid-1"
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
  local mode="$1" run_arg="${2:-}"
  if [ -n "${run_arg}" ]; then
    (cd "${case_root}" && bash "${checker}" "${mode}" "${run_arg}" >/dev/null)
  else
    (cd "${case_root}" && bash "${checker}" "${mode}" >/dev/null)
  fi
}

run_fail() {
  local mode="$1" expected="$2" run_arg="${3:-}"
  if [ -n "${run_arg}" ]; then
    check_cmd=(bash "${checker}" "${mode}" "${run_arg}")
  else
    check_cmd=(bash "${checker}" "${mode}")
  fi
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

# Reject contradictory/duplicate summary fields instead of accepting one matching line.
for field in Status Mode 'Built targets' 'Fallback binary'; do
  reset_case
  write_summary <<'EOF'
Status: SUCCESS
Mode: build
Built targets: 1
Fallback binary: bin
EOF
  touch "${run_path}/selected.bin"
  printf '%s: conflicting\n' "${field}" >> "${run_path}/build-summary.txt"
  run_fail build "duplicate summary field: ${field}"
done

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
