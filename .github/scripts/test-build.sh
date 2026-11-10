#!/usr/bin/env bash
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"
# Lifecycle/copy cases select their image explicitly; automatic selection has its
# own real-parser cases in the container suite.
export ZMK_BUILD_IMAGE="${ZMK_BUILD_IMAGE:-zmkfirmware/zmk-build-arm:stable}"

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
test_failure_line=""
test_current_line=0
test_previous_line=0

remember_host_failure() {
  [ -n "${test_failure_line}" ] || test_failure_line="$1"
}

cleanup() {
  local container log stream file failure_status="$1" failure_line="$2"
  # Docker create writes its immutable ID to stdout. A name collision writes no ID.
  # Read only logs registered for our validate calls, including calls that later fail.
  for log in ${container_logs[@]+"${container_logs[@]}"}; do
    [ -f "${log}" ] || continue
    container="$(awk '{gsub(/\r/, "")} length($0) == 64 && $0 !~ /[^0-9a-f]/ && !found {print; found=1}' "${log}")"
    [ -z "${container}" ] || docker rm -f "${container}" >/dev/null 2>&1 || true
  done
  if [ -n "${ZMK_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "${ZMK_TEST_ARTIFACT_DIR}/runs"
    if [ "${mode}" = host ] && [ "${failure_status}" != 0 ]; then
      printf '%s\n' "${failure_line}" > "${ZMK_TEST_ARTIFACT_DIR}/host-failure-line.txt"
      for stream in "${tmp_dir}"/native-copy-*; do
        [ -d "${stream}" ] || continue
        mkdir -p "${ZMK_TEST_ARTIFACT_DIR}/native-copy/${stream##*/}" || return 1
        for file in count 1.tar 2.tar; do
          [ ! -f "${stream}/${file}" ] || cp "${stream}/${file}" \
            "${ZMK_TEST_ARTIFACT_DIR}/native-copy/${stream##*/}/" || return 1
        done
      done
    fi
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
trap 'remember_host_failure "${test_previous_line}"' ERR
trap 'cleanup "$?" "${test_failure_line:-$test_previous_line}"' EXIT
if [ "${mode}" = host ]; then
  # Bash 3.2 reports the enclosing compound command's final line in ERR/EXIT.
  # DEBUG also runs before those handlers; retain the preceding command's line.
  # Keep only numeric locations, never command text or raw diagnostic contents.
  trap 'test_previous_line=$test_current_line; test_current_line=$LINENO' DEBUG
fi

summary_from_log() {
  local run
  run="$(awk '{gsub(/\033\[[0-9;]*m/, ""); gsub(/\r/, ""); if (sub(/^Run directory: /, "")) print}' "$1")"
  [ -n "${run}" ] || { echo "Run directory was not reported: $1" >&2; return 1; }
  printf '%s/build-summary.txt\n' "${run}"
}

mkdir -p "${fixture}/config" "${tool_root}/.build"
cp "${repo_root}/build.sh" "${tool_root}/build.sh"
cp "${repo_root}/.github/fixtures/ci-zmk-config/config/west.yml" "${fixture}/config/west.yml"
cp "${repo_root}/.github/fixtures/ci-zmk-config/build.yaml" "${fixture}/build.yaml"

add_payload_dirs() {
  local root="$1" dir
  mkdir -p "${root}"/{modules,tools,zmk,bootloader,optional,src,build,.cache,nested/build,nested/.cache}
  for dir in modules tools zmk bootloader optional; do
    printf 'generated\n' > "${root}/${dir}/generated.txt"
  done
  printf 'keep\n' > "${root}/src/keep.txt"
  printf 'exclude root\n' > "${root}/build/root.txt"
  printf 'exclude root\n' > "${root}/.cache/root.txt"
  printf 'keep nested\n' > "${root}/nested/build/keep.txt"
  printf 'keep nested\n' > "${root}/nested/.cache/keep.txt"
}

add_generated_git_markers() {
  local root="$1"
  mkdir -p "${root}"/{modules,tools,zmk,bootloader,optional}/.git
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
  local scenario="$1" target="$2" log_path module expectations
  shift 2
  local modules=()
  for module in "$@"; do modules+=(-m "${module}"); done
  local container="zmk-copy-excludes-${scenario}-$$"
  log_path="${tmp_dir}/${scenario}.log"
  expectations="${tmp_dir}/${scenario}.expect"
  printf '%s\0' image "${ZMK_BUILD_IMAGE}" target "$(cd "${target}" && pwd -P)" \
    cache "${ZMK_DOCKER_CACHE_VOLUME:-zmk-cache}" > "${expectations}"
  container_logs+=("${log_path}")

  echo "[build-contract] ${scenario}"
  ZMK_WEST_UPDATE_ATTEMPTS=2 ZMK_COPY_IGNORED="${copy_ignored:-}" ZMK_CCACHE_DIR="${ccache_dir:-}" \
    ZMK_KEEP_CONTAINER=1 ZMK_CONTAINER_NAME="${container}" \
    bash "${tool_root}/build.sh" validate "${target}" --settings-reset ${modules[@]+"${modules[@]}"} >"${log_path}" 2>&1 ||
    { tail -n 120 "${log_path}" >&2; return 1; }
  local run
  run="$(awk '{gsub(/\033\[[0-9;]*m/, ""); last=$0} END {gsub(/\r/, "", last); print last}' "${log_path}")"
  bash "${repo_root}/.github/scripts/check-build-output.sh" validate "${run}" --expect "${expectations}"
  last_container="$(awk '{gsub(/\r/, "")} length($0) == 64 && $0 !~ /[^0-9a-f]/ && !found {print; found=1}' "${log_path}")"
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

create_tmp="${tmp_dir}/.temporary inputs 名前 [test]"
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
  summary="$(summary_from_log "${tmp_dir}/host-${phase}.log")"
  [ -n "${summary}" ] || { echo "host ${phase} failure lost its summary" >&2; exit 1; }
  grep -qx 'Status: FAILED' "${summary}"
  grep -qx "Reason: ${reason}" "${summary}"
  grep -q 'injected .* failure' "${summary%/*}/build.log"
  grep -q 'Failure excerpt' "${summary}"
  [ "$(find "${create_tmp}" -type f | wc -l | tr -d '[:space:]')" = 0 ]
done
rm "${fake_bin}/tar"

# Exercise production tar/Git selection on the native host, including BSD tar and
# Git Bash. The daemon captures both actual input streams, then rejects the module
# copy deliberately; this proves host copying, not a container or firmware build.
copy_bin="${tmp_dir}/native-copy-bin"
mkdir -p "${copy_bin}"
copy_real_tar="$(command -v tar)"
copy_real_git="$(command -v git)"
cat > "${copy_bin}/tar" <<'EOF'
#!/usr/bin/env bash
if [ "${COPY_CONTROL}" = no-null ]; then
  if [ "${1:-}" = --help ]; then printf '%s\n' --exclude --null; exit 0; fi
  for arg in "$@"; do [ "${arg}" != --null ] || exit 2; done
fi
exec "${COPY_REAL_TAR}" "$@"
EOF
cat > "${copy_bin}/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = ls-files ]; then
  case "${COPY_CONTROL}" in git-failure) exit 23 ;; git-empty) exit 0 ;; esac
fi
exec "${COPY_REAL_GIT}" "$@"
EOF
cat > "${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  create) printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  start|rm) ;;
  exec)
    case "$*" in
      *'tar --no-same-owner'*)
        index="$(cat "${COPY_STREAMS}/count")"
        index=$((index + 1))
        [ "${index}" -le 2 ] || exit 99
        if [ "${index}" = 2 ]; then
          for last_arg in "$@"; do :; done
          [ "${last_arg}" = "${COPY_MODULE_NAME}" ] || exit 99
        fi
        cat > "${COPY_STREAMS}/${index}.tar" || exit "$?"
        printf '%s\n' "${index}" > "${COPY_STREAMS}/count"
        if [ "${index}" = 2 ]; then
          echo 'injected module copy boundary failure' >&2
          exit 23
        fi ;;
      *'cat > /root/zmk-config/build.sh'*) cat >/dev/null ;;
      *'mkdir -p /root/zmk-config'*) ;;
      *) exit 99 ;;
    esac ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${copy_bin}/tar" "${copy_bin}/git" "${fake_bin}/docker"

add_native_copy_payload() {
  local root="$1" role="$2" name
  for name in .zmk .build .cache .ccache .vscode build dist node_modules out tmp zmk_search; do
    mkdir -p "${root}/${name}" "${root}/nested/${name}"
    printf 'exclude root\n' > "${root}/${name}/root.txt"
    printf 'keep nested\n' > "${root}/nested/${name}/keep.txt"
  done
  for name in .git .west __pycache__; do
    mkdir -p "${root}/nested/${name}"
    printf 'exclude marker\n' > "${root}/nested/${name}/marker.txt"
  done
  mkdir -p "${root}/.hidden payload"
  printf '%s\n' "${role}" > "${root}/source-identity.txt"
  printf 'LF\nCRLF\r\nCR\rControl-Z\032NUL\000end\n' > "${root}/.hidden payload/mixed bytes.bin"
  printf 'unicode payload\n' > "${root}/.hidden payload/unicode-名前.txt"
  for name in '-C' '--exclude=src' 'literal [ab] $value; & (test).txt' 'unicode-名前-📦.txt'; do
    printf 'literal filename payload\n' > "${root}/${name}"
  done
  awk 'BEGIN { for (i=0;i<65536;i++) printf "0123456789abcdef" }' > "${root}/large input.bin"
  MSYS=winsymlinks:sys ln -s src/keep.txt "${root}/input-link"
  [ -L "${root}/input-link" ] || { echo 'native copy source fixture is not a symlink' >&2; return 1; }
  MSYS=winsymlinks:sys ln -s 'missing destination with spaces' "${root}/dangling-input-link"
  [ -L "${root}/dangling-input-link" ] && [ ! -e "${root}/dangling-input-link" ] || return 1
}

assert_native_copy_payload() {
  local original="$1" copied="$2" role="$3" policy="$4" generated="$5" name
  cmp "${copied}/source-identity.txt" <(printf '%s\n' "${role}") || return 1
  for name in 'src/keep.txt' '.hidden payload/mixed bytes.bin' '.hidden payload/unicode-名前.txt' 'large input.bin'; do
    cmp "${original}/${name}" "${copied}/${name}" || return 1
  done
  for name in '-C' '--exclude=src' 'literal [ab] $value; & (test).txt' 'unicode-名前-📦.txt'; do
    [ -f "${copied}/${name}" ] || { echo 'native copy lost literal filename' >&2; return 1; }
    cmp "${copied}/${name}" <(printf 'literal filename payload\n') || return 1
  done
  [ -L "${copied}/input-link" ] || { echo 'native copy lost the symlink type' >&2; return 1; }
  [ "$(readlink "${copied}/input-link")" = src/keep.txt ] || return 1
  [ -L "${copied}/dangling-input-link" ] && [ ! -e "${copied}/dangling-input-link" ] || return 1
  [ "$(readlink "${copied}/dangling-input-link")" = 'missing destination with spaces' ] || return 1
  for name in .zmk .build .cache .ccache .vscode build dist node_modules out tmp zmk_search; do
    [ ! -e "${copied}/${name}" ] || return 1
    cmp "${copied}/nested/${name}/keep.txt" <(printf 'keep nested\n') || return 1
  done
  for name in .git .west __pycache__; do
    [ ! -e "${copied}/${name}" ] || return 1
    [ ! -e "${copied}/nested/${name}" ] || return 1
  done
  for name in zmk modules tools bootloader optional; do
    if [ "${generated}" = exclude ]; then [ ! -e "${copied}/${name}" ] || return 1;
    else cmp "${copied}/${name}/generated.txt" <(printf 'generated\n') || return 1; fi
    [ ! -e "${copied}/${name}/.git" ] || return 1
  done
  if [ "${policy}" != none ]; then
    cmp "${copied}/visible.txt" <(printf 'visible\n') || return 1
    cmp "${copied}/artifacts/forced.txt" <(printf 'forced\n') || return 1
    [ ! -e "${copied}/gone.txt" ] || return 1
    for name in artifacts/run1/big.bin web/node_modules/pkg/index.js; do
      if [ "${policy}" = visible ]; then [ ! -e "${copied}/${name}" ] || return 1;
      else cmp "${original}/${name}" "${copied}/${name}" || return 1; fi
    done
  fi
}

native_target="$(make_target 'native copy target' none)"
native_module="$(make_module '.hidden native module' none)"
add_native_copy_payload "${native_target}" target
add_native_copy_payload "${native_module}" module
for root in "${native_target}" "${native_module}"; do
  add_git_ignore_payload "${root}"
  # Keep the nested fixed-exclusion names visible; ignore only the intended bulk.
  printf '/artifacts/\n/web/node_modules/\n' > "${root}/.gitignore"
done
generated_target="$(make_target 'native generated target' west)"
generated_module="$(make_module '.hidden generated module' west)"
add_native_copy_payload "${generated_target}" target
add_native_copy_payload "${generated_module}" module
add_generated_git_markers "${generated_target}"
add_generated_git_markers "${generated_module}"
for copy_case in git-visible git-opt-out git-failure git-empty no-null generated no-west no-markers; do
  echo "[host-contract] native-copy ${copy_case}"
  copy_target="${native_target}"
  copy_module="${native_module}"
  copy_policy=all
  copy_generated=keep
  copy_ignored=0
  case "${copy_case}" in
    git-visible) copy_policy=visible ;;
    git-opt-out) copy_ignored=1 ;;
    generated|no-west|no-markers)
      copy_target="${generated_target}"
      copy_module="${generated_module}"
      copy_policy=none
      case "${copy_case}" in
        generated) copy_generated=exclude ;;
        no-west) rmdir "${copy_target}/.west" "${copy_module}/.west" ;;
        no-markers)
          mkdir "${copy_target}/.west" "${copy_module}/.west"
          for root in "${copy_target}" "${copy_module}"; do
            for name in zmk modules tools bootloader optional; do rmdir "${root}/${name}/.git"; done
          done ;;
      esac ;;
  esac
  copy_streams="${tmp_dir}/native-copy-${copy_case}"
  mkdir "${copy_streams}" "${copy_streams}/target" "${copy_streams}/module"
  printf '0\n' > "${copy_streams}/count"
  if TMPDIR="${create_tmp}" PATH="${copy_bin}:${fake_bin}:${PATH}" COPY_CONTROL="${copy_case}" \
      COPY_REAL_TAR="${copy_real_tar}" COPY_REAL_GIT="${copy_real_git}" COPY_STREAMS="${copy_streams}" \
      COPY_MODULE_NAME="${copy_module##*/}" ZMK_COPY_IGNORED="${copy_ignored}" \
      bash "${tool_root}/build.sh" validate "${copy_target}/." -m "${copy_module}/." \
      > "${tmp_dir}/native-copy-${copy_case}.log" 2>&1; then
    echo 'injected source copy boundary failure was accepted' >&2; exit 1
  else
    copy_status=$?
  fi
  [ "${copy_status}" = 23 ]
  [ "$(cat "${copy_streams}/count")" = 2 ]
  find "${create_tmp}" -type f > "${tmp_dir}/native-copy-temporaries.log"
  [ ! -s "${tmp_dir}/native-copy-temporaries.log" ]
  summary="$(summary_from_log "${tmp_dir}/native-copy-${copy_case}.log")"
  grep -qx 'Status: FAILED' "${summary}"
  grep -qx 'Reason: source copy failed' "${summary}"
  MSYS=winsymlinks:sys "${copy_real_tar}" --no-same-owner -xf "${copy_streams}/1.tar" -C "${copy_streams}/target"
  MSYS=winsymlinks:sys "${copy_real_tar}" --no-same-owner -xf "${copy_streams}/2.tar" -C "${copy_streams}/module"
  assert_native_copy_payload "${copy_target}" "${copy_streams}/target" target "${copy_policy}" "${copy_generated}"
  assert_native_copy_payload "${copy_module}" "${copy_streams}/module" module "${copy_policy}" "${copy_generated}"
  if [ "${copy_case}" = git-visible ]; then
    # Named control: losing one literal filename fails even when the archive extracts.
    rm "${copy_streams}/target/literal [ab] \$value; & (test).txt"
    if assert_native_copy_payload "${copy_target}" "${copy_streams}/target" target visible keep \
        > "${tmp_dir}/native-copy-lost-literal-name.log" 2>&1; then
      echo 'native copy accepted a missing literal filename' >&2; exit 1
    fi
    grep -qx 'native copy lost literal filename' "${tmp_dir}/native-copy-lost-literal-name.log"
    cp "${copy_target}/literal [ab] \$value; & (test).txt" "${copy_streams}/target/"
    echo '[host-contract] control lost-literal-name rejected'
    # Named controls prove a swapped input or materialized link cannot pass the oracle.
    if assert_native_copy_payload "${copy_target}" "${copy_streams}/module" target visible keep \
        > "${tmp_dir}/native-copy-wrong-input.log" 2>&1; then
      echo 'native copy accepted the wrong source identity' >&2; exit 1
    fi
    grep -q 'source-identity.txt' "${tmp_dir}/native-copy-wrong-input.log"
    rm "${copy_streams}/target/input-link"
    cp "${copy_streams}/target/src/keep.txt" "${copy_streams}/target/input-link"
    if assert_native_copy_payload "${copy_target}" "${copy_streams}/target" target visible keep \
        > "${tmp_dir}/native-copy-materialized-link.log" 2>&1; then
      echo 'native copy accepted a materialized symlink' >&2; exit 1
    fi
    grep -qx 'native copy lost the symlink type' "${tmp_dir}/native-copy-materialized-link.log"
  fi
done

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
      *'find /root/zmk-config/.build'*) printf '/root/zmk-config/.build/selected.bin\0' ;;
      *'tar --no-same-owner'*)
        cat >/dev/null
        [ "${IDENTITY_PHASE}" != copy ] || { echo 'injected copy failure' >&2; exit 23; } ;;
      *'cat > /root/zmk-config/build.sh'*) cat >/dev/null ;;
      *'./build.sh validate'*) echo "injected ${IDENTITY_PHASE} failure" >&2; exit 23 ;;
      *'./build.sh build'*) echo 'Build complete: 1 target(s).' ;;
      *'mkdir -p /root/zmk-config'*) ;;
      *) exit 99 ;;
    esac ;;
  cp) echo 'injected artifact failure' >&2; exit 23 ;;
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
    echo "injected identity ${phase} failure was accepted" >&2; identity_failed=1; remember_host_failure "$LINENO"
  fi
  if ! grep -qx 'rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${commands}"; then
    echo "identity ${phase}: cleanup addressed a replaceable container name" >&2; identity_failed=1; remember_host_failure "$LINENO"
  fi
  if grep -v '^create ' "${commands}" | grep -q 'replaceable-test-name'; then
    echo "identity ${phase}: an operation addressed a replaceable container name" >&2; identity_failed=1; remember_host_failure "$LINENO"
  fi
  grep -q "injected ${phase} failure" "${tmp_dir}/identity-${phase}.log"
  if [ "${phase}" = module ]; then
    if ! grep '/root/external_modules' "${commands}" | grep -q '_ dot-module$'; then
      echo 'module path ending in /. was copied under the wrong name' >&2; identity_failed=1; remember_host_failure "$LINENO"
    fi
  fi
  case "${phase}" in
    start) reason='container start failed' ;;
    copy) reason='source copy failed' ;;
    validate|module) reason='validation failed' ;;
    artifact) reason='artifact copy failed' ;;
  esac
  summary="$(summary_from_log "${tmp_dir}/identity-${phase}.log")"
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
    echo "lifecycle ${phase}: expected status ${expected}, got ${status}" >&2; lifecycle_failed=1; remember_host_failure "$LINENO"
  fi
  summary="$(summary_from_log "${tmp_dir}/lifecycle-${phase}.log")"
  if [ ! -f "${summary}" ]; then
    echo "lifecycle ${phase}: missing run summary" >&2; lifecycle_failed=1; remember_host_failure "$LINENO"; continue
  fi
  if [ "${expected}" = 0 ]; then
    if ! bash "${repo_root}/.github/scripts/check-build-output.sh" validate "${summary%/*}" \
        >"${tmp_dir}/lifecycle-${phase}.checker.log" 2>&1; then lifecycle_failed=1; remember_host_failure "$LINENO"; fi
  elif ! grep -qx 'Status: FAILED' "${summary}" || ! grep -qx "Reason: ${reason}" "${summary}"; then
    echo "lifecycle ${phase}: missing FAILED summary or original reason" >&2; lifecycle_failed=1; remember_host_failure "$LINENO"
  fi
  case "${phase}" in
    cleanup-failure|both-failures)
      if ! grep -q 'injected container cleanup failure' "${summary%/*}/build.log" ||
          ! grep -q 'failed to remove build container' "${summary}"; then
        echo "lifecycle ${phase}: cleanup diagnostics lost" >&2; lifecycle_failed=1; remember_host_failure "$LINENO"
      fi ;;
    reset-failure|list-failure)
      if grep -q '^create ' "${commands}" || ! grep -q 'injected .* failure' "${summary%/*}/build.log"; then
        echo "lifecycle ${phase}: build started after reset failure or diagnostics lost" >&2; lifecycle_failed=1; remember_host_failure "$LINENO"
      fi ;;
  esac
  if [ "${phase}" = keep ] || [ "${phase}" = create-failure ]; then
    if grep -q '^rm ' "${commands}"; then
      echo "lifecycle ${phase}: removed a kept or unowned container" >&2; lifecycle_failed=1; remember_host_failure "$LINENO"
    fi
  elif [ "${phase}" != reset-failure ] && [ "${phase}" != list-failure ]; then
    if ! grep -qx 'rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${commands}"; then lifecycle_failed=1; remember_host_failure "$LINENO"; fi
  fi
  case "${phase}" in
    missing|list-failure)
      if grep -q '^volume rm ' "${commands}"; then
        echo "lifecycle ${phase}: removed an absent or unverified volume" >&2; lifecycle_failed=1; remember_host_failure "$LINENO"
      fi ;;
    present|present-crlf|reset-failure)
      if ! grep -qx 'volume rm lifecycle-cache' "${commands}"; then lifecycle_failed=1; remember_host_failure "$LINENO"; fi ;;
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
    summary="$(summary_from_log "${signal_prefix}.log")"
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
    echo "distinct module names were rejected: ${order}" >&2; module_names_failed=1; remember_host_failure "$LINENO"
  fi
done
same="$(make_module beta none "${tmp_dir}/other-parent")"
if PATH="${fake_bin}:${PATH}" bash "${tool_root}/build.sh" validate "${fixture}" -m "${short}" -m "${same}" \
    >"${tmp_dir}/module-names-duplicate.log" 2>&1; then
  echo 'duplicate module basename was accepted' >&2; module_names_failed=1; remember_host_failure "$LINENO"
fi
grep -q 'duplicate module input name: beta' "${tmp_dir}/module-names-duplicate.log"
if grep -q 'fake docker reached' "${tmp_dir}/module-names-duplicate.log"; then
  echo 'duplicate module basename reached Docker' >&2; module_names_failed=1; remember_host_failure "$LINENO"
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

# Separate byte-pressure/count boundaries from repeated per-file imports.
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
      *'find /root/zmk-config/.build'*)
        case "${NEW_ATTACK:-}" in
          large-list)
            printf '/tmp/escape.bin\0' || exit "$?"
            awk 'BEGIN {for (i=0; i<32768; i++) printf "/root/zmk-config/.build/padding-for-drain-control.bin%c", 0}' || exit "$?"
            : > "${NEW_LIST_COMPLETE}" ;;
          absolute-entry) printf '/tmp/escape.bin\0' ;;
          parent-entry) printf '/root/zmk-config/.build/../escape.bin\0' ;;
          truncated-list) printf '/root/zmk-config/.build/selected.bin' ;;
          duplicate-entry) printf '/root/zmk-config/.build/selected.bin\0/root/zmk-config/.build/selected.bin\0' ;;
          duplicate-case) printf '/root/zmk-config/.build/selected.bin\0/root/zmk-config/.build/SELECTED.bin\0' ;;
          reserved-name) printf '/root/zmk-config/.build/CON.part.bin\0' ;;
          unsafe-name) printf '/root/zmk-config/.build/line\nbreak.bin\0' ;;
          *)
            while IFS= read -r -d '' file; do
              printf '/root/zmk-config/.build/%s\0' "${file##*/}"
            done < <(find "${NEW_PAYLOAD}" -mindepth 1 -maxdepth 1 -print0) ;;
        esac
        [ "${NEW_ATTACK:-}" != list-failure ] || exit 23 ;;
      *'tar --no-same-owner'*|*'cat > /root/zmk-config/build.sh'*) cat >/dev/null ;;
      *'./build.sh validate'*) echo 'build.yaml is valid.' ;;
      *'./build.sh build'*)
        case "${NEW_MARKER_STYLE:-plain}" in
          decorated)
            printf 'old Build complete: 9 target(s).\n'
            awk 'BEGIN {for (i=0; i<32768; i++) printf "Build complete: 7 target(s). "; print "Build complete: 8 target(s). trailing malformed Build complete: invalid target(s)."}'
            printf '\033[?25h[worker] Build \033[36mcomplete:\033[0m 1 target(s). mid Build comp\rlete: 2 target(s). tail Build complete: invalid target(s).\r\n'
            printf 'Build complete: 777 targets.\n' ;;
          absent) printf 'synthetic build without a completion marker\n' ;;
          plain) printf 'Build complete: %s target(s).\n' "${NEW_COUNT}" ;;
          *) exit 99 ;;
        esac ;;
      *'mkdir -p /root/zmk-config'*) ;;
      *) exit 99 ;;
    esac ;;
  cp)
    case "$2" in
      aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:/root/zmk-config/.build/*) ;;
      *) echo 'artifact copy did not use its acquired container ID' >&2; exit 99 ;;
    esac
    [ "$3" = ./firmware ] && [ -f ./firmware ] && [ ! -L ./firmware ] || exit 99
    [ "${NEW_ATTACK:-}" != copy-failure ] || exit 23
    source="${NEW_PAYLOAD}/${2##*/}"
    # The daemon preserves link type. MSYS's default deepcopy is not that model.
    MSYS=winsymlinks:sys cp -P "${source}" "$3" || exit "$?"
    if [ -L "${source}" ] && [ ! -L "$3" ]; then
      echo 'artifact-copy fixture materialized a symlink' >&2; exit 99
    fi ;;
  rm)
    if [ "${NEW_PHASE}" = cleanup-rm ]; then
      : > "${NEW_REACHED}"
      while [ ! -f "${NEW_RELEASE}" ]; do sleep .01; done
    fi
    [ -z "${NEW_COMPLETE:-}" ] || : > "${NEW_COMPLETE}"
    printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${fake_bin}/docker"
export NEW_REAL_RM="$(command -v rm)"
cat > "${fake_bin}/rm" <<'EOF'
#!/usr/bin/env bash
if [ "${NEW_ATTACK:-}" = staging-cleanup ] && [ "${1:-}" = -rf ]; then
  case "${2:-}" in */artifact-tmp-*) echo 'injected artifact staging cleanup failure' >&2; exit 23 ;; esac
fi
exec "${NEW_REAL_RM}" "$@"
EOF
chmod +x "${fake_bin}/rm"
export NEW_REAL_CHMOD="$(command -v chmod)"
cat > "${fake_bin}/chmod" <<'EOF'
#!/usr/bin/env bash
if [ "${NEW_ATTACK:-}" = permissions-failure ] && [ "${1:-}" = 0644 ]; then
  echo 'injected artifact permissions failure' >&2; exit 23
fi
exec "${NEW_REAL_CHMOD}" "$@"
EOF
chmod +x "${fake_bin}/chmod"
payload="${tmp_dir}/firmware-multiple"
mkdir -p "${payload}"
padding=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
for number in 1 2; do
  printf 'synthetic firmware\n' > "${payload}/target-${number}-${padding}.bin"
done
for marker_style in decorated absent; do
  PATH="${fake_bin}:${PATH}" NEW_PHASE=artifacts NEW_COUNT=2 NEW_PAYLOAD="${payload}" \
      NEW_MARKER_STYLE="${marker_style}" NEW_CALLS="${tmp_dir}/firmware-multiple-${marker_style}.commands.log" \
      bash "${tool_root}/build.sh" "${fixture}" >"${tmp_dir}/firmware-multiple-${marker_style}.log" 2>&1
  summary="$(summary_from_log "${tmp_dir}/firmware-multiple-${marker_style}.log")"
  grep -qx 'Status: SUCCESS' "${summary}"
  grep -qx 'Built targets: 2' "${summary}"
  [ "$(grep -c '^- target-' "${summary}")" = 2 ]
  for number in 1 2; do
    cmp "${summary%/*}/target-${number}-${padding}.bin" <(printf 'synthetic firmware\n')
  done
  bash "${repo_root}/.github/scripts/check-build-output.sh" build "${summary%/*}"
done

# A marker above 255 must remain an integer even when the output is incomplete.
PATH="${fake_bin}:${PATH}" NEW_PHASE=artifacts NEW_COUNT=512 NEW_PAYLOAD="${payload}" \
    NEW_CALLS="${tmp_dir}/firmware-count.commands.log" \
    bash "${tool_root}/build.sh" "${fixture}" >"${tmp_dir}/firmware-count.log" 2>&1
summary="$(summary_from_log "${tmp_dir}/firmware-count.log")"
grep -qx 'Built targets: 512' "${summary}"
if bash "${repo_root}/.github/scripts/check-build-output.sh" build "${summary%/*}" \
    > "${tmp_dir}/firmware-count-check.log" 2>&1; then
  echo 'large build count accepted incomplete firmware output' >&2; exit 1
fi
grep -F 'Firmware artifact count (2) is lower than built target count (512).' "${tmp_dir}/firmware-count-check.log" >/dev/null

# Named process-budget control: normalization and summary counting must not start
# a pipeline of helpers on every invocation. Include the real source-copy filter.
budget_bin="${tmp_dir}/helper-budget-bin"
mkdir -p "${budget_bin}"
for helper in awk sed tr tail; do
  cat > "${budget_bin}/${helper}" <<'EOF'
#!/usr/bin/env bash
helper="${0##*/}"
printf '%s\n' "${helper}" >> "${HOST_HELPER_CALLS}"
case "${helper}" in
  awk) exec "${HOST_REAL_AWK}" "$@" ;;
  sed) exec "${HOST_REAL_SED}" "$@" ;;
  tr) exec "${HOST_REAL_TR}" "$@" ;;
  tail) exec "${HOST_REAL_TAIL}" "$@" ;;
  *) exit 99 ;;
esac
EOF
  chmod +x "${budget_bin}/${helper}"
done
helper_calls="${tmp_dir}/host-helper-budget.calls.log"
budget_real_awk="$(command -v awk)" budget_real_sed="$(command -v sed)"
budget_real_tr="$(command -v tr)" budget_real_tail="$(command -v tail)"
PATH="${budget_bin}:${fake_bin}:${PATH}" HOST_HELPER_CALLS="${helper_calls}" \
    HOST_REAL_AWK="${budget_real_awk}" HOST_REAL_SED="${budget_real_sed}" \
    HOST_REAL_TR="${budget_real_tr}" HOST_REAL_TAIL="${budget_real_tail}" \
    NEW_PHASE=helper-budget NEW_CALLS="${tmp_dir}/host-helper-budget.commands.log" \
    bash "${tool_root}/build.sh" validate "${fixture}" >"${tmp_dir}/host-helper-budget.log" 2>&1
summary="$(summary_from_log "${tmp_dir}/host-helper-budget.log")"
bash "${repo_root}/.github/scripts/check-build-output.sh" validate "${summary%/*}"
helper_count=0
while IFS= read -r helper; do
  case "${helper}" in awk|sed|tr|tail) ;; *) echo 'invalid process-budget receipt' >&2; exit 1 ;; esac
  helper_count=$((helper_count + 1))
done < "${helper_calls}"
if [ "${helper_count}" -eq 0 ] || [ "${helper_count}" -gt 3 ]; then
  echo "host helper process budget exceeded: ${helper_count} (maximum 3)" >&2; exit 1
fi
echo '[host-contract] helper process budget passed'

# Named control: a lazy consumer closes before this >1MiB NUL producer completes.
control_done="${tmp_dir}/unsafe-list.complete"
if NEW_PHASE=artifacts NEW_ATTACK=large-list NEW_LIST_COMPLETE="${control_done}" \
    NEW_CALLS="${tmp_dir}/unsafe-list.commands.log" "${fake_bin}/docker" exec \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa find /root/zmk-config/.build -print0 |
    (IFS= read -r -d '' first; printf '%s\n' "${first}" > "${tmp_dir}/unsafe-list-first.log"; exit 23) \
    > "${tmp_dir}/unsafe-list.log" 2>&1; then
  echo 'unsafe artifact-list consumer unexpectedly succeeded' >&2; exit 1
fi
grep -qx '/tmp/escape.bin' "${tmp_dir}/unsafe-list-first.log"
[ ! -e "${control_done}" ]
echo '[host-contract] control lazy-list-consumer rejected'

# YAML-derived firmware names, including dots and multi-part fallback, stay inside the run.
payload="${tmp_dir}/firmware-dotted"
mkdir -p "${payload}"
printf 'synthetic signed firmware\n' > "${payload}/target.with.dots.signed.bin"
PATH="${fake_bin}:${PATH}" NEW_PHASE=artifacts NEW_COUNT=1 NEW_PAYLOAD="${payload}" \
    NEW_CALLS="${tmp_dir}/firmware-dotted.commands.log" ZMK_FALLBACK_BINARY=signed.bin \
    bash "${tool_root}/build.sh" "${fixture}" >"${tmp_dir}/firmware-dotted.log" 2>&1
summary="$(summary_from_log "${tmp_dir}/firmware-dotted.log")"
grep -qx 'Status: SUCCESS' "${summary}"
grep -qx 'Built targets: 1' "${summary}"
test -s "${summary%/*}/target.with.dots.signed.bin"
bash "${repo_root}/.github/scripts/check-build-output.sh" build "${summary%/*}"

# Container output cannot replace evidence, traverse paths or import special files.
for attack in log-link summary-link log-case summary-case firmware-link firmware-directory \
    reserved-name unsafe-name duplicate-case duplicate-entry absolute-entry parent-entry \
    truncated-list list-failure large-list copy-failure permissions-failure staging-cleanup; do
  payload="${tmp_dir}/artifact-${attack}"
  outside="${tmp_dir}/outside-${attack}"
  mkdir -p "${payload}" "${outside}"
  printf 'preserve host canary\n' > "${outside}/canary"
  printf 'synthetic firmware\n' > "${payload}/selected.bin"
  case "${attack}" in
    log-link) MSYS=winsymlinks:sys ln -s "${outside}/canary" "${payload}/build.log" ;;
    summary-link) MSYS=winsymlinks:sys ln -s "${outside}" "${payload}/build-summary.txt" ;;
    log-case) printf 'fake log\n' > "${payload}/BUILD.LOG" ;;
    summary-case) printf 'fake summary\n' > "${payload}/BUILD-SUMMARY.TXT" ;;
    firmware-link)
      rm "${payload}/selected.bin"
      MSYS=winsymlinks:sys ln -s "${outside}/canary" "${payload}/selected.bin" ;;
    firmware-directory) rm "${payload}/selected.bin"; mkdir "${payload}/selected.bin" ;;
  esac
  case "${attack}" in
    log-link|summary-link|firmware-link)
      [ -L "${payload}/build.log" ] || [ -L "${payload}/build-summary.txt" ] || [ -L "${payload}/selected.bin" ] ||
        { echo 'artifact attack fixture is not a symlink' >&2; exit 1; } ;;
  esac
  if PATH="${fake_bin}:${PATH}" NEW_PHASE=artifacts NEW_COUNT=1 NEW_PAYLOAD="${payload}" NEW_ATTACK="${attack}" \
      NEW_LIST_COMPLETE="${tmp_dir}/artifact-${attack}.list-complete" \
      NEW_CALLS="${tmp_dir}/artifact-${attack}.commands.log" \
      bash "${tool_root}/build.sh" "${fixture}" >"${tmp_dir}/artifact-${attack}.log" 2>&1; then
    status=0
  else status=$?; fi
  summary="$(summary_from_log "${tmp_dir}/artifact-${attack}.log")"
  if [ -n "${ZMK_TEST_ARTIFACT_DIR:-}" ]; then
    attack_evidence="${ZMK_TEST_ARTIFACT_DIR}/artifact-security/${attack}"
    mkdir -p "${attack_evidence}"
    cp "${outside}/canary" "${attack_evidence}/host-canary"
    find "${outside}" -mindepth 1 -maxdepth 1 -print > "${attack_evidence}/outside-entries.txt"
    printf '%s\n' "${status}" > "${attack_evidence}/build.exit"
  fi
  if [ "${status}" = 0 ] || ! cmp -s "${outside}/canary" <(printf 'preserve host canary\n') ||
      [ "$(find "${outside}" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')" != 1 ] ||
      [ -L "${summary}" ] || [ -L "${summary%/*}/build.log" ] ||
      ! grep -qx 'Status: FAILED' "${summary}"; then
    echo "artifact ${attack}: container output replaced evidence or wrote outside the run" >&2
    finalization_failed=1; remember_host_failure "$LINENO"
  else
    grep -qx 'Reason: artifact copy failed' "${summary}"
    staging_count="$(find "${summary%/*}" -mindepth 1 -maxdepth 1 -name 'artifact-tmp-*' | wc -l | tr -d '[:space:]')"
    if [ "${attack}" = staging-cleanup ]; then
      [ "${staging_count}" = 1 ]
    else [ "${staging_count}" = 0 ]; fi
    # Independently inspect rejection and copy argv so an unrelated error is no PASS.
    case "${attack}" in
      log-*|summary-*) expected='artifact filename collides with host evidence' ;;
      firmware-link) expected='artifact is not a regular file' ;;
      firmware-directory|copy-failure) expected='failed to copy build output from the container' ;;
      reserved-name) expected='reserved artifact filename from the container' ;;
      unsafe-name|parent-entry) expected='unsafe artifact filename from the container' ;;
      duplicate-*) expected='duplicate artifact filename from the container' ;;
      absolute-entry|large-list) expected='artifact path is outside the container output directory' ;;
      truncated-list) expected='unterminated artifact path from the container' ;;
      list-failure) expected='failed to list build output from the container' ;;
      permissions-failure) expected='failed to normalize artifact permissions' ;;
      staging-cleanup) expected='failed to remove artifact staging directory' ;;
    esac
    grep -Fx "${expected}" "${summary%/*}/build.log" >/dev/null
    if [ "${attack}" = large-list ]; then
      test -f "${tmp_dir}/artifact-${attack}.list-complete"
      echo '[host-contract] large artifact list drained before rejection'
    fi
    case "${attack}" in
      firmware-*|copy-failure|permissions-failure|staging-cleanup)
        grep -Fx 'cp aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:/root/zmk-config/.build/selected.bin ./firmware' \
          "${tmp_dir}/artifact-${attack}.commands.log" >/dev/null ;;
      *)
        if grep '^cp ' "${tmp_dir}/artifact-${attack}.commands.log" >/dev/null; then
          echo "artifact ${attack}: rejected names reached docker cp" >&2; exit 1
        fi ;;
    esac
  fi
done
rm "${fake_bin}/rm" "${fake_bin}/chmod"

# A frozen clock and concurrent invocations must reserve separate run directories.
real_date="$(command -v date)"
real_mkdir="$(command -v mkdir)"
cat > "${fake_bin}/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = '+%Y-%m-%d_%H-%M-%S' ]; then printf '%s\n' "${ZMK_TEST_RUN_TIMESTAMP:-2000-01-02_03-04-05}"
else exec "${ZMK_TEST_REAL_DATE}" "$@"; fi
EOF
chmod +x "${fake_bin}/date"
# Some mkdir implementations report success for a concurrently created directory.
# Model that behavior explicitly while retaining the native-command lane.
cat > "${fake_bin}/mkdir" <<'EOF'
#!/usr/bin/env bash
if [ "${ZMK_TEST_OPTIMISTIC_MKDIR:-0}" = 1 ]; then
  destination=
  for argument in "$@"; do destination="$argument"; done
  case "${destination##*/}" in
    run-*)
      "${ZMK_TEST_REAL_MKDIR}" "$@" 2>/dev/null
      status=$?
      [ ! -d "${destination}" ] || exit 0
      exit "${status}" ;;
  esac
fi
exec "${ZMK_TEST_REAL_MKDIR}" "$@"
EOF
chmod +x "${fake_bin}/mkdir"
for reservation_kind in native optimistic; do
  case "${reservation_kind}" in
    native) frozen_time=2000-01-02_03-04-05; optimistic_mkdir=0 ;;
    optimistic) frozen_time=2000-01-02_03-04-06; optimistic_mkdir=1 ;;
  esac
  reserved="${tool_root}/.build/run-${frozen_time}-ci-zmk-config"
  printf 'preserve existing file\n' > "${reserved}"
  MSYS=winsymlinks:sys ln -s "${tmp_dir}/missing-run" "${reserved}-2"
  [ -L "${reserved}-2" ] || { echo 'run reservation fixture is not a symlink' >&2; exit 1; }
  if [ "${reservation_kind}" = optimistic ]; then
    printf 'preserve foreign claim\n' > "${reserved}-3.reserve"
    MSYS=winsymlinks:sys ln -s "${tmp_dir}/missing-claim" "${reserved}-4.reserve"
    [ -L "${reserved}-4.reserve" ] || { echo 'claim fixture is not a symlink' >&2; exit 1; }
  fi
  reservation_pids=()
  for number in $(seq 1 10); do
    PATH="${fake_bin}:${PATH}" ZMK_TEST_REAL_DATE="${real_date}" ZMK_TEST_REAL_MKDIR="${real_mkdir}" \
        ZMK_TEST_RUN_TIMESTAMP="${frozen_time}" ZMK_TEST_OPTIMISTIC_MKDIR="${optimistic_mkdir}" NEW_PHASE=reservation \
        NEW_CALLS="${tmp_dir}/reservation-${reservation_kind}-${number}.commands.log" \
        bash "${tool_root}/build.sh" validate "${fixture}" > "${tmp_dir}/reservation-${reservation_kind}-${number}.log" 2>&1 &
    reservation_pids+=("$!")
  done
  for pid in "${reservation_pids[@]}"; do wait "${pid}"; done
  for number in $(seq 1 10); do
    summary="$(summary_from_log "${tmp_dir}/reservation-${reservation_kind}-${number}.log")"
    case "${reservation_kind}:${summary}" in
      native:"${reserved}"-[3-9]/build-summary.txt|native:"${reserved}"-1[0-2]/build-summary.txt|\
      optimistic:"${reserved}"-[5-9]/build-summary.txt|optimistic:"${reserved}"-1[0-4]/build-summary.txt) ;;
      *) echo "Unexpected reserved run directory: ${summary}" >&2; exit 1 ;;
    esac
    bash "${repo_root}/.github/scripts/check-build-output.sh" validate "${summary%/*}"
  done
  [ "$(find "${tool_root}/.build" -maxdepth 1 -type d -name "run-${frozen_time}-ci-zmk-config-*" | wc -l | tr -d '[:space:]')" = 10 ]
  grep -qx 'preserve existing file' "${reserved}"
  [ -L "${reserved}-2" ]
  if [ "${reservation_kind}" = optimistic ]; then
    grep -qx 'preserve foreign claim' "${reserved}-3.reserve"
    [ -L "${reserved}-4.reserve" ]
    [ "$(find "${tool_root}/.build" -maxdepth 1 -name "run-${frozen_time}-*.reserve" | wc -l | tr -d '[:space:]')" = 2 ]
    rm "${reserved}-3.reserve" "${reserved}-4.reserve"
  else
    [ "$(find "${tool_root}/.build" -maxdepth 1 -name "run-${frozen_time}-*.reserve" | wc -l | tr -d '[:space:]')" = 0 ]
  fi
  rm "${reserved}" "${reserved}-2"
done
rm "${fake_bin}/mkdir"

# A failed claim release retains failure evidence and stops before Docker.
cat > "${fake_bin}/rm" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -f ]; then
  case "${2:-}" in
    *.reserve)
      printf 'claim release attempted\n' >> "${ZMK_TEST_CLAIM_RM_CALLS}"
      echo 'injected run claim release failure' >&2; exit 23 ;;
  esac
fi
exec "${NEW_REAL_RM}" "$@"
EOF
chmod +x "${fake_bin}/rm"
prefix="${tmp_dir}/claim-release-failure"
if PATH="${fake_bin}:${PATH}" ZMK_TEST_REAL_DATE="${real_date}" ZMK_TEST_RUN_TIMESTAMP=2000-01-02_03-04-07 \
    ZMK_TEST_CLAIM_RM_CALLS="${prefix}.rm-calls.log" NEW_PHASE=reservation NEW_CALLS="${prefix}.commands.log" \
    bash "${tool_root}/build.sh" validate "${fixture}" > "${prefix}.log" 2>&1; then
  echo 'failed run claim release was accepted' >&2; exit 1
fi
summary="$(summary_from_log "${prefix}.log")"
grep -qx 'Status: FAILED' "${summary}"
grep -qx 'Reason: run directory reservation failed' "${summary}"
grep -qx 'failed to release run directory claim' "${summary%/*}/build.log"
[ -f "${summary%/*}.reserve" ]
[ "$(wc -l < "${prefix}.rm-calls.log" | tr -d '[:space:]')" = 1 ]
[ ! -e "${prefix}.commands.log" ]
rm "${fake_bin}/rm"

# Names are safe display labels from the selected config root, not parsed YAML on the host.
for naming_case in hidden numeric unicode literal long; do
  case "${naming_case}" in
    hidden) source_name='.Hidden Config.V2-10'; expected_label=hidden-config-v2-10 ;;
    numeric) source_name=numeric-10; expected_label=numeric-10 ;;
    unicode) source_name=名前; expected_label=config ;;
    literal) source_name="--MiX--..__name-  tail='Quoted'--"; expected_label=mix---__name--tail-quoted ;;
    long)
      source_name="$(printf '%100s' '' | tr ' ' a)"
      expected_label=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  esac
  source_root="${tmp_dir}/${source_name}"
  mkdir -p "${source_root}/config"
  cp "${fixture}/build.yaml" "${source_root}/build.yaml"
  cp "${fixture}/config/west.yml" "${source_root}/config/west.yml"
  PATH="${fake_bin}:${PATH}" ZMK_TEST_REAL_DATE="${real_date}" NEW_PHASE=naming \
      NEW_CALLS="${tmp_dir}/naming-${naming_case}.commands.log" \
      bash "${tool_root}/build.sh" validate "${source_root}/." > "${tmp_dir}/naming-${naming_case}.log" 2>&1
  summary="$(summary_from_log "${tmp_dir}/naming-${naming_case}.log")"
  [ "${summary}" = "${tool_root}/.build/run-2000-01-02_03-04-05-${expected_label}/build-summary.txt" ]
  bash "${repo_root}/.github/scripts/check-build-output.sh" validate "${summary%/*}"
  if [ "${naming_case}" = long ]; then
    PATH="${fake_bin}:${PATH}" ZMK_TEST_REAL_DATE="${real_date}" NEW_PHASE=naming \
        NEW_CALLS="${tmp_dir}/naming-long-second.commands.log" \
        bash "${tool_root}/build.sh" validate "${source_root}" > "${tmp_dir}/naming-long-second.log" 2>&1
    second_summary="$(summary_from_log "${tmp_dir}/naming-long-second.log")"
    [ "${second_summary}" = "${summary%/*}-2/build-summary.txt" ]
    grep -qx 'Run sequence: 2' "${second_summary}"
    bash "${repo_root}/.github/scripts/check-build-output.sh" validate "${second_summary%/*}"
  fi
done
rm "${fake_bin}/date"

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
    echo 'receipt parsing lost the created container identity' >&2; finalization_failed=1; remember_host_failure "$LINENO"
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
    summary="$(summary_from_log "${prefix}.log")"
    expected=143 reason='interrupted by SIGTERM'
    [ "${initial_failure}" != 1 ] || { expected=23; reason='container start failed'; }
    if [ "${status}" != "${expected}" ] || [ ! -f "${prefix}.complete" ] ||
        ! grep -qx 'Status: FAILED' "${summary}" || ! grep -qx "Reason: ${reason}" "${summary}"; then
      echo "finalization ${phase}/${initial_failure}: cleanup, status or final summary lost" >&2
      finalization_failed=1; remember_host_failure "$LINENO"
    fi
    if bash "${repo_root}/.github/scripts/check-build-output.sh" validate "${summary%/*}" >/dev/null 2>&1; then
      echo 'interrupted finalization passed the output checker' >&2; finalization_failed=1; remember_host_failure "$LINENO"
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

# Exercise the production host import with the real Docker daemon. Only compilation
# is replaced with synthetic output; these controls do not claim a firmware build.
test_artifact_import_boundary() {
local artifact_bin real_docker attack outside log_path status summary expectations expected
artifact_bin="${tmp_dir}/artifact-bin"
mkdir -p "${artifact_bin}"
cat > "${artifact_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = exec ] && [[ "$*" == *'./build.sh build'* ]]; then
  exec "${ZMK_TEST_REAL_DOCKER}" exec "$2" /bin/bash -c '
    set -e
    output=/root/zmk-config/.build
    mkdir -p "$output"
    printf "synthetic firmware\n" > "$output/selected.bin"
    case "$1" in
      regular) chmod 4777 "$output/selected.bin" ;;
      log-link) ln -s "$2/canary" "$output/build.log" ;;
      summary-link) ln -s "$2" "$output/build-summary.txt" ;;
      firmware-link) rm "$output/selected.bin"; ln -s "$2/canary" "$output/selected.bin"; test -L "$output/selected.bin" ;;
      firmware-directory) rm "$output/selected.bin"; mkdir "$output/selected.bin"; ln -s "$2/canary" "$output/selected.bin/build.log" ;;
      firmware-fifo) rm "$output/selected.bin"; mkfifo "$output/selected.bin"; test -p "$output/selected.bin" ;;
      *) exit 99 ;;
    esac
    printf "Build complete: 1 target(s).\n"
  ' _ "${ZMK_TEST_ARTIFACT_ATTACK}" "${ZMK_TEST_HOST_CANARY}"
fi
exec "${ZMK_TEST_REAL_DOCKER}" "$@"
EOF
chmod +x "${artifact_bin}/docker"
real_docker="$(command -v docker)"
for attack in regular log-link summary-link firmware-link firmware-directory firmware-fifo; do
  echo "[build-contract] artifact-import-${attack} (synthetic output)"
  outside="${tmp_dir}/docker-artifact-${attack}"
  mkdir -p "${outside}"
  printf 'preserve host canary\n' > "${outside}/canary"
  log_path="${tmp_dir}/docker-artifact-${attack}.log"
  container_logs+=("${log_path}")
  if PATH="${artifact_bin}:${PATH}" ZMK_TEST_REAL_DOCKER="${real_docker}" \
      ZMK_TEST_ARTIFACT_ATTACK="${attack}" ZMK_TEST_HOST_CANARY="${outside}" ZMK_KEEP_CONTAINER=0 \
      bash "${tool_root}/build.sh" "${fixture}" > "${log_path}" 2>&1; then
    status=0
  else status=$?; fi
  summary="$(summary_from_log "${log_path}")"
  cmp "${outside}/canary" <(printf 'preserve host canary\n')
  [ "$(find "${outside}" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')" = 1 ]
  [ ! -L "${summary}" ] && [ ! -L "${summary%/*}/build.log" ]
  if [ "${attack}" = regular ]; then
    [ "${status}" = 0 ]
    expectations="${tmp_dir}/docker-artifact-regular.expect"
    printf '%s\0' image "${ZMK_BUILD_IMAGE}" target "$(cd "${fixture}" && pwd -P)" \
      cache "${ZMK_DOCKER_CACHE_VOLUME}" artifact selected.bin > "${expectations}"
    bash "${repo_root}/.github/scripts/check-build-output.sh" build "${summary%/*}" --expect "${expectations}"
    cmp "${summary%/*}/selected.bin" <(printf 'synthetic firmware\n')
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*) echo 'artifact-mode: NOT APPLICABLE (native Windows POSIX permission bits)' ;;
      *)
        if [ -z "$(find "${summary%/*}/selected.bin" -perm 0644 -print)" ]; then
          echo 'artifact-mode: container permissions were retained instead of normalized to 0644' >&2
          exit 1
        fi ;;
    esac
  else
    [ "${status}" != 0 ]
    grep -qx 'Status: FAILED' "${summary}"
    grep -qx 'Reason: artifact copy failed' "${summary}"
    case "${attack}" in
      log-link|summary-link) expected='artifact filename collides with host evidence' ;;
      firmware-link|firmware-fifo) expected='artifact is not a regular file|failed to copy build output from the container' ;;
      firmware-directory) expected='failed to copy build output from the container' ;;
    esac
    grep -Ex "${expected}" "${summary%/*}/build.log" >/dev/null || { cat "${log_path}" >&2; exit 1; }
    [ ! -e "${summary%/*}/selected.bin" ] && [ ! -L "${summary%/*}/selected.bin" ]
  fi
  [ "$(find "${summary%/*}" -mindepth 1 -maxdepth 1 -name 'artifact-tmp-*' | wc -l | tr -d '[:space:]')" = 0 ]
done
}

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
test_artifact_import_boundary

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
(cd "${repo_root}" && tar cf - .github/scripts/test-build-container.py .github/scripts/test-build-fixtures.sh \
  .github/fixtures/target-shapes-zmk-config/build.yaml scripts/source-common.sh \
  scripts/auto-build-external.sh scripts/build-external-source.sh .github/scripts/check-build-output.sh .github/workflows/*.yml) |
  docker exec -i -e ZMK_BUILD_IMAGE="${ZMK_BUILD_IMAGE}" "${last_container}" bash -c '
    set -eu
    mkdir -p /tmp/contract-inputs /tmp/workflows
    tar xf - -C /tmp/contract-inputs
    cp /tmp/contract-inputs/.github/scripts/test-build-container.py /tmp/
    cp /tmp/contract-inputs/.github/scripts/test-build-fixtures.sh /tmp/
    cp /tmp/contract-inputs/.github/fixtures/target-shapes-zmk-config/build.yaml /tmp/target-shapes.yaml
    cp /tmp/contract-inputs/scripts/*.sh /tmp/
    cp /tmp/contract-inputs/.github/scripts/check-build-output.sh /tmp/
    cp /tmp/contract-inputs/.github/workflows/*.yml /tmp/workflows/
    cp /tmp/workflows/auto-build.yml /tmp/
    exec python3 -u /tmp/test-build-container.py /tmp/target-shapes.yaml'

# Round-trip the actual pruned Linux tree through the same host-path helper as external clone.
(
  source "${repo_root}/scripts/build-external-source.sh"
  mkdir -p "${tmp_dir}/.clone destination 名前/returned files"
  docker_no_pathconv cp "${last_container}:/tmp/windows-copy/." "$(docker_host_path "${tmp_dir}/.clone destination 名前/returned files")"
)
[ "$(find "${tmp_dir}/.clone destination 名前/returned files" -type f | wc -l | tr -d '[:space:]')" = 11 ]
for file in keep.txt 'nested/valid name.txt' nested/COM0.txt nested/my..file.txt unicode-名前.txt $'DEL-\177.txt' COM⁴.txt \
    '-C' '--exclude=src' 'literal [ab] $value; & (test).txt' 'unicode-名前-📦.txt'; do
  cmp "${tmp_dir}/.clone destination 名前/returned files/${file}" <(printf 'clone payload\n')
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
summary="$(summary_from_log "${tmp_dir}/pristine-in-use.log")"
grep -qx 'Status: FAILED' "${summary}"
grep -qx 'Reason: cache reset failed' "${summary}"
grep -q 'volume is in use' "${summary%/*}/build.log"
[ "$(docker inspect -f '{{.State.Running}}' "${last_container}")" = true ]
docker volume inspect "${ZMK_DOCKER_CACHE_VOLUME}" >/dev/null

if [ "${ZMK_TEST_PROFILE:-0}" = 1 ]; then
  : "${ZMK_TEST_RESULTS:?Profiling requires the canonical test entry point}"
  profile_docker_exec() {
    local number
    for ((number=0; number<5; number++)); do
      docker exec "${last_container}" true || return "$?"
    done
  }
  TIMEFORMAT='%3R'
  profile_status=0
  { time profile_docker_exec > "${ZMK_TEST_RESULTS}/probe-docker-exec.log" 2>&1; } \
    2> "${ZMK_TEST_RESULTS}/probe-docker-exec.time" || profile_status=$?
  IFS= read -r profile_duration < "${ZMK_TEST_RESULTS}/probe-docker-exec.time"
  printf 'probe-docker-exec\t%s\t5\t%s\n' "${profile_status}" "${profile_duration}" >> "${ZMK_TEST_RESULTS}/profile.tsv"
  [ "${profile_status}" = 0 ] || exit "${profile_status}"
fi

echo "build host/copy contracts passed."
