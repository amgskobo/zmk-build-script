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
container_logs=()
last_container=""

cleanup() {
  local container log
  # Docker create writes its immutable ID to stdout. A name collision writes no ID.
  # Read only logs registered for our validate calls, including calls that later fail.
  for log in ${container_logs[@]+"${container_logs[@]}"}; do
    [ -f "${log}" ] || continue
    container="$(tr -d '\r' < "${log}" | awk 'length($0) == 64 && $0 !~ /[^0-9a-f]/ && !found {print; found=1}')"
    [ -z "${container}" ] || docker rm -f "${container}" >/dev/null 2>&1 || true
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
  log_path="${tmp_dir}/${scenario}.log"
  container_logs+=("${log_path}")

  echo "[build-contract] ${scenario}"
  ZMK_WEST_UPDATE_ATTEMPTS=2 ZMK_COPY_IGNORED="${copy_ignored:-}" ZMK_CCACHE_DIR="${ccache_dir:-}" \
    ZMK_KEEP_CONTAINER=1 ZMK_CONTAINER_NAME="${container}" \
    bash "${tool_root}/build.sh" validate "${target}" --settings-reset ${modules[@]+"${modules[@]}"} >"${log_path}" 2>&1 ||
    { tail -n 120 "${log_path}" >&2; return 1; }
  local run
  run="$(sed $'s/\033\[[0-9;]*m//g' "${log_path}" | tail -n 1 | tr -d '\r')"
  bash "${repo_root}/.github/scripts/check-build-output.sh" validate "${run}"
  last_container="$(tr -d '\r' < "${log_path}" | awk 'length($0) == 64 && $0 !~ /[^0-9a-f]/ && !found {print; found=1}')"
  [ -n "${last_container}" ] || { echo 'validate did not return a container ID' >&2; return 1; }
}

run_validate_fail() {
  local scenario="$1" target="$2" expected="$3" module_arg="${4:-}" log_path
  local container="zmk-copy-excludes-${scenario}-$$"
  log_path="${tmp_dir}/${scenario}.log"
  container_logs+=("${log_path}")

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
    [ "$1" != create ] || printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
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

create_tmp="${tmp_dir}/create-temporaries"
mkdir -p "${create_tmp}"
# Another run may sort after this invocation even when its PID is unrelated.
foreign_run="${tool_root}/.build/run-9999-12-31_23-59-59-pid-1"
mkdir -p "${foreign_run}"
printf 'Status: FAILED\nReason: unrelated summary sentinel\n' > "${foreign_run}/build-summary.txt"
for phase in create start copy; do
  case "${phase}" in
    create) reason='container creation failed' ;;
    start) reason='container start failed' ;;
    copy) reason='source copy failed' ;;
  esac
  TMPDIR="${create_tmp}" ZMK_TEST_REAL_TAR="${real_tar}" PATH="${fake_bin}:${PATH}" FAKE_FAILURE="${phase}" \
      bash "${tool_root}/build.sh" validate "${fixture}" >"${tmp_dir}/host-${phase}.log" 2>&1 &
  build_pid=$!
  if wait "${build_pid}"; then
    echo "injected host ${phase} failure was accepted" >&2
    exit 1
  fi
  summary="$(find "${tool_root}/.build" -path "*-pid-${build_pid}/build-summary.txt" -print)"
  [ -n "${summary}" ] || { echo "host ${phase} failure lost its summary" >&2; exit 1; }
  grep -qx 'Status: FAILED' "${summary}"
  grep -qx "Reason: ${reason}" "${summary}"
  grep -q 'injected .* failure' "${summary%/*}/build.log"
  grep -q 'Failure excerpt' "${summary}"
  [ "$(find "${create_tmp}" -type f | wc -l | tr -d '[:space:]')" = 0 ]
done
rm "${fake_bin}/tar"

# Every operation after create must retain the returned identity if a name is reused.
# This daemon model deliberately accepts either address; assertions inspect the calls.
identity_failed=0
cat > "${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${IDENTITY_COMMANDS}"
case "$1" in
  create) printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  start)
    [ "${IDENTITY_PHASE}" != start ] || { echo 'injected start failure' >&2; exit 23; } ;;
  exec)
    case "$*" in
      *'tar -C /root/zmk-config/.build'*) echo 'injected artifact failure' >&2; exit 23 ;;
      *'tar --no-same-owner'*)
        cat >/dev/null
        [ "${IDENTITY_PHASE}" != copy ] || { echo 'injected copy failure' >&2; exit 23; } ;;
      *'cat > /root/zmk-config/build.sh'*) cat >/dev/null ;;
      *'./build.sh validate'*) echo "injected ${IDENTITY_PHASE} failure" >&2; exit 23 ;;
      *'./build.sh build'*) echo 'Build complete: 1 target(s).' ;;
      *'mkdir -p /root/zmk-config'*) ;;
      *) exit 99 ;;
    esac ;;
  rm) ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${fake_bin}/docker"
dot_module="$(make_module dot-module none)"
for phase in start copy validate artifact module; do
  commands="${tmp_dir}/identity-${phase}.commands.log"
  invocation=(validate "${fixture}")
  [ "${phase}" != artifact ] || invocation=("${fixture}")
  [ "${phase}" != module ] || invocation=(validate "${fixture}" -m "${dot_module}/.")
  PATH="${fake_bin}:${PATH}" IDENTITY_PHASE="${phase}" IDENTITY_COMMANDS="${commands}" \
      ZMK_CONTAINER_NAME=replaceable-test-name bash "${tool_root}/build.sh" "${invocation[@]}" \
      >"${tmp_dir}/identity-${phase}.log" 2>&1 &
  build_pid=$!
  if wait "${build_pid}"; then
    echo "injected identity ${phase} failure was accepted" >&2; identity_failed=1
  fi
  if ! grep -qx 'rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${commands}"; then
    echo "identity ${phase}: cleanup addressed a replaceable container name" >&2; identity_failed=1
  fi
  if grep -v '^create ' "${commands}" | grep -q 'replaceable-test-name'; then
    echo "identity ${phase}: an operation addressed a replaceable container name" >&2; identity_failed=1
  fi
  grep -q "injected ${phase} failure" "${tmp_dir}/identity-${phase}.log"
  if [ "${phase}" = module ]; then
    if ! grep '/root/external_modules' "${commands}" | grep -q '_ dot-module$'; then
      echo 'module path ending in /. was copied under the wrong name' >&2; identity_failed=1
    fi
  fi
  case "${phase}" in
    start) reason='container start failed' ;;
    copy) reason='source copy failed' ;;
    validate|module) reason='validation failed' ;;
    artifact) reason='artifact copy failed' ;;
  esac
  summary="$(find "${tool_root}/.build" -path "*-pid-${build_pid}/build-summary.txt" -print)"
  grep -qx 'Status: FAILED' "${summary}"
  grep -qx "Reason: ${reason}" "${summary}"
done
grep -qx 'Reason: unrelated summary sentinel' "${foreign_run}/build-summary.txt"

# Cleanup/reset failures must fail the run without changing a prior failure or ownership.
lifecycle_failed=0
cat > "${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LIFECYCLE_COMMANDS}"
case "$1" in
  volume)
    case "$2" in
      ls)
        printf '%s\n' "${ZMK_DOCKER_CACHE_VOLUME}-other"
        if [ "${LIFECYCLE_PHASE}" = present-crlf ]; then
          printf '%s\r\n' "${ZMK_DOCKER_CACHE_VOLUME}"
        elif [ "${LIFECYCLE_PHASE}" != missing ]; then
          printf '%s\n' "${ZMK_DOCKER_CACHE_VOLUME}"
        fi
        [ "${LIFECYCLE_PHASE}" != list-failure ] || { echo 'injected partial volume list failure' >&2; exit 23; } ;;
      rm)
        [ "${LIFECYCLE_PHASE}" != reset-failure ] || { echo 'injected cache reset failure' >&2; exit 23; } ;;
      *) exit 99 ;;
    esac ;;
  create)
    [ "${LIFECYCLE_PHASE}" != create-failure ] || { echo 'injected create failure' >&2; exit 23; }
    printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  start)
    [ "${LIFECYCLE_PHASE}" != both-failures ] || { echo 'injected start failure' >&2; exit 23; } ;;
  exec)
    case "$*" in
      *'tar --no-same-owner'*|*'cat > /root/zmk-config/build.sh'*) cat >/dev/null ;;
      *'./build.sh validate'*) echo 'build.yaml is valid.' ;;
      *'mkdir -p /root/zmk-config'*) ;;
      *) exit 99 ;;
    esac ;;
  rm)
    case "${LIFECYCLE_PHASE}" in
      cleanup-failure|both-failures|keep) echo 'injected container cleanup failure' >&2; exit 23 ;;
    esac ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${fake_bin}/docker"
for phase in cleanup-failure both-failures keep reset-failure list-failure missing present present-crlf create-failure; do
  commands="${tmp_dir}/lifecycle-${phase}.commands.log"
  : > "${commands}"
  invocation=(validate "${fixture}")
  expected=0 keep=0 reason=
  case "${phase}" in
    cleanup-failure) expected=1; reason='container cleanup failed' ;;
    both-failures) expected=23; reason='container start failed' ;;
    keep) keep=1 ;;
    reset-failure|list-failure) expected=1; reason='cache reset failed'; invocation+=(--pristine) ;;
    missing|present|present-crlf) invocation+=(--pristine) ;;
    create-failure) expected=23; reason='container creation failed' ;;
  esac
  PATH="${fake_bin}:${PATH}" LIFECYCLE_PHASE="${phase}" LIFECYCLE_COMMANDS="${commands}" \
      ZMK_KEEP_CONTAINER="${keep}" ZMK_DOCKER_CACHE_VOLUME=lifecycle-cache ZMK_CONTAINER_NAME=replaceable-test-name \
      bash "${tool_root}/build.sh" "${invocation[@]}" >"${tmp_dir}/lifecycle-${phase}.log" 2>&1 &
  build_pid=$!
  if wait "${build_pid}"; then
    status=0
  else
    status=$?
  fi
  if [ "${status}" != "${expected}" ]; then
    echo "lifecycle ${phase}: expected status ${expected}, got ${status}" >&2; lifecycle_failed=1
  fi
  summary="$(find "${tool_root}/.build" -path "*-pid-${build_pid}/build-summary.txt" -print)"
  if [ ! -f "${summary}" ]; then
    echo "lifecycle ${phase}: missing run summary for PID ${build_pid}" >&2; lifecycle_failed=1; continue
  fi
  if [ "${expected}" = 0 ]; then
    if ! bash "${repo_root}/.github/scripts/check-build-output.sh" validate "${summary%/*}" \
        >"${tmp_dir}/lifecycle-${phase}.checker.log" 2>&1; then lifecycle_failed=1; fi
  elif ! grep -qx 'Status: FAILED' "${summary}" || ! grep -qx "Reason: ${reason}" "${summary}"; then
    echo "lifecycle ${phase}: missing FAILED summary or original reason" >&2; lifecycle_failed=1
  fi
  case "${phase}" in
    cleanup-failure|both-failures)
      if ! grep -q 'injected container cleanup failure' "${summary%/*}/build.log" ||
          ! grep -q 'failed to remove build container' "${summary}"; then
        echo "lifecycle ${phase}: cleanup diagnostics lost" >&2; lifecycle_failed=1
      fi ;;
    reset-failure|list-failure)
      if grep -q '^create ' "${commands}" || ! grep -q 'injected .* failure' "${summary%/*}/build.log"; then
        echo "lifecycle ${phase}: build started after reset failure or diagnostics lost" >&2; lifecycle_failed=1
      fi ;;
  esac
  if [ "${phase}" = keep ] || [ "${phase}" = create-failure ]; then
    if grep -q '^rm ' "${commands}"; then
      echo "lifecycle ${phase}: removed a kept or unowned container" >&2; lifecycle_failed=1
    fi
  elif [ "${phase}" != reset-failure ] && [ "${phase}" != list-failure ]; then
    if ! grep -qx 'rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${commands}"; then lifecycle_failed=1; fi
  fi
  case "${phase}" in
    missing|list-failure)
      if grep -q '^volume rm ' "${commands}"; then
        echo "lifecycle ${phase}: removed an absent or unverified volume" >&2; lifecycle_failed=1
      fi ;;
    present|present-crlf|reset-failure)
      if ! grep -qx 'volume rm lifecycle-cache' "${commands}"; then lifecycle_failed=1; fi ;;
  esac
done

# SIGTERM must finalize failure evidence and retain ownership in both modes.
cat > "${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SIGNAL_COMMANDS}"
block_signal_phase() {
  : > "${SIGNAL_REACHED}"
  for attempt in $(seq 1 100); do
    [ ! -f "${SIGNAL_RELEASE}" ] || return 0
    sleep .1
  done
  return 23
}
case "$1" in
  create)
    [ "${SIGNAL_PHASE}" != create ] || block_signal_phase || exit "$?"
    printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  start) ;;
  exec)
    case "$*" in
      *'tar --no-same-owner'*|*'cat > /root/zmk-config/build.sh'*) cat >/dev/null ;;
      *'./build.sh validate'*|*'./build.sh build'*)
        block_signal_phase ;;
      *'mkdir -p /root/zmk-config'*) ;;
      *) exit 99 ;;
    esac ;;
  rm|stop) : > "${SIGNAL_RELEASE}" ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${fake_bin}/docker"
for signal_mode in build validate; do
  for keep in 0 1; do
   for signal_phase in create execute; do
    signal_prefix="${tmp_dir}/signal-${signal_mode}-${keep}-${signal_phase}"
    invocation=("${fixture}")
    [ "${signal_mode}" != validate ] || invocation=(validate "${fixture}")
    PATH="${fake_bin}:${PATH}" SIGNAL_COMMANDS="${signal_prefix}.commands.log" \
      SIGNAL_REACHED="${signal_prefix}.reached" SIGNAL_RELEASE="${signal_prefix}.release" \
      SIGNAL_PHASE="${signal_phase}" \
      ZMK_KEEP_CONTAINER="${keep}" bash "${tool_root}/build.sh" "${invocation[@]}" \
      >"${signal_prefix}.log" 2>&1 &
    build_pid=$!
    for attempt in $(seq 1 100); do
      [ ! -f "${signal_prefix}.reached" ] || break
      sleep .1
    done
    [ -f "${signal_prefix}.reached" ] || { kill -TERM "${build_pid}" 2>/dev/null || true; exit 1; }
    kill -TERM "${build_pid}"
    if [ "${signal_phase}" = create ]; then
      sleep .1
      : > "${signal_prefix}.release"
    fi
    if wait "${build_pid}"; then status=0; else status=$?; fi
    : > "${signal_prefix}.release"
    [ "${status}" = 143 ] || { echo 'SIGTERM exit status lost' >&2; exit 1; }
    summary="$(find "${tool_root}/.build" -path "*-pid-${build_pid}/build-summary.txt" -print)"
    grep -qx 'Status: FAILED' "${summary}"
    grep -qx 'Reason: interrupted by SIGTERM' "${summary}"
    if [ "${keep}" = 1 ]; then
      if [ "${signal_phase}" = execute ]; then
        grep -qx 'stop -t 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${signal_prefix}.commands.log"
      fi
      if grep -q '^rm ' "${signal_prefix}.commands.log"; then exit 1; fi
    else
      grep -qx 'rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${signal_prefix}.commands.log"
    fi
    if [ "${signal_phase}" = create ] && grep -q '^start ' "${signal_prefix}.commands.log"; then exit 1; fi
   done
  done
done

fake_bin="${tmp_dir}/fake-bin"
mkdir -p "${fake_bin}"
fake_bin="$(cd "${fake_bin}" && pwd -P)"
cat > "${fake_bin}/docker" <<'EOF'
#!/usr/bin/env sh
echo "fake docker reached" >&2
exit 42
EOF
chmod +x "${fake_bin}/docker"

# Distinct basenames remain distinct even when one includes the other's name as a word.
module_names_failed=0
spaced="$(make_module 'alpha beta' none)"
short="$(make_module beta none)"
for order in forward reverse; do
  module_args=(-m "${spaced}" -m "${short}")
  [ "${order}" != reverse ] || module_args=(-m "${short}" -m "${spaced}")
  if PATH="${fake_bin}:${PATH}" bash "${tool_root}/build.sh" validate "${fixture}" "${module_args[@]}" \
      >"${tmp_dir}/module-names-${order}.log" 2>&1; then :; fi
  if ! grep -q 'fake docker reached' "${tmp_dir}/module-names-${order}.log"; then
    echo "distinct module names were rejected: ${order}" >&2; module_names_failed=1
  fi
done
same="$(make_module beta none "${tmp_dir}/other-parent")"
if PATH="${fake_bin}:${PATH}" bash "${tool_root}/build.sh" validate "${fixture}" -m "${short}" -m "${same}" \
    >"${tmp_dir}/module-names-duplicate.log" 2>&1; then
  echo 'duplicate module basename was accepted' >&2; module_names_failed=1
fi
grep -q 'duplicate module input name: beta' "${tmp_dir}/module-names-duplicate.log"
if grep -q 'fake docker reached' "${tmp_dir}/module-names-duplicate.log"; then
  echo 'duplicate module basename reached Docker' >&2; module_names_failed=1
fi

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
  if PATH="${fake_bin}:${PATH}" ZMK_WEST_UPDATE_ATTEMPTS="${value}" \
      bash "${tool_root}/build.sh" validate "${fixture}" >"${tmp_dir}/attempts-${value}.log" 2>&1; then
    echo "invalid update attempts accepted: ${value}" >&2; exit 1
  fi
  grep -q 'ZMK_WEST_UPDATE_ATTEMPTS must be a positive integer' "${tmp_dir}/attempts-${value}.log"
done
for value in .bin -bin '../bin' 'bad*'; do
  if ZMK_FALLBACK_BINARY="${value}" bash "${tool_root}/build.sh" validate "${fixture}" >"${tmp_dir}/extension.log" 2>&1; then
    echo "invalid fallback accepted: ${value}" >&2; exit 1
  fi
  grep -q 'invalid firmware extension' "${tmp_dir}/extension.log"
done
# The harness must also respect ownership when its first validate cannot start.
# A failed create owns nothing; a later start failure still owns the returned ID.
cat > "${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HARNESS_DOCKER_LOG}"
case "$1" in
  create)
    if [ "${HARNESS_FAILURE}" = create ]; then
      echo 'injected existing-name collision' >&2; exit 23
    fi
    printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  start)
    [ "${HARNESS_FAILURE}" != start ] || { echo 'injected start failure' >&2; exit 23; } ;;
  exec)
    case "$*" in
      *'mkdir -p /root/zmk-config'*) ;;
      *'tar --no-same-owner'*|*'cat > /root/zmk-config/build.sh'*) cat >/dev/null ;;
      *'./build.sh validate'*) echo 'build.yaml is valid.' ;;
      *) echo 'injected payload query failure' >&2; exit 23 ;;
    esac ;;
  rm) exit 0 ;;
  *) echo 'unexpected fake daemon call' >&2; exit 99 ;;
esac
EOF
chmod +x "${fake_bin}/docker"
for phase in create start probe; do
  commands="${tmp_dir}/harness-${phase}-commands.log"
  : > "${commands}"
  if PATH="${fake_bin}:${PATH}" HARNESS_FAILURE="${phase}" HARNESS_DOCKER_LOG="${commands}" \
      ZMK_TEST_ARTIFACT_DIR="${ZMK_TEST_ARTIFACT_DIR:-${tmp_dir}}/harness-${phase}" \
      bash "${repo_root}/.github/scripts/test-build.sh" docker >"${tmp_dir}/harness-${phase}.log" 2>&1; then
    echo "harness accepted injected ${phase} failure" >&2; exit 1
  fi
  grep -q '^create ' "${commands}"
  if [ "${phase}" = create ]; then
    grep -q 'injected existing-name collision' "${tmp_dir}/harness-${phase}.log"
    if grep -q '^rm ' "${commands}"; then
      echo 'harness removed a container it did not create' >&2; exit 1
    fi
  else
    if [ "${phase}" = start ]; then
      grep -q 'injected start failure' "${tmp_dir}/harness-${phase}.log"
    else
      grep -q 'injected payload query failure' "${tmp_dir}/harness-${phase}.log"
      if grep -v '^create ' "${commands}" | grep -q 'zmk-copy-excludes-'; then
        echo 'harness queried a replaceable container name' >&2; exit 1
      fi
    fi
    grep -qx 'rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${commands}"
  fi
done

# Exercise large artifact streams and finalization with the same fake-daemon boundary.
finalization_failed=0
cat > "${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${NEW_PHASE}" = cleanup-entry ] && [ "$1" = rm ]; then
  : > "${NEW_REACHED}"
  while [ ! -f "${NEW_RELEASE}" ]; do sleep .01; done
fi
printf '%s\n' "$*" >> "${NEW_CALLS}"
case "$1" in
  create)
    if [ "${NEW_CRLF:-0}" = 1 ]; then printf '%s\r\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    else printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi ;;
  start) [ "${NEW_INITIAL_FAILURE:-0}" != 1 ] || exit 23 ;;
  exec)
    case "$*" in
      *'tar -C /root/zmk-config/.build'*) tar -C "${NEW_PAYLOAD}" -cf - . ;;
      *'tar --no-same-owner'*|*'cat > /root/zmk-config/build.sh'*) cat >/dev/null ;;
      *'./build.sh validate'*) echo 'build.yaml is valid.' ;;
      *'./build.sh build'*) printf 'Build complete: %s target(s).\n' "${NEW_COUNT}" ;;
      *'mkdir -p /root/zmk-config'*) ;;
      *) exit 99 ;;
    esac ;;
  rm)
    if [ "${NEW_PHASE}" = cleanup-rm ]; then
      : > "${NEW_REACHED}"
      while [ ! -f "${NEW_RELEASE}" ]; do sleep .01; done
    fi
    [ -z "${NEW_COMPLETE:-}" ] || : > "${NEW_COMPLETE}" ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${fake_bin}/docker"
for count in 1 512; do
  payload="${tmp_dir}/firmware-${count}"
  mkdir -p "${payload}"
  padding=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  for number in $(seq 1 "${count}"); do
    printf 'synthetic firmware\n' > "${payload}/target-${number}-${padding}.bin"
  done
  PATH="${fake_bin}:${PATH}" NEW_PHASE=artifacts NEW_COUNT="${count}" NEW_PAYLOAD="${payload}" \
      NEW_CALLS="${tmp_dir}/firmware-${count}.commands.log" \
      bash "${tool_root}/build.sh" "${fixture}" >"${tmp_dir}/firmware-${count}.log" 2>&1 &
  build_pid=$!
  if wait "${build_pid}"; then status=0; else status=$?; fi
  summary="$(find "${tool_root}/.build" -path "*-pid-${build_pid}/build-summary.txt" -print)"
  if [ "${status}" != 0 ] || ! grep -qx 'Status: SUCCESS' "${summary}" ||
      [ "$(grep -c '^- target-' "${summary}")" != "${count}" ]; then
    echo "artifact stream ${count}: successful firmware collection was rejected or omitted" >&2
    finalization_failed=1
  else
    bash "${repo_root}/.github/scripts/check-build-output.sh" build "${summary%/*}"
  fi
done

# A failing external receipt filter must not lose ownership after a successful create.
real_tr="$(command -v tr)"
cat > "${fake_bin}/tr" <<'EOF'
#!/usr/bin/env bash
input="$(mktemp)"
trap 'rm -f "${input}"' EXIT
cat > "${input}"
receipt="$(cat "${input}")"; receipt="${receipt%$'\r'}"
if [ "${receipt}" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]; then
  echo 'injected receipt filter failure' >&2; exit 23
fi
"${NEW_REAL_TR}" "$@" < "${input}"
EOF
chmod +x "${fake_bin}/tr"
for crlf in 0 1; do
  calls="${tmp_dir}/receipt-${crlf}.commands.log"
  if PATH="${fake_bin}:${PATH}" NEW_REAL_TR="${real_tr}" NEW_PHASE=receipt NEW_CRLF="${crlf}" NEW_CALLS="${calls}" \
      bash "${tool_root}/build.sh" validate "${fixture}" >"${tmp_dir}/receipt-${crlf}.log" 2>&1; then
    status=0
  else status=$?; fi
  if [ "${status}" != 0 ] || ! grep -qx 'rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${calls}"; then
    echo 'receipt parsing lost the created container identity' >&2; finalization_failed=1
  fi
done
rm "${fake_bin}/tr"

# Pause before the daemon mutation and while its client is in flight.
for phase in cleanup-entry cleanup-rm; do
  for initial_failure in 0 1; do
    prefix="${tmp_dir}/finalize-${phase}-${initial_failure}"
    PATH="${fake_bin}:${PATH}" NEW_PHASE="${phase}" \
        NEW_INITIAL_FAILURE="${initial_failure}" NEW_CALLS="${prefix}.commands.log" \
        NEW_REACHED="${prefix}.reached" NEW_RELEASE="${prefix}.release" NEW_COMPLETE="${prefix}.complete" \
        bash "${tool_root}/build.sh" validate "${fixture}" >"${prefix}.log" 2>&1 &
    build_pid=$!
    for attempt in $(seq 1 100); do [ ! -f "${prefix}.reached" ] || break; sleep .05; done
    [ -f "${prefix}.reached" ] || { kill -TERM "${build_pid}" 2>/dev/null || true; exit 1; }
    kill -TERM "${build_pid}"
    : > "${prefix}.release"
    if wait "${build_pid}"; then status=0; else status=$?; fi
    summary="$(find "${tool_root}/.build" -path "*-pid-${build_pid}/build-summary.txt" -print)"
    expected=143 reason='interrupted by SIGTERM'
    [ "${initial_failure}" != 1 ] || { expected=23; reason='container start failed'; }
    if [ "${status}" != "${expected}" ] || [ ! -f "${prefix}.complete" ] ||
        ! grep -qx 'Status: FAILED' "${summary}" || ! grep -qx "Reason: ${reason}" "${summary}"; then
      echo "finalization ${phase}/${initial_failure}: cleanup, status or final summary lost" >&2
      finalization_failed=1
    fi
    if bash "${repo_root}/.github/scripts/check-build-output.sh" validate "${summary%/*}" >/dev/null 2>&1; then
      echo 'interrupted finalization passed the output checker' >&2; finalization_failed=1
    fi
  done
done
[ "${finalization_failed}" = 0 ] || exit 1

# Visible evidence would checksum itself and turn log writes into false source drift.
runner_fixture="${tmp_dir}/runner-fixture"
mkdir -p "${runner_fixture}/.github/scripts"
cp "${repo_root}/.github/scripts/test.sh" "${runner_fixture}/.github/scripts/test.sh"
git_in "${runner_fixture}" init -q
if (cd "${runner_fixture}"; ZMK_TEST_RESULTS=visible-results bash .github/scripts/test.sh shell) \
    >"${tmp_dir}/visible-results.log" 2>&1; then
  echo 'visible in-tree evidence was accepted' >&2; exit 1
fi
grep -q 'inside the repository must be Git-ignored' "${tmp_dir}/visible-results.log"
[ ! -d "${runner_fixture}/visible-results" ]
[ "${identity_failed}" = 0 ] && [ "${module_names_failed}" = 0 ] && [ "${lifecycle_failed}" = 0 ] || exit 1
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
spaced_module="$(make_module 'alpha beta' none)"
short_module="$(make_module beta none)"
dot_module="$(make_module dot-module none)"
run_validate whole-copy "${target_no_west}" "${external_no_west}" "${external_west}" "${spaced_module}" "${short_module}" "${dot_module}/."
assert_payload "${last_container}" '/root/external_modules/alpha beta' keep
assert_payload "${last_container}" /root/external_modules/beta keep
assert_payload "${last_container}" /root/external_modules/dot-module keep
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

# Stage the complete contract input set once in the existing validation container.
(cd "${repo_root}" && tar cf - .github/scripts/test-build-container.py \
  .github/fixtures/target-shapes-zmk-config/build.yaml scripts/source-common.sh \
  scripts/auto-build-external.sh .github/scripts/check-build-output.sh .github/workflows/*.yml) |
  docker exec -i "${last_container}" bash -c '
    set -eu
    mkdir -p /tmp/contract-inputs /tmp/workflows
    tar xf - -C /tmp/contract-inputs
    cp /tmp/contract-inputs/.github/scripts/test-build-container.py /tmp/
    cp /tmp/contract-inputs/.github/fixtures/target-shapes-zmk-config/build.yaml /tmp/target-shapes.yaml
    cp /tmp/contract-inputs/scripts/*.sh /tmp/
    cp /tmp/contract-inputs/.github/scripts/check-build-output.sh /tmp/
    cp /tmp/contract-inputs/.github/workflows/*.yml /tmp/workflows/
    cp /tmp/workflows/auto-build.yml /tmp/
    exec python3 -u /tmp/test-build-container.py /tmp/target-shapes.yaml'

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
# Use the existing validate container as the holder; never reset a production cache.
: "${ZMK_DOCKER_CACHE_VOLUME:?Run Docker contracts through test.sh}"
docker inspect -f '{{range .Mounts}}{{println .Name}}{{end}}' "${last_container}" |
  grep -Fxq "${ZMK_DOCKER_CACHE_VOLUME}"
ZMK_KEEP_CONTAINER=0 bash "${tool_root}/build.sh" validate "${target_no_west}" --pristine \
  >"${tmp_dir}/pristine-in-use.log" 2>&1 &
pristine_pid=$!
if wait "${pristine_pid}"; then
  echo 'pristine continued with an in-use cache volume' >&2; exit 1
fi
summary="$(find "${tool_root}/.build" -path "*-pid-${pristine_pid}/build-summary.txt" -print)"
grep -qx 'Status: FAILED' "${summary}"
grep -qx 'Reason: cache reset failed' "${summary}"
grep -q 'volume is in use' "${summary%/*}/build.log"
[ "$(docker inspect -f '{{.State.Running}}' "${last_container}")" = true ]
docker volume inspect "${ZMK_DOCKER_CACHE_VOLUME}" >/dev/null

echo "build host/copy contracts passed."
