#!/usr/bin/env bash
# Firmware contracts: standard targets, overlays/restoration and a standalone application.
set -euo pipefail
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

capture_container_build_stream() {
  local container="$1" output="$2" marker="$3" attempt=1 snapshot
  # Docker's log reader may briefly lag the attached stream after process exit.
  # Preserve every read and still require the expected completion marker.
  while [ "${attempt}" -le 10 ]; do
    snapshot="${output}.attempt-${attempt}"
    if ! docker logs "${container}" > "${snapshot}" 2>&1; then
      cp "${snapshot}" "${output}" || return 1
      echo 'Failed to read the container build log.' >&2
      return 1
    fi
    cp "${snapshot}" "${output}" || return 1
    if grep -F -- "${marker}" "${output}"; then return 0; fi
    [ "${attempt}" -ge 10 ] || sleep 1
    attempt=$((attempt + 1))
  done
  echo 'Timed out waiting for the container build log completion marker.' >&2
  return 1
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${repo_root}"
: "${ZMK_TEST_RESULTS:?Run through .github/scripts/test.sh}"
: "${ZMK_DOCKER_CACHE_VOLUME:?A dedicated cache is required}"
scratch="$(mktemp -d "${repo_root}/.build/zmk-firmware-test.XXXXXX")"
containers=()
container_logs=()
cleanup() {
  local container log
  # Keep only immutable IDs actually returned by create, never a requested name.
  for log in ${container_logs[@]+"${container_logs[@]}"}; do
    [ -f "${log}" ] || continue
    container="$(tr -d '\r' < "${log}" | awk 'length($0) == 64 && $0 !~ /[^0-9a-f]/ && !found {print; found=1}')"
    [ -z "${container}" ] || containers+=("${container}")
  done
  for container in ${containers[@]+"${containers[@]}"}; do docker rm -f "${container}" >/dev/null 2>&1 || true; done
  rm -rf "${scratch}"
}
trap cleanup EXIT
build_case() {
  local name="$1" run expectations expected_image expected_tag expected_target artifact
  shift
  expectations="${ZMK_TEST_RESULTS}/${name}.expect"
  expected_target="$(cd "$1" && pwd -P)"
  expected_image="${ZMK_BUILD_IMAGE:-}"
  if [ -z "${expected_image}" ]; then
    # These fixtures pin a mainline commit; their auto toolchain is stable.
    expected_tag="${ZMK_BUILD_IMAGE_TAG:-auto}"
    [ "${expected_tag}" != auto ] || expected_tag=stable
    expected_image="${ZMK_BUILD_IMAGE_REPOSITORY:-zmkfirmware/zmk-build-arm}:${expected_tag}"
  fi
  {
    printf '%s\0' image "${expected_image}" target "${expected_target}" cache "${ZMK_DOCKER_CACHE_VOLUME}"
    case "${name}" in
      standard)
        for artifact in ci_extra_nice_nano_corne_left_nice_view_adapter ci_split_nice_nano_corne_right_nice_view_adapter \
          ci_bootloader_settings_reset ci_bootloader_settings_reset_xiao_ble ci_bootloader_corne_left \
          ci_xiao_ble_tester ci_bootloader_corne_right ci_reset_nice_nano; do
          printf '%s\0' artifact "${artifact}.uf2"
        done ;;
      overlay|restore)
        printf '%s\0' artifact ci_module_override_zmk_studio_messages.bin artifact ci_module_override_reset_hex.hex ;;
      standalone) printf '%s\0' artifact ci_standalone.bin ;;
      *) echo 'Missing fixture output expectations.' >&2; return 1 ;;
    esac
  } > "${expectations}"
  container_logs+=("${ZMK_TEST_RESULTS}/${name}.log")
  bash build.sh "$@" | tee "${ZMK_TEST_RESULTS}/${name}.log"
  run="$(sed $'s/\033\[[0-9;]*m//g' "${ZMK_TEST_RESULTS}/${name}.log" | tail -n 1 | tr -d '\r')"
  bash .github/scripts/check-build-output.sh build "${run}" --expect "${expectations}"
  case "${name}" in
    standard)
      grep -qx 'Built targets: 8' "${run}/build-summary.txt"
      [ "$(find "${run}" -maxdepth 1 -name '*.uf2' | wc -l | tr -d '[:space:]')" = 8 ] ;;
    overlay|restore)
      grep -qx 'Built targets: 2' "${run}/build-summary.txt"
      test -f "${run}/ci_module_override_zmk_studio_messages.bin"
      test -f "${run}/ci_module_override_reset_hex.hex" ;;
    standalone)
      grep -qx 'Built targets: 1' "${run}/build-summary.txt"
      test -f "${run}/ci_standalone.bin" ;;
  esac
  printf '%s\t%s\n' "${name}" "${run}" >> "${ZMK_TEST_RESULTS}/firmware-runs.tsv"
  last_container="$(tr -d '\r' < "${ZMK_TEST_RESULTS}/${name}.log" | awk 'length($0) == 64 && $0 !~ /[^0-9a-f]/ && !found {print; found=1}')"
  [ -n "${last_container}" ] || { echo 'build did not return a container ID' >&2; return 1; }
}
pristine=()
[ "${ZMK_TEST_PRISTINE:-0}" != 1 ] || pristine+=(--pristine)
build_case standard .github/fixtures/ci-zmk-config --jobs "${ZMK_BUILD_JOBS:-1}" ${pristine[@]+"${pristine[@]}"}
cache_reader="zmk-test-cache-$$"
# Record ownership only after create succeeds.
cache_reader_id="$(docker create --name "${cache_reader}" -v "${ZMK_DOCKER_CACHE_VOLUME}:/workspaces" \
  "${ZMK_BUILD_IMAGE:-zmkfirmware/zmk-build-arm:stable}" | tr -d '\r')"
containers+=("${cache_reader_id}")
# Use the same native host-path conversion as external clone.
source scripts/build-external-source.sh
host_scratch="$(docker_host_path "${scratch}")"
docker cp "${cache_reader_id}:/workspaces/zmk-config/modules/msgs/zmk-studio-messages" "${host_scratch}/"
docker cp "${cache_reader_id}:/workspaces/zmk-config/modules/lib/zcbor" "${host_scratch}/"
touch "${scratch}/zmk-studio-messages/.ci-local-override" "${scratch}/zcbor/.ci-local-override"
extra="${scratch}/zmk-feature-ci-extra"
mkdir -p "${extra}/zephyr" "${extra}/boards/shields/ci-extra" "${extra}/snippets/ci-extra"
printf 'name: zmk-feature-ci-extra\nbuild: {settings: {board_root: ., snippet_root: .}}\n' > "${extra}/zephyr/module.yml"
printf 'name: ci-extra\n' > "${extra}/snippets/ci-extra/snippet.yml"
hidden="${scratch}/.ci-hidden-extra"
mkdir -p "${hidden}/zephyr"
printf 'name: ci-hidden-extra\nbuild: {cmake: .}\n' > "${hidden}/zephyr/module.yml"
printf 'message(STATUS "Hidden module input reached CMake")\n' > "${hidden}/CMakeLists.txt"
overlay="zmk-test-overlay-$$"
ZMK_KEEP_CONTAINER=1 ZMK_CONTAINER_NAME="${overlay}" build_case overlay .github/fixtures/module-override-zmk-config \
  -m "${scratch}/zmk-studio-messages" -m "${scratch}/zcbor" -m "${extra}" -m "${hidden}"
for pair in zmk-studio-messages:msgs zcbor:lib; do
  project="${pair%:*}"; parent="${pair#*:}"
  grep -F "Overlaying module input west project: ${project} -> modules/${parent}/${project}" "${ZMK_TEST_RESULTS}/overlay.log"
  docker exec "${last_container}" test -f "/workspaces/zmk-config/modules/${parent}/${project}/.ci-local-override"
done
grep -F 'Adding module input as extra module: zmk-feature-ci-extra' "${ZMK_TEST_RESULTS}/overlay.log"
grep -F 'Adding module input as extra module: .ci-hidden-extra' "${ZMK_TEST_RESULTS}/overlay.log"
[ "$(grep -c '^-- Hidden module input reached CMake$' "${ZMK_TEST_RESULTS}/overlay.log")" = 2 ]
restore="zmk-test-restore-$$"
# Never pass --pristine: the previous workspace is the subject of this assertion.
ZMK_KEEP_CONTAINER=1 ZMK_CONTAINER_NAME="${restore}" build_case restore .github/fixtures/module-override-zmk-config
for pair in zmk-studio-messages:msgs zcbor:lib; do
  project="${pair%:*}"; parent="${pair#*:}"
  grep -F "Restoring previous module input overlay from backup: ${project} -> modules/${parent}/${project}" "${ZMK_TEST_RESULTS}/restore.log"
  docker exec "${last_container}" test ! -e "/workspaces/zmk-config/modules/${parent}/${project}/.ci-local-override"
done
docker exec "${last_container}" sh -c 'cd /workspaces/zmk-config; west list -f "{name} {revision} {path}"; west forall -c "git rev-parse HEAD"' \
  > "${ZMK_TEST_RESULTS}/dependencies.txt"
docker exec -i "${last_container}" python3 - <<'PY'
import pathlib
import re
import subprocess
import yaml
root = pathlib.Path('/workspaces/zmk-config')
manifest = yaml.safe_load(pathlib.Path('/root/zmk-config/config/west.yml').read_text())['manifest']
projects = {project['name']: project for project in manifest['projects']}
upstream = yaml.safe_load((root / 'zmk/app/west.yml').read_text())['manifest']['projects']
upstream_zephyr = next(project for project in upstream if project['name'] == 'zephyr')
for key in ('import', 'clone-depth'):
    assert projects['zephyr'].get(key) == upstream_zephyr.get(key), key
for name in ('zmk', 'zephyr'):
    expected = projects[name]['revision']
    assert re.fullmatch('[0-9a-f]{40}', expected), (name, expected)
    actual = subprocess.check_output(['git', '-C', str(root / name), 'rev-parse', 'HEAD'], text=True).strip()
    assert actual == expected, (name, expected, actual)
    print('Verified fixture dependency:', name, actual)
PY
capture_container_build_stream "${last_container}" "${ZMK_TEST_RESULTS}/container-build-stream.log" 'Build complete: 2 target(s).'
# Reuse the resolved manifest, but compile a root application with module search roots.
# Its CMakeLists.txt must remain the application entry point, not a module build file.
standalone="${scratch}/standalone"
mkdir -p "${standalone}/config" "${standalone}/src" "${standalone}/boards" \
  "${standalone}/dts" "${standalone}/snippets/ci-standalone"
cp .github/fixtures/ci-zmk-config/config/west.yml "${standalone}/config/west.yml"
cat > "${standalone}/build.yaml" <<'EOF'
application: .
include:
  - board: nrf52840dk/nrf52840
    snippet: ci-standalone
    artifact-name: ci_standalone
EOF
cat > "${standalone}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(ci_standalone)
target_sources(app PRIVATE src/main.c)
EOF
printf '#include <zephyr/kernel.h>\nint main(void) { return 0; }\n' > "${standalone}/src/main.c"
touch "${standalone}/prj.conf"
cat > "${standalone}/snippets/ci-standalone/snippet.yml" <<'EOF'
name: ci-standalone
append:
  EXTRA_CONF_FILE: ci-standalone.conf
EOF
printf 'CONFIG_PRINTK=y\n' > "${standalone}/snippets/ci-standalone/ci-standalone.conf"
ZMK_KEEP_CONTAINER=1 build_case standalone "${standalone}"
test ! -f "${standalone}/zephyr/module.yml"
docker exec -i "${last_container}" python3 - <<'PY'
import pathlib
import yaml
root = pathlib.Path('/root/zmk-config')
metadata = yaml.safe_load((root / 'zephyr/module.yml').read_text())
assert metadata['build'] == {'settings': {
    'board_root': '.', 'dts_root': '.', 'snippet_root': '.'}}, metadata
PY

echo 'Firmware build/overlay/restore/standalone contracts passed.'
