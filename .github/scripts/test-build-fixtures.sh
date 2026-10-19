#!/usr/bin/env bash
# Firmware contracts: standard targets, two project overlays, then restoration without pristine.
set -euo pipefail
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${repo_root}"
: "${ZMK_TEST_RESULTS:?Run through .github/scripts/test.sh}"
: "${ZMK_DOCKER_CACHE_VOLUME:?A dedicated cache is required}"
scratch="$(mktemp -d "${repo_root}/.build/zmk-firmware-test.XXXXXX")"
containers=()
cleanup() {
  local container
  for container in ${containers[@]+"${containers[@]}"}; do docker rm -f "${container}" >/dev/null 2>&1 || true; done
  rm -rf "${scratch}"
}
trap cleanup EXIT
build_case() {
  local name="$1" run
  shift
  bash build.sh "$@" | tee "${ZMK_TEST_RESULTS}/${name}.log"
  run="$(sed $'s/\033\[[0-9;]*m//g' "${ZMK_TEST_RESULTS}/${name}.log" | tail -n 1 | tr -d '\r')"
  bash .github/scripts/check-build-output.sh build "${run}"
  case "${name}" in
    standard)
      grep -qx 'Built targets: 8' "${run}/build-summary.txt"
      [ "$(find "${run}" -maxdepth 1 -name '*.uf2' | wc -l | tr -d '[:space:]')" = 8 ] ;;
    overlay|restore)
      grep -qx 'Built targets: 2' "${run}/build-summary.txt"
      test -f "${run}/ci_module_override_zmk_studio_messages.bin"
      test -f "${run}/ci_module_override_reset_hex.hex" ;;
  esac
  printf '%s\t%s\n' "${name}" "${run}" >> "${ZMK_TEST_RESULTS}/firmware-runs.tsv"
}
pristine=()
[ "${ZMK_TEST_PRISTINE:-0}" != 1 ] || pristine+=(--pristine)
build_case standard .github/fixtures/ci-zmk-config --jobs "${ZMK_BUILD_JOBS:-1}" ${pristine[@]+"${pristine[@]}"}
cache_reader="zmk-test-cache-$$"
# Record ownership only after create succeeds.
docker create --name "${cache_reader}" -v "${ZMK_DOCKER_CACHE_VOLUME}:/workspaces" \
  "${ZMK_BUILD_IMAGE:-zmkfirmware/zmk-build-arm:stable}" >/dev/null
containers+=("${cache_reader}")
# Use the same native host-path conversion as external clone.
source scripts/build-external-source.sh
host_scratch="$(docker_host_path "${scratch}")"
docker cp "${cache_reader}:/workspaces/zmk-config/modules/msgs/zmk-studio-messages" "${host_scratch}/"
docker cp "${cache_reader}:/workspaces/zmk-config/modules/lib/zcbor" "${host_scratch}/"
touch "${scratch}/zmk-studio-messages/.ci-local-override" "${scratch}/zcbor/.ci-local-override"
extra="${scratch}/zmk-feature-ci-extra"
mkdir -p "${extra}/zephyr" "${extra}/boards/shields/ci-extra" "${extra}/snippets/ci-extra"
printf 'name: zmk-feature-ci-extra\nbuild: {settings: {board_root: ., snippet_root: .}}\n' > "${extra}/zephyr/module.yml"
printf 'name: ci-extra\n' > "${extra}/snippets/ci-extra/snippet.yml"
overlay="zmk-test-overlay-$$"
containers+=("${overlay}")
ZMK_KEEP_CONTAINER=1 ZMK_CONTAINER_NAME="${overlay}" build_case overlay .github/fixtures/module-override-zmk-config \
  -m "${scratch}/zmk-studio-messages" -m "${scratch}/zcbor" -m "${extra}"
for pair in zmk-studio-messages:msgs zcbor:lib; do
  project="${pair%:*}"; parent="${pair#*:}"
  grep -F "Overlaying module input west project: ${project} -> modules/${parent}/${project}" "${ZMK_TEST_RESULTS}/overlay.log"
  docker exec "${overlay}" test -f "/workspaces/zmk-config/modules/${parent}/${project}/.ci-local-override"
done
grep -F 'Adding module input as extra module: zmk-feature-ci-extra' "${ZMK_TEST_RESULTS}/overlay.log"
restore="zmk-test-restore-$$"
containers+=("${restore}")
# Never pass --pristine: the previous workspace is the subject of this assertion.
ZMK_KEEP_CONTAINER=1 ZMK_CONTAINER_NAME="${restore}" build_case restore .github/fixtures/module-override-zmk-config
for pair in zmk-studio-messages:msgs zcbor:lib; do
  project="${pair%:*}"; parent="${pair#*:}"
  grep -F "Restoring previous module input overlay from backup: ${project} -> modules/${parent}/${project}" "${ZMK_TEST_RESULTS}/restore.log"
  docker exec "${restore}" test ! -e "/workspaces/zmk-config/modules/${parent}/${project}/.ci-local-override"
done
docker exec "${restore}" sh -c 'cd /workspaces/zmk-config; west list -f "{name} {revision} {path}"; west forall -c "git rev-parse HEAD"' \
  > "${ZMK_TEST_RESULTS}/dependencies.txt"
docker logs "${restore}" > "${ZMK_TEST_RESULTS}/container-build-stream.log" 2>&1
grep -F 'Build complete: 2 target(s).'  "${ZMK_TEST_RESULTS}/container-build-stream.log"
echo 'Firmware build/overlay/restore contracts passed.'
