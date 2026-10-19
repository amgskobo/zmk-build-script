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

echo "check-build-output.sh behavior tests passed."
