#!/usr/bin/env bash
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tmp_parent="${repo_root}/.build"
mkdir -p "${tmp_parent}"
tmp_dir="$(mktemp -d "${tmp_parent}/zmk-copy-excludes.XXXXXX")"
tool_root="${tmp_dir}/tool-root"
fixture="${tool_root}/.github/fixtures/ci-zmk-config"
local_modules_root="${tool_root}/local_modules"
containers=()
last_container=""

cleanup() {
  local container
  for container in "${containers[@]}"; do
    docker rm -f "${container}" >/dev/null 2>&1 || true
  done
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

mkdir -p "${fixture}/config" "${tool_root}/.build"
cp "${repo_root}/build.sh" "${tool_root}/build.sh"
cp "${repo_root}/.github/fixtures/ci-zmk-config/config/west.yml" "${fixture}/config/west.yml"
cp "${repo_root}/.github/fixtures/ci-zmk-config/build.yaml" "${fixture}/build.yaml"

add_payload_dirs() {
  local root="$1" dir
  for dir in modules tools zmk bootloader optional; do
    mkdir -p "${root}/${dir}"
    printf 'generated\n' > "${root}/${dir}/generated.txt"
  done
  mkdir -p "${root}/src"
  printf 'keep\n' > "${root}/src/keep.txt"
}

make_target() {
  local name="$1" with_west="$2" target
  target="${tmp_dir}/${name}-target"
  mkdir -p "${target}/config"
  cp "${fixture}/config/west.yml" "${target}/config/west.yml"
  cp "${fixture}/build.yaml" "${target}/build.yaml"
  [ "${with_west}" = "west" ] && mkdir -p "${target}/.west"
  add_payload_dirs "${target}"
  printf '%s\n' "${target}"
}

make_module() {
  local name="$1" with_west="$2" root="${3:-${tmp_dir}}" module
  module="${root}/${name}"
  mkdir -p "${module}"
  [ "${with_west}" = "west" ] && mkdir -p "${module}/.west"
  add_payload_dirs "${module}"
  printf '%s\n' "${module}"
}

run_validate() {
  local scenario="$1" target="$2" module_arg="${3:-}" log_path
  local container="zmk-copy-excludes-${scenario}-$$"
  containers+=("${container}")
  last_container="${container}"
  log_path="${tmp_dir}/${scenario}.log"

  echo "[copy-excludes] ${scenario}"
  if [ -n "${module_arg}" ]; then
    ZMK_KEEP_CONTAINER=1 ZMK_CONTAINER_NAME="${container}" \
      bash "${tool_root}/build.sh" validate "${target}" --settings-reset -m "${module_arg}" >"${log_path}" 2>&1 ||
      { tail -n 120 "${log_path}" >&2; return 1; }
  else
    ZMK_KEEP_CONTAINER=1 ZMK_CONTAINER_NAME="${container}" \
      bash "${tool_root}/build.sh" validate "${target}" --settings-reset >"${log_path}" 2>&1 ||
      { tail -n 120 "${log_path}" >&2; return 1; }
  fi
}

assert_preserved() {
  local container="$1" base="$2"
  docker exec "${container}" /bin/bash -lc '
    set -eu
    base="$1"
    test -f "${base}/src/keep.txt"
    for dir in modules tools zmk bootloader optional; do
      test -f "${base}/${dir}/generated.txt" || { echo "missing:${dir}" >&2; exit 1; }
    done
  ' _ "${base}"
}

assert_excluded() {
  local container="$1" base="$2"
  docker exec "${container}" /bin/bash -lc '
    set -eu
    base="$1"
    test -f "${base}/src/keep.txt"
    for dir in modules tools zmk bootloader optional; do
      if [ -e "${base}/${dir}" ]; then
        echo "present:${dir}" >&2
        exit 1
      fi
    done
  ' _ "${base}"
}

mkdir -p "${local_modules_root}"

target_no_west="$(make_target target-no-west none)"
run_validate target-no-west-preserve "${target_no_west}"
assert_preserved "${last_container}" /root/zmk-config

target_west="$(make_target target-west west)"
run_validate target-west-exclude "${target_west}"
assert_excluded "${last_container}" /root/zmk-config

module_target="$(make_target module-target west)"

external_no_west="$(make_module external-no-west none)"
run_validate external-no-west-preserve "${module_target}" "${external_no_west}"
assert_preserved "${last_container}" /root/external_modules/external-no-west

external_west="$(make_module external-west west)"
run_validate external-west-exclude "${module_target}" "${external_west}"
assert_excluded "${last_container}" /root/external_modules/external-west

local_no_west="$(make_module local-no-west none "${local_modules_root}")"
run_validate local-no-west-preserve "${module_target}"
assert_preserved "${last_container}" /root/local_modules/local-no-west
rm -rf "${local_no_west}"

local_west="$(make_module local-west west "${local_modules_root}")"
run_validate local-west-exclude "${module_target}"
assert_excluded "${last_container}" /root/local_modules/local-west
rm -rf "${local_west}"

echo "copy exclude behavior tests passed."
