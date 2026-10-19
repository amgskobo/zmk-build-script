#!/usr/bin/env bash
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
mode="${1:-docker}"
case "${mode}" in host|docker) ;; *) echo "usage: $0 host|docker" >&2; exit 2 ;; esac
tmp_parent="${repo_root}/.build"
mkdir -p "${tmp_parent}"
tmp_dir="$(mktemp -d "${tmp_parent}/zmk-build-tests.XXXXXX")"
tool_root="${tmp_dir}/tool-root"
fixture="${tool_root}/.github/fixtures/ci-zmk-config"
containers=()
last_container=""

cleanup() {
  local container
  for container in ${containers[@]+"${containers[@]}"}; do
    docker rm -f "${container}" >/dev/null 2>&1 || true
  done
  if [ -n "${ZMK_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "${ZMK_TEST_ARTIFACT_DIR}/runs"
    for log in "${tmp_dir}"/*.log "${tmp_dir}"/*.err; do
      [ ! -f "${log}" ] || cp "${log}" "${ZMK_TEST_ARTIFACT_DIR}/"
    done
    for run in "${tool_root}/.build"/run-*; do
      [ -d "${run}" ] || continue
      mkdir -p "${ZMK_TEST_ARTIFACT_DIR}/runs/${run##*/}"
      cp "${run}/build.log" "${run}/build-summary.txt" "${ZMK_TEST_ARTIFACT_DIR}/runs/${run##*/}/" 2>/dev/null || true
    done
  fi
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
  mkdir -p "${root}/src" "${root}/build" "${root}/.cache" "${root}/nested/build" "${root}/nested/.cache"
  printf 'keep\n' > "${root}/src/keep.txt"
  printf 'exclude root\n' > "${root}/build/root.txt"
  printf 'exclude root\n' > "${root}/.cache/root.txt"
  printf 'keep nested\n' > "${root}/nested/build/keep.txt"
  printf 'keep nested\n' > "${root}/nested/.cache/keep.txt"
}

add_generated_git_markers() {
  local root="$1" dir
  for dir in modules tools zmk bootloader optional; do
    mkdir -p "${root}/${dir}/.git"
  done
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

# run_validate SCENARIO TARGET [MODULE...]: one validate run, one container, any number of -m modules.
run_validate() {
  local scenario="$1" target="$2" log_path module
  shift 2
  local modules=()
  for module in "$@"; do modules+=(-m "${module}"); done
  local container="zmk-copy-excludes-${scenario}-$$"
  containers+=("${container}")
  last_container="${container}"
  log_path="${tmp_dir}/${scenario}.log"

  echo "[build-contract] ${scenario}"
  ZMK_COPY_IGNORED="${copy_ignored:-}" ZMK_CCACHE_DIR="${ccache_dir:-}" \
    ZMK_KEEP_CONTAINER=1 ZMK_CONTAINER_NAME="${container}" \
    bash "${tool_root}/build.sh" validate "${target}" --settings-reset ${modules[@]+"${modules[@]}"} >"${log_path}" 2>&1 ||
    { tail -n 120 "${log_path}" >&2; return 1; }
  local run
  run="$(sed $'s/\033\[[0-9;]*m//g' "${log_path}" | tail -n 1 | tr -d '\r')"
  bash "${repo_root}/.github/scripts/check-build-output.sh" validate "${run}"
}

run_validate_fail() {
  local scenario="$1" target="$2" expected="$3" module_arg="${4:-}" log_path
  local container="zmk-copy-excludes-${scenario}-$$"
  containers+=("${container}")
  log_path="${tmp_dir}/${scenario}.log"

  echo "[build-contract] ${scenario}"
  set +e
  if [ -n "${module_arg}" ]; then
    ZMK_KEEP_CONTAINER=1 ZMK_CONTAINER_NAME="${container}" \
      bash "${tool_root}/build.sh" validate "${target}" --settings-reset -m "${module_arg}" >"${log_path}" 2>&1
  else
    ZMK_KEEP_CONTAINER=1 ZMK_CONTAINER_NAME="${container}" \
      bash "${tool_root}/build.sh" validate "${target}" --settings-reset >"${log_path}" 2>&1
  fi
  status=$?
  set -e
  [ "${status}" -ne 0 ] || { echo "expected failure for ${scenario}" >&2; return 1; }
  grep -F "${expected}" "${log_path}" >/dev/null || { tail -n 120 "${log_path}" >&2; return 1; }
}

# One container query per payload, with explicit expectations for each independent boundary.
assert_payload() {
  local container="$1" base="$2" generated="$3" git_policy="${4:-none}"
  docker exec "${container}" /bin/bash -lc '
    set -eu
    base="$1"; generated="$2"; git_policy="$3"
    test -f "${base}/src/keep.txt"
    test ! -e "${base}/build" || { echo "root build was copied" >&2; exit 1; }
    test ! -e "${base}/.cache" || { echo "root .cache was copied" >&2; exit 1; }
    test -f "${base}/nested/build/keep.txt" || { echo "nested build was excluded" >&2; exit 1; }
    test -f "${base}/nested/.cache/keep.txt" || { echo "nested .cache was excluded" >&2; exit 1; }
    for dir in modules tools zmk bootloader optional; do
      if [ "$generated" = keep ]; then
        test -f "${base}/${dir}/generated.txt" || { echo "missing:${dir}" >&2; exit 1; }
      else
        test ! -e "${base}/${dir}" || { echo "present:${dir}" >&2; exit 1; }
      fi
    done
    [ "$git_policy" != none ] || exit 0
    test -f "${base}/visible.txt" || { echo "visible untracked file missing" >&2; exit 1; }
    test -f "${base}/artifacts/forced.txt" || { echo "tracked ignored file missing" >&2; exit 1; }
    test ! -e "${base}/gone.txt" || { echo "deleted tracked file present" >&2; exit 1; }
    for file in artifacts/run1/big.bin web/node_modules/pkg/index.js; do
      if [ "$git_policy" = all ]; then test -f "${base}/${file}";
      else test ! -e "${base}/${file}"; fi
    done
  ' _ "${base}" "${generated}" "${git_policy}"
}

# Native git.exe does not understand MSYS paths while path conversion is off, so run it from inside the directory.
git_in() {
  local root="$1"
  shift
  (cd "${root}" && git "$@")
}

# A Git working tree with ignored bulk (artifacts/, a nested node_modules/), an untracked file that is not ignored,
# a tracked file that an ignore rule also matches, and a tracked file that was deleted from the work tree.
add_git_ignore_payload() {
  local root="$1"
  git_in "${root}" init -q
  git_in "${root}" config core.autocrlf false
  printf 'artifacts/\nnode_modules/\n' > "${root}/.gitignore"
  mkdir -p "${root}/artifacts/run1" "${root}/web/node_modules/pkg"
  printf 'big\n' > "${root}/artifacts/run1/big.bin"
  printf 'dep\n' > "${root}/web/node_modules/pkg/index.js"
  printf 'visible\n' > "${root}/visible.txt"
  printf 'forced\n' > "${root}/artifacts/forced.txt"
  git_in "${root}" add -f artifacts/forced.txt
  printf 'gone\n' > "${root}/gone.txt"
  git_in "${root}" add gone.txt
  rm "${root}/gone.txt"
}

assert_env() {
  local container="$1" name="$2" expected="$3" actual
  actual="$(docker exec "${container}" printenv "${name}" | tr -d '\r' || true)"
  [ "${actual}" = "${expected}" ] || { echo "${name}: expected '${expected}', got '${actual}'" >&2; return 1; }
}

# The container must be able to use ccache: ZMK's compile commands carry -specs=picolibc.specs, which ccache looks up
# relative to the working directory, cannot find, and then refuses every compile ("bad compiler arguments"); and a
# cache inside a throw-away container would never survive the run. The cache therefore lives on the cache volume.
assert_ccache_works() {
  local container="$1" mounts
  assert_env "${container}" CCACHE_IGNOREOPTIONS '-specs=*'
  assert_env "${container}" CCACHE_DIR /workspaces/.ccache
  mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "${container}")"
  case " ${mounts}" in
    *" /workspaces "*) ;;
    *) echo "the cache volume is not mounted at /workspaces: ${mounts}" >&2; return 1 ;;
  esac
  docker exec "${container}" /bin/bash -lc '
    set -eu
    gcc="$(ls /opt/zephyr-sdk-*/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc | head -n 1)"
    export CCACHE_DIR="$(mktemp -d)"
    cd "$(mktemp -d)"
    printf "int f(int a) { return a + 1; }\n" > t.c
    for run in 1 2; do
      ccache "${gcc}" -mcpu=cortex-m4 -mthumb -specs=picolibc.specs -O2 -c t.c -o t.o
    done
    ccache -s | grep -Eq "Hits: +1 /" || { echo "second compile was not a cache hit" >&2; exit 1; }
  '
}

assert_absent() {
  local container="$1" path="$2"
  if docker exec "${container}" test -e "${path}"; then
    echo "unexpectedly present:${path}" >&2
    return 1
  fi
}

if [ "${mode}" = host ]; then
# Host setup/copy failures must retain both log and summary, including failures before validation starts.
# Reuse this fixture's tool root with a fake daemon so each failure costs no additional container.
fake_bin="${tmp_dir}/fake-bin"
mkdir -p "${fake_bin}"
cat > "${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  rm) exit 0 ;;
  create|start)
    if [ "$1" = "${FAKE_FAILURE}" ]; then
      echo "injected ${FAKE_FAILURE} failure" >&2
      exit 23
    fi
    exit 0
    ;;
  exec)
    case "$*" in
      *'tar --no-same-owner'*)
        cat >/dev/null
        echo "injected source copy failure" >&2
        exit 23
        ;;
      *'mkdir -p /root/zmk-config'*) exit 0 ;;
    esac
    echo "unexpected container execution" >&2
    exit 99
    ;;
esac
exit 99
EOF
chmod +x "${fake_bin}/docker"
# An unsupported host tar must fail before contacting Docker.
cat > "${fake_bin}/tar" <<'EOF'
#!/usr/bin/env sh
echo 'tar without exclude support'
exit 2
EOF
chmod +x "${fake_bin}/tar"
if PATH="${fake_bin}:${PATH}" bash "${tool_root}/build.sh" validate "${fixture}" >"${tmp_dir}/tar-preflight.log" 2>&1; then
  echo 'unsupported tar was accepted' >&2
  exit 1
fi
grep -q 'tar must support --exclude' "${tmp_dir}/tar-preflight.log"
rm "${fake_bin}/tar"
# A large help producer must not turn a supported tar into a false preflight failure.
# The old grep -q probe receives --exclude immediately and closes this pipe early.
real_tar="$(command -v tar)"
cat > "${fake_bin}/tar" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' --exclude
  awk 'BEGIN { for (i=0;i<100000;i++) print "large tar help payload" }'
else
  exec "${ZMK_TEST_REAL_TAR}" "$@"
fi
EOF
chmod +x "${fake_bin}/tar"

for phase in create start copy; do
  case "${phase}" in
    create) reason='container creation failed' ;;
    start) reason='container start failed' ;;
    copy) reason='source copy failed' ;;
  esac
  if ZMK_TEST_REAL_TAR="${real_tar}" PATH="${fake_bin}:${PATH}" FAKE_FAILURE="${phase}" \
      bash "${tool_root}/build.sh" validate "${fixture}" >"${tmp_dir}/host-${phase}.log" 2>&1; then
    echo "injected host ${phase} failure was accepted" >&2
    exit 1
  fi
  summary="$(find "${tool_root}/.build" -name build-summary.txt -print | sort | tail -n 1)"
  [ -n "${summary}" ] || { echo "host ${phase} failure lost its summary" >&2; exit 1; }
  grep -qx 'Status: FAILED' "${summary}"
  grep -qx "Reason: ${reason}" "${summary}"
  grep -q 'injected .* failure' "${summary%/*}/build.log"
  grep -q 'Failure excerpt' "${summary}"
done
rm "${fake_bin}/tar"

fake_bin="${tmp_dir}/fake-bin"
mkdir -p "${fake_bin}"
fake_bin="$(cd "${fake_bin}" && pwd -P)"
cat > "${fake_bin}/docker" <<'EOF'
#!/usr/bin/env sh
echo "fake docker reached" >&2
exit 42
EOF
chmod +x "${fake_bin}/docker"

compat_dir="${tmp_dir}/compat-zmk-config"
mkdir -p "${compat_dir}/config/boards"
touch "${compat_dir}/config/west.yml" "${compat_dir}/build.yaml"
if PATH="${fake_bin}:${PATH}" "${tool_root}/build.sh" validate "${compat_dir}" > "${tmp_dir}/compat.err" 2>&1; then
  :
fi
grep -q "fake docker reached" "${tmp_dir}/compat.err"
if grep -q "config/boards" "${tmp_dir}/compat.err"; then
  echo "ZMK config/boards compatibility path was not accepted" >&2
  exit 1
fi

snippet_dir="${tmp_dir}/snippet-zmk-config"
mkdir -p "${snippet_dir}/config" "${snippet_dir}/snippets/local-test"
touch "${snippet_dir}/config/west.yml" "${snippet_dir}/build.yaml"
printf 'name: local-test\n' > "${snippet_dir}/snippets/local-test/snippet.yml"
if PATH="${fake_bin}:${PATH}" "${tool_root}/build.sh" validate "${snippet_dir}" > "${tmp_dir}/snippet.err" 2>&1; then
  :
fi
grep -q "fake docker reached" "${tmp_dir}/snippet.err"
if grep -q "root snippet_root requires" "${tmp_dir}/snippet.err"; then
  echo "root snippets/ was rejected by the host-side target guard" >&2
  exit 1
fi

if "${tool_root}/build.sh" validate "${fixture}" -m "${tmp_dir}/missing-module" 2> "${tmp_dir}/module.err"; then
  echo "missing module input was accepted unexpectedly" >&2
  exit 1
fi
grep -q "module input directory not found" "${tmp_dir}/module.err"

# Invalid host inputs must stop before contacting the daemon.
for value in 0 00 -1 1.5 bad; do
  if PATH="${fake_bin}:${PATH}" bash "${tool_root}/build.sh" validate "${fixture}" --jobs "${value}" >"${tmp_dir}/jobs-${value}.log" 2>&1; then
    echo "invalid jobs accepted: ${value}" >&2; exit 1
  fi
  grep -q 'positive integer' "${tmp_dir}/jobs-${value}.log"
done
for value in .bin -bin '../bin' 'bad*'; do
  if ZMK_FALLBACK_BINARY="${value}" bash "${tool_root}/build.sh" validate "${fixture}" >"${tmp_dir}/extension.log" 2>&1; then
    echo "invalid fallback accepted: ${value}" >&2; exit 1
  fi
  grep -q 'invalid firmware extension' "${tmp_dir}/extension.log"
done
echo '[host-contract] passed'
  exit 0
fi

# Combine independent module and target inputs without repeating identical validation containers.
target_no_west="$(make_target target-no-west none)"
external_no_west="$(make_module external-no-west none)"
external_west="$(make_module external-west west)"
mkdir -p "${external_west}/zephyr" "${external_west}/boards"
touch "${external_west}/CMakeLists.txt"
printf 'build: {cmake: ., settings: {board_root: .}}\n' >"${external_west}/zephyr/module.yml"
run_validate whole-copy "${target_no_west}" "${external_no_west}" "${external_west}"
assert_payload "${last_container}" /root/zmk-config keep
assert_payload "${last_container}" /root/external_modules/external-no-west keep
assert_payload "${last_container}" /root/external_modules/external-west keep

target_west="$(make_target target-west west)"
mkdir -p "${target_west}/boards" "${target_west}/snippets" "${target_west}/dts"
touch "${target_west}/CMakeLists.txt" "${target_west}/Kconfig"
printf 'build: {cmake: .}\n' > "${target_west}/module.yml"
mkdir -p "${tool_root}/local_modules"
make_module ignored-local none "${tool_root}/local_modules" >/dev/null
run_validate west-without-markers "${target_west}"
assert_payload "${last_container}" /root/zmk-config keep
assert_absent "${last_container}" /root/local_modules
test ! -f "${target_west}/zephyr/module.yml"
grep -qx 'build: {cmake: .}' "${target_west}/module.yml"
rm -rf "${tool_root}/local_modules"

target_generated="$(make_target target-generated west)"
add_generated_git_markers "${target_generated}"
run_validate generated-dependencies "${target_generated}"
assert_payload "${last_container}" /root/zmk-config excluded

cmake_only="$(make_module cmake-only none)"
printf 'cmake_minimum_required(VERSION 3.20.0)\n' >"${cmake_only}/CMakeLists.txt"
run_validate_fail cmake-only-module "${target_west}" 'module input cmake-only: root module content requires zephyr/module.yml' "${cmake_only}"

# Git ignore rules: files a Git working tree ignores are not copied; untracked files that are not ignored and tracked
# files are; an opt-out copies everything; a tree whose rules ignore every file falls back to a full copy.
target_git="$(make_target target-git none)"
add_git_ignore_payload "${target_git}"
module_git="$(make_module external-git none)"
add_git_ignore_payload "${module_git}"
module_all_ignored="$(make_module external-all-ignored none)"
git_in "${module_all_ignored}" init -q
printf '*\n' > "${module_all_ignored}/.gitignore"

# One container: a Git target, a Git module and a module whose rules ignore everything (full copy). The same
# container carries the default ccache environment.
# BSD tar's short help does not list --null even though it supports NUL-separated lists.
# Hide that option on every host so GNU tar also catches a regression to help-text detection.
tar_bin="${tmp_dir}/tar-bin"
mkdir -p "${tar_bin}"
cat > "${tar_bin}/tar" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  "${ZMK_TEST_REAL_TAR}" --help | sed '/--null/d'
else
  exec "${ZMK_TEST_REAL_TAR}" "$@"
fi
EOF
chmod +x "${tar_bin}/tar"
ZMK_TEST_REAL_TAR="$(command -v tar)" PATH="${tar_bin}:${PATH}" \
  run_validate git-ignore "${target_git}" "${module_git}" "${module_all_ignored}"
rm "${tar_bin}/tar"
assert_payload "${last_container}" /root/zmk-config keep visible
assert_payload "${last_container}" /root/external_modules/external-git keep visible
assert_payload "${last_container}" /root/external_modules/external-all-ignored keep
assert_ccache_works "${last_container}"

# One container: both opt-outs.
copy_ignored=1
ccache_dir=/workspaces/elsewhere
run_validate git-opt-outs "${target_git}"
assert_payload "${last_container}" /root/zmk-config keep all
assert_env "${last_container}" CCACHE_DIR /workspaces/elsewhere
copy_ignored=
ccache_dir=

# Exercise parser/schema cases inside the existing validate container; no extra build container.
docker exec -i "${last_container}" sh -c 'cat > /tmp/test-build-container.py' < "${repo_root}/.github/scripts/test-build-container.py"
docker exec -i "${last_container}" sh -c 'cat > /tmp/target-shapes.yaml' < "${repo_root}/.github/fixtures/target-shapes-zmk-config/build.yaml"
docker exec -i "${last_container}" sh -c 'cat > /tmp/source-common.sh' < "${repo_root}/scripts/source-common.sh"
docker exec "${last_container}" python3 /tmp/test-build-container.py /tmp/target-shapes.yaml

# Round-trip the actual pruned Linux tree through the same host-path helper as external clone.
(
  source "${repo_root}/scripts/build-external-source.sh"
  mkdir -p "${tmp_dir}/clone-copy"
  docker_no_pathconv cp "${last_container}:/tmp/windows-copy/." "$(docker_host_path "${tmp_dir}/clone-copy")"
)
[ "$(find "${tmp_dir}/clone-copy" -type f | wc -l | tr -d '[:space:]')" = 7 ]
for file in keep.txt 'nested/valid name.txt' nested/COM0.txt nested/my..file.txt unicode-名前.txt $'DEL-\177.txt' COM⁴.txt; do
  cmp "${tmp_dir}/clone-copy/${file}" <(printf 'clone payload\n')
done
echo "build host/copy contracts passed."
