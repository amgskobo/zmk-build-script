#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
builder="${repo_root}/scripts/auto-build-external.sh"
source_builder="${repo_root}/scripts/build-external-source.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zmk-external-test.XXXXXX")"
tmp_dir="$(cd "${tmp_dir}" && pwd -P)"

cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  printf '%s\n' "${haystack}" | grep -F -- "${needle}" >/dev/null ||
    fail "${label}: ${haystack}"
}

assert_file_contains() {
  local file="$1" needle="$2" label="$3"
  grep -F -- "${needle}" "${file}" >/dev/null ||
    fail "${label}: $(cat "${file}")"
}

# Bound tests of worker death and a zero-width queue without depending on GNU timeout on the host.
run_bounded() {
  local child timer status
  "$@" &
  child=$!
  (sleep 30; kill -TERM "${child}" 2>/dev/null || true) &
  timer=$!
  if wait "${child}"; then status=0; else status=$?; fi
  kill "${timer}" 2>/dev/null || true
  wait "${timer}" 2>/dev/null || true
  return "${status}"
}

local_one="${tmp_dir}/local-one"
local_two="${tmp_dir}/local-two"
local_three="${tmp_dir}/local-three"
mkdir -p "${local_one}/config" "${local_two}/config" "${local_three}/config"
touch "${local_one}/config/west.yml" "${local_one}/build.yaml"
touch "${local_two}/config/west.yml" "${local_two}/build.yaml"
touch "${local_three}/config/west.yml" "${local_three}/build.yaml"

repos_file="${tmp_dir}/repos.txt"
cat > "${repos_file}" <<'EOF'
# comments and blank lines are ignored
https://github.com/caksoylar/zmk-config.git

https://github.com/urob/zmk-config.git
git@github.com:GEIGEIGEIST/zmk-config-totem.git
git://github.com/example/zmk-config.git
file:///tmp/zmk-config.git
path:local-one
local-two
https://github.com/caksoylar/zmk-config.git
EOF

list="$(bash "${builder}" --list "${repos_file}")"
json="$(bash "${builder}" --list-json "${repos_file}")"

assert_contains "${list}" $'caksoylar-zmk-config\tzmk-cache-external-caksoylar-zmk-config\trepo\thttps://github.com/caksoylar/zmk-config.git' \
  "list did not include caksoylar slug"
assert_contains "${list}" $'urob-zmk-config\tzmk-cache-external-urob-zmk-config\trepo\thttps://github.com/urob/zmk-config.git' \
  "list did not include urob slug"
assert_contains "${list}" $'geigeigeist-zmk-config-totem\tzmk-cache-external-geigeigeist-zmk-config-totem\trepo\tgit@github.com:GEIGEIGEIST/zmk-config-totem.git' \
  "list did not include ssh slug"
assert_contains "${list}" $'example-zmk-config\tzmk-cache-external-example-zmk-config\trepo\tgit://github.com/example/zmk-config.git' \
  "list did not include git protocol slug"
assert_contains "${list}" $'tmp-zmk-config\tzmk-cache-external-tmp-zmk-config\trepo\tfile:///tmp/zmk-config.git' \
  "list did not include file protocol slug"
assert_contains "${list}" $'local-one\tzmk-cache-external-local-one\tpath\t'"${local_one}" \
  "list did not include prefixed local path"
assert_contains "${list}" $'local-two\tzmk-cache-external-local-two\tpath\t'"${local_two}" \
  "list did not include inferred local path"
assert_contains "${list}" $'caksoylar-zmk-config-2\tzmk-cache-external-caksoylar-zmk-config-2\trepo\thttps://github.com/caksoylar/zmk-config.git' \
  "duplicate slug was not made unique"
assert_contains "${json}" '"slug":"caksoylar-zmk-config"' \
  "json list did not include caksoylar slug"
assert_contains "${json}" '"type":"repo"' \
  "json list did not include repo type"
assert_contains "${json}" '"index":1,"slug":' \
  "json matrix did not start with a numeric public source index"
assert_contains "${json}" '"index":8,"slug":' \
  "json matrix indices did not cover every source"
assert_contains "${json}" '"source":"https://github.com/caksoylar/zmk-config.git"' \
  "json list did not include repo source"

indices="$(bash "${builder}" --list-indices-json "${repos_file}")"
[ "${indices}" = '{"include":[{"index":1},{"index":2},{"index":3},{"index":4},{"index":5},{"index":6},{"index":7},{"index":8}]}' ] ||
  fail 'public matrix contains something other than numeric indices'
selected="$(bash "${builder}" --list "${repos_file}" --source-index 0008)"
[ "${selected}" = "$(printf '%s\n' "${list}" | tail -n 1)" ] || fail 'indexed selection changed a collision-resolved slug'
for format in --list-json --list-indices-json; do
  selected="$(bash "${builder}" "${format}" "${repos_file}" --source-index 0008)"
  assert_contains "${selected}" '"index":8' 'JSON selection renumbered the original source index'
done

# Pins are list data; changing the default branch must not change selected inputs.
revision_one=1111111111111111111111111111111111111111
revision_two=2222222222222222222222222222222222222222
pinned_file="${tmp_dir}/pinned sources.txt"
printf '%s %s\n%s\t%s\npath:local source with spaces\n' \
  https://example.invalid/config.git "${revision_one}" \
  repo:https://example.invalid/config.git "${revision_two}" > "${pinned_file}"
pinned="$(bash "${builder}" --list-json "${pinned_file}")"
assert_contains "${pinned}" '"source":"https://example.invalid/config.git","revision":"'"${revision_one}"'"' 'space-separated revision was lost'
assert_contains "${pinned}" '"slug":"config-2"' 'revision changed slug collision handling'
assert_contains "${pinned}" '"revision":"'"${revision_two}"'"' 'TAB-separated revision was lost'
assert_contains "${pinned}" 'local source with spaces","revision":""' 'local path was split as a repository pin'
selected="$(bash "${builder}" --list-json "${pinned_file}" --source-index 2)"
assert_contains "${selected}" '"index":2' 'pinned selection changed the original index'
assert_contains "${selected}" '"revision":"'"${revision_two}"'"' 'indexed selection lost its revision'
case "${selected}" in *"${revision_one}"*) fail 'indexed selection retained the wrong revision' ;; esac
selected="$(bash "${builder}" --list-json --repo https://example.invalid/config.git --revision "${revision_one}")"
assert_contains "${selected}" '"revision":"'"${revision_one}"'"' 'explicit revision was lost'
for bad_revision in main v1.0 short 000000000000000000000000000000000000000G; do
  printf 'https://example.invalid/config.git %s\n' "${bad_revision}" > "${tmp_dir}/bad-pin.txt"
  if bash "${builder}" --list "${tmp_dir}/bad-pin.txt" >"${tmp_dir}/bad-pin.out" 2>&1; then fail 'mutable or malformed revision was accepted'; fi
  assert_file_contains "${tmp_dir}/bad-pin.out" 'full 40-character' 'revision rejection did not reach its validator'
done
if bash "${builder}" --list --path "${local_one}" --revision "${revision_one}" >"${tmp_dir}/bad-pin.out" 2>&1; then fail 'revision was accepted for a local path'; fi
assert_file_contains "${tmp_dir}/bad-pin.out" '--revision must follow --repo' 'local-path revision guard was not reached'

pin_probe="${tmp_dir}/pin-probe.sh"
printf '#!/usr/bin/env bash\nprintf '\''%%s\\0'\'' "$@" > "$PIN_ARGV"\n' > "${pin_probe}"
# Define each budget independently of the invoking runner. Keep exact argv checks
# for the selected pin while covering defaults, environment and CLI precedence.
for budget in default environment leading-zero cli-override; do
  case "${budget}" in
    default) expected_jobs=1 ;;
    environment) expected_jobs=2 ;;
    leading-zero) expected_jobs=0002 ;;
    cli-override) expected_jobs=3 ;;
  esac
  (
    unset ZMK_BUILD_JOBS
    jobs_args=()
    case "${budget}" in
      environment|cli-override) export ZMK_BUILD_JOBS=2 ;;
      leading-zero) export ZMK_BUILD_JOBS=0002 ;;
    esac
    [ "${budget}" != cli-override ] || jobs_args+=(--jobs 3)
    PIN_ARGV="${tmp_dir}/pinned.argv" ZMK_EXTERNAL_SOURCE_BUILDER="${pin_probe}" \
      bash "${builder}" --sources-file "${pinned_file}" --source-index 2 --mode validate \
      ${jobs_args[@]+"${jobs_args[@]}"} > "${tmp_dir}/pin-probe.out"
  )
  printf '%s\0' --repo https://example.invalid/config.git --revision "${revision_two}" \
    --source-slug config-2 --mode validate --jobs "${expected_jobs}" > "${tmp_dir}/expected-pinned.argv"
  cmp "${tmp_dir}/expected-pinned.argv" "${tmp_dir}/pinned.argv" || fail "worker pin/budget argv mismatch: ${budget}"
done

# Every repository in the maintained default list needs a pin, independent of its size.
default_list="$(bash "${builder}" --list "${repo_root}/repos.txt")"
printf '%s\n' "${default_list}" | awk -F '\t' '
  $3 == "repo" { count++; if (length($5) != 40 || $5 ~ /[^0-9a-f]/) exit 1 }
  END { if (!count) exit 1 }
' || fail 'default external repository list contains missing or malformed pins'
for bad_revision in main short 000000000000000000000000000000000000000G; do
  if bash "${source_builder}" --repo https://example.invalid/config.git --revision "${bad_revision}" >"${tmp_dir}/bad-worker-pin.out" 2>&1; then
    fail 'worker accepted a mutable or malformed revision'
  fi
  assert_file_contains "${tmp_dir}/bad-worker-pin.out" 'full 40-character' 'worker pin guard was not reached before Docker'
done
if bash "${source_builder}" --path "${local_one}" --revision "${revision_one}" >"${tmp_dir}/bad-worker-pin.out" 2>&1; then fail 'worker accepted a local-path revision'; fi
assert_file_contains "${tmp_dir}/bad-worker-pin.out" '--revision requires a repository source' 'worker local-path pin guard was not reached'
# Every JSON control byte must be escaped, including legal bytes inside Unix paths.
for number in $(seq 1 31); do
  printf -v octal '%03o' "${number}"
  printf -v character '%b' "\\${octal}"
  value="synthetic${character}path"
  json="$(bash "${builder}" --list-json --path "${value}")"
  case "${json}" in *"${character}"*) fail 'JSON output contains an unescaped control byte' ;; esac
done
for invalid in '' 0 00 9 bad -1; do
  if bash "${builder}" --list "${repos_file}" --source-index "${invalid}" >/dev/null 2>&1; then
    fail 'invalid source index was accepted'
  fi
done

path_list="$(bash "${builder}" --list --path "${local_one}" --repo-slug custom-local --path "${local_two}")"
assert_contains "${path_list}" $'custom-local\tzmk-cache-external-custom-local\tpath\t'"${local_one}" \
  "explicit path slug was not honored"
assert_contains "${path_list}" $'local-two\tzmk-cache-external-local-two\tpath\t'"${local_two}" \
  "second explicit path was not listed"

path_cases_file="${tmp_dir}/path-cases.txt"
cat > "${path_cases_file}" <<'EOF'
path://server/share
path:\\server\share
path:C:relative
EOF
path_cases="$(bash "${builder}" --list "${path_cases_file}")"
assert_contains "${path_cases}" $'share\tzmk-cache-external-share\tpath\t//server/share' \
  "UNC slash path was not treated as absolute"
assert_contains "${path_cases}" $'share-2\tzmk-cache-external-share-2\tpath\t\\\\server\\share' \
  "UNC backslash path was not treated as absolute"
assert_contains "${path_cases}" $'c-relative\tzmk-cache-external-c-relative\tpath\t'"${tmp_dir}/C:relative" \
  "drive-relative path was not resolved from the source file"

empty_file="${tmp_dir}/empty.txt"
printf '# no sources\n\n' > "${empty_file}"
[ -z "$(bash "${builder}" --list "${empty_file}")" ] ||
  fail "empty sources file did not produce an empty list"

missing_path="${tmp_dir}/missing"
failure_output="${tmp_dir}/failure.out"
failure_summary="${tmp_dir}/summary.md"

set +e
GITHUB_ACTIONS=true \
  GITHUB_STEP_SUMMARY="${failure_summary}" \
  bash "${builder}" --path "${missing_path}" --source-slug missing --source-jobs 1 > "${failure_output}" 2>&1
failure_status=$?
set -e

[ "${failure_status}" -eq 1 ] ||
  fail "missing source did not fail with status 1: ${failure_status}"
assert_file_contains "${failure_output}" "::error title=External source execution failed::path not found" \
  "failure annotation was not emitted"
assert_file_contains "${failure_output}" "path not found missing" \
  "missing path failure was not printed"
assert_file_contains "${failure_summary}" '| failure | build |' \
  "failure summary row was not written"
if grep -Fq "${missing_path}" "${failure_summary}" ||
    grep '^::error ' "${failure_output}" | grep -Fq "${missing_path}"; then
  fail 'public summary or annotation disclosed a private source path'
fi

invalid_output="${tmp_dir}/invalid.out"
set +e
bash "${builder}" --path "${missing_path}" --source-jobs 0 > "${invalid_output}" 2>&1
invalid_status=$?
set -e

[ "${invalid_status}" -eq 1 ] ||
  fail "invalid source jobs did not fail with status 1: ${invalid_status}"
assert_file_contains "${invalid_output}" "source jobs must be a positive integer" \
  "invalid source jobs error was not printed"

set +e
bash "${source_builder}" --path "${missing_path}" --source-slug missing-direct > "${tmp_dir}/direct.out" 2>&1
direct_status=$?
set -e

[ "${direct_status}" -eq 1 ] ||
  fail "direct missing source did not fail with status 1: ${direct_status}"
assert_file_contains "${tmp_dir}/direct.out" "path not found missing-direct" \
  "direct source helper did not fail before Docker"

set +e
ZMK_EXTERNAL_CLONE_ATTEMPTS=0 \
  bash "${source_builder}" --path "${missing_path}" --source-slug invalid-clone-attempts > "${tmp_dir}/invalid-clone-attempts.out" 2>&1
invalid_clone_attempts_status=$?
set -e

[ "${invalid_clone_attempts_status}" -eq 1 ] ||
  fail "invalid clone attempts did not fail with status 1: ${invalid_clone_attempts_status}"
assert_file_contains "${tmp_dir}/invalid-clone-attempts.out" "clone attempts must be a positive integer" \
  "invalid clone attempts error was not printed"

fake_builder="${tmp_dir}/fake-source-builder.sh"
fake_log="${tmp_dir}/fake-builder.log"
cat > "${fake_builder}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

slug=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-slug)
      slug="$2"
      shift
      ;;
  esac
  shift
done

printf 'start %s\n' "${slug}" >> "${FAKE_LOG}"
case "${slug}" in
  slow) sleep 2 ;;
  killed) kill -KILL "$$"; exit 0 ;;
  failed) exit 7 ;;
esac
printf 'end %s\n' "${slug}" >> "${FAKE_LOG}"
EOF

ZMK_EXTERNAL_SOURCE_BUILDER="${fake_builder}" \
  FAKE_LOG="${fake_log}" \
  bash "${builder}" \
    --path "${local_one}" --source-slug slow \
    --path "${local_two}" --source-slug fast \
    --path "${local_three}" --source-slug third \
    --source-jobs 02 \
    --mode validate \
    --jobs 01 > "${tmp_dir}/rolling.out" 2>&1

third_start_line="$(grep -n '^start third$' "${fake_log}" | sed -n '1s/:.*//p')"
slow_end_line="$(grep -n '^end slow$' "${fake_log}" | sed -n '1s/:.*//p')"
[ -n "${third_start_line}" ] && [ -n "${slow_end_line}" ] ||
  fail "rolling source log was incomplete: $(cat "${fake_log}")"
[ "${third_start_line}" -lt "${slow_end_line}" ] ||
  fail "source queue waited for the slow batch instead of filling an open slot: $(cat "${fake_log}")"

# All-zero decimal spellings must be rejected, including queue width and clone attempts.
for option in --jobs --source-jobs; do
  if run_bounded bash "${builder}" --path "${missing_path}" "${option}" 00 >"${tmp_dir}/zero.out" 2>&1; then
    fail "${option} 00 was accepted"
  fi
  assert_file_contains "${tmp_dir}/zero.out" 'must be a positive integer: 00' "all-zero ${option} was not rejected"
done
if ZMK_EXTERNAL_CLONE_ATTEMPTS=00 bash "${source_builder}" --path "${missing_path}" >"${tmp_dir}/clone-zero.out" 2>&1; then
  fail 'all-zero clone attempts were accepted'
fi
assert_file_contains "${tmp_dir}/clone-zero.out" 'clone attempts must be a positive integer: 00' 'all-zero clone attempts were not rejected'

# A source worker killed before it can publish a status must fail promptly and release its queue slot.
set +e
ZMK_EXTERNAL_SOURCE_BUILDER="${fake_builder}" FAKE_LOG="${fake_log}" \
  run_bounded bash "${builder}" \
    --path "${local_one}" --source-slug killed \
    --path "${local_two}" --source-slug failed \
    --path "${local_three}" --source-slug after-kill \
    --source-jobs 1 >"${tmp_dir}/killed.out" 2>&1
killed_status=$?
set -e
[ "${killed_status}" -eq 1 ] || fail "worker death did not finish with failure status: ${killed_status}"
assert_file_contains "${tmp_dir}/killed.out" 'killed: failure' 'killed source was not recorded'
assert_file_contains "${tmp_dir}/killed.out" 'failed: failure' 'ordinary child failure was not preserved'
assert_file_contains "${tmp_dir}/killed.out" 'after-kill: success' 'queue did not continue after worker death'
assert_file_contains "${tmp_dir}/killed.out" '=== Done: 2 failure(s) ===' 'worker failure total was incorrect'

# Exercise process-group cancellation in the native Linux/macOS/Git Bash matrix.
cancel_root="${tmp_dir}/cancellation"
mkdir "${cancel_root}"
cat > "${cancel_root}/worker.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
slug=
child=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --source-slug ]; then slug="$2"; shift; fi
  shift
done
stop() {
  trap '' INT TERM
  [ -z "$child" ] || kill -TERM "$child" 2>/dev/null || true
  [ -z "$child" ] || wait "$child" 2>/dev/null || true
  : > "${CANCEL_ROOT}/${slug}.stopped"
  exit 143
}
trap stop TERM
sleep 30 &
child=$!
: > "${CANCEL_ROOT}/${slug}.started"
wait "$child"
EOF
CANCEL_ROOT="${cancel_root}" ZMK_EXTERNAL_SOURCE_BUILDER="${cancel_root}/worker.sh" \
  bash "${builder}" --path "${local_one}" --source-slug first \
    --path "${local_two}" --source-slug second --path "${local_three}" --source-slug pending \
    --source-jobs 2 >"${cancel_root}/console" 2>&1 &
coordinator=$!
(sleep 30; kill -KILL "${coordinator}" 2>/dev/null || true) &
cancel_timer=$!
for attempt in $(seq 1 100); do
  [ ! -f "${cancel_root}/first.started" ] || [ ! -f "${cancel_root}/second.started" ] || break
  sleep .05
done
kill -TERM "${coordinator}"
if wait "${coordinator}"; then cancel_status=0; else cancel_status=$?; fi
kill "${cancel_timer}" 2>/dev/null || true
wait "${cancel_timer}" 2>/dev/null || true
[ "${cancel_status}" = 143 ] || fail "coordinator cancellation returned ${cancel_status}"
[ -f "${cancel_root}/first.stopped" ] && [ -f "${cancel_root}/second.stopped" ] || \
  fail 'coordinator returned before active workers stopped'
[ ! -f "${cancel_root}/pending.started" ] || fail 'cancellation started a pending source'

# Clone setup must never remove a pre-existing name after create fails. Later failures
# must remove only containers created by this process, including each failed retry.
clone_bin="${tmp_dir}/clone-bin"
mkdir -p "${clone_bin}"
cat > "${clone_bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CLONE_TEST_LOG}"
case "$1" in
  info) exit 0 ;;
  rm)
    case "${CLONE_TEST_PHASE}" in
      cleanup|start-cleanup) echo 'injected clone container removal failure' >&2; exit 23 ;;
    esac ;;
  create)
    [ "${CLONE_TEST_PHASE}" != create ] || exit 23
    counter="${CLONE_TEST_LOG}.count"
    attempt=0
    [ ! -f "${counter}" ] || read -r attempt < "${counter}"
    attempt=$((attempt + 1))
    printf '%s\n' "${attempt}" > "${counter}"
    printf '%064d\n' "${attempt}" ;;
  start)
    case "${CLONE_TEST_PHASE}" in start|start-cleanup) exit 23 ;; esac ;;
  cp)
    if [ "${CLONE_TEST_PHASE}" = partial ]; then
      mkdir -p "$3"
      printf 'partial source\n' > "$3/fresh.txt"
      exit 23
    fi
    case "${CLONE_TEST_PHASE}" in success|cleanup) ;; *) exit 23 ;; esac
    mkdir -p "$3"
    printf 'fresh source\n' > "$3/fresh.txt" ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${clone_bin}/docker"
for phase in create start copy; do
  clone_log="${tmp_dir}/clone-${phase}.commands"
  if PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE="${phase}" \
      ZMK_EXTERNAL_CLONE_ATTEMPTS=2 bash "${source_builder}" \
      --repo https://example.invalid/zmk-config.git --source-slug "test-clone-${phase}-$$" >"${tmp_dir}/clone-${phase}.out" 2>&1; then
    fail "injected clone ${phase} failure was accepted"
  fi
  if [ "${phase}" = create ]; then
    if grep -q '^rm ' "${clone_log}"; then fail 'a failed clone create removed an unowned container'; fi
  else
    expected=2
    [ "${phase}" != copy ] || expected=1
    actual="$(grep -c '^rm ' "${clone_log}")"
    [ "${actual}" -eq "${expected}" ] || fail "clone ${phase} cleanup count: expected ${expected}, got ${actual}"
    for ((attempt=1; attempt<=expected; attempt++)); do
      expected_id="$(printf '%064d' "${attempt}")"
      grep -qx "rm -f ${expected_id}" "${clone_log}" || fail "clone ${phase} cleanup used a replaceable name: $(cat "${clone_log}")"
      grep -qx "start -a ${expected_id}" "${clone_log}" || fail "clone ${phase} start used a replaceable name: $(cat "${clone_log}")"
    done
    if [ "${phase}" = copy ]; then
      grep -q "^cp ${expected_id}:/tmp/source/\. " "${clone_log}" || fail "clone copy used a replaceable name: $(cat "${clone_log}")"
    fi
  fi
  if [ "${phase}" != copy ]; then
    actual="$(grep -c '^create ' "${clone_log}")"
    [ "${actual}" -eq 2 ] || fail "clone ${phase} retry count: ${actual}"
  fi
done

# A failed removal must not merge a fresh clone into stale host content.
clone_parent="${tmp_dir}/clone-clear"
clone_target="${clone_parent}/blocked"
mkdir -p "${clone_target}"
printf 'stale source\n' > "${clone_target}/stale.txt"
clone_real_rm="$(command -v rm)"
cat > "${clone_bin}/rm" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "${arg}" = "${CLONE_FAIL_RM_TARGET}" ]; then
    echo 'injected clone cleanup failure' >&2
    exit 23
  fi
done
exec "${CLONE_REAL_RM}" "$@"
EOF
chmod +x "${clone_bin}/rm"
clone_log="${tmp_dir}/clone-clear.commands"
if PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE=copy \
    CLONE_FAIL_RM_TARGET="${clone_target}" CLONE_REAL_RM="${clone_real_rm}" \
    bash -c 'source "$1"; WORK_DIR="$2"; main --repo https://example.invalid/config.git --source-slug blocked' \
    _ "${source_builder}" "${clone_parent}" >"${tmp_dir}/clone-clear.out" 2>&1; then
  fail 'failed clone destination cleanup was accepted'
fi
assert_file_contains "${tmp_dir}/clone-clear.out" 'injected clone cleanup failure' 'cleanup injection did not run'
[ -f "${clone_target}/stale.txt" ] || fail 'cleanup injection did not preserve stale source'
if grep -q '^create ' "${clone_log}"; then
  fail "clone started after destination cleanup failed: $(cat "${clone_log}")"
fi

# Once cleanup works again, no stale file may reach the builder.
rm "${clone_bin}/rm"
clone_probe="${tmp_dir}/clone-probe.sh"
cat > "${clone_probe}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" != validate ] || shift
[ ! -e "$1/stale.txt" ]
grep -qx 'fresh source' "$1/fresh.txt"
printf 'builder reached\n' >> "${CLONE_TEST_LOG}"
exit "${CLONE_BUILD_EXIT:-0}"
EOF
chmod +x "${clone_probe}"
if ! PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE=success \
    bash -c 'source "$1"; WORK_DIR="$2"; BUILD_SCRIPT="$3"; main --repo https://example.invalid/config.git --source-slug blocked --mode build' \
    _ "${source_builder}" "${clone_parent}" "${clone_probe}" >"${tmp_dir}/clone-recovered.out" 2>&1; then
  fail "clone did not recover after destination cleanup was repaired: $(cat "${tmp_dir}/clone-recovered.out")"
fi
[ ! -e "${clone_target}" ] || fail 'successful clone left its host copy behind'
[ "$(grep -c '^create ' "${clone_log}")" = 1 ] || fail 'failed cleanup started an extra clone'
expected_id="$(printf '%064d' 1)"
grep -qx "rm -f ${expected_id}" "${clone_log}" || fail 'recovered clone lost container ownership'

# A failed clone-container cleanup must stop before another create or builder start.
for phase in cleanup start-cleanup; do
  clone_log="${tmp_dir}/clone-${phase}.commands"
  if PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE="${phase}" \
      bash -c 'source "$1"; WORK_DIR="$2"; BUILD_SCRIPT="$3"; main --repo https://example.invalid/config.git --source-slug cleanup --mode build' \
      _ "${source_builder}" "${clone_parent}" "${clone_probe}" >"${tmp_dir}/clone-${phase}.out" 2>&1; then
    fail "clone ${phase} ignored container cleanup failure"
  fi
  assert_file_contains "${tmp_dir}/clone-${phase}.out" 'failed to remove clone container' 'clone cleanup diagnostics missing'
  [ "$(grep -c '^create ' "${clone_log}")" = 1 ] || fail 'clone retried after container cleanup failure'
  if grep -q 'builder reached' "${clone_log}"; then fail 'builder started after clone cleanup failure'; fi
  if grep '^rm ' "${clone_log}" | grep -vx "rm -f ${expected_id}"; then fail 'clone cleanup changed its immutable ID'; fi
done

# Cache deletion belongs to build.sh; both wrapper modes must forward --pristine.
forward_probe="${tmp_dir}/forward-probe.sh"
cat > "${forward_probe}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FORWARD_LOG}"
EOF
chmod +x "${forward_probe}"
for mode in build validate; do
  clone_log="${tmp_dir}/pristine-${mode}.commands"
  forward_log="${tmp_dir}/pristine-${mode}.args"
  PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE=success FORWARD_LOG="${forward_log}" \
    bash -c 'source "$1"; BUILD_SCRIPT="$2"; main --path "$3" --source-slug delegated --mode "$4" --pristine' \
    _ "${source_builder}" "${forward_probe}" "${local_one}" "${mode}" >"${tmp_dir}/pristine-${mode}.out" 2>&1
  grep -qx -- --pristine "${forward_log}" || fail "${mode} did not forward pristine"
  if grep -q '^volume ' "${clone_log}"; then fail 'wrapper reset the cache outside builder recording'; fi
done

# Post-build clone removal must complete before success, and preserve build failure details.
post_failed=0
post_target="${clone_parent}/post-cleanup"
cat > "${clone_bin}/rm" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "${arg}" = "${CLONE_FAIL_RM_TARGET}" ] && [ -f "${arg}/fresh.txt" ]; then
    printf 'host cleanup blocked\n' >> "${CLONE_TEST_LOG}"
    echo 'injected post-copy host cleanup failure' >&2
    exit 23
  fi
done
exec "${CLONE_REAL_RM}" "$@"
EOF
chmod +x "${clone_bin}/rm"
for mode in build validate; do
  for build_status in 0 23; do
    clone_log="${tmp_dir}/post-${mode}-${build_status}.commands"
    step_summary="${tmp_dir}/post-${mode}-${build_status}.summary"
    : > "${step_summary}"
    if PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE=success \
        CLONE_BUILD_EXIT="${build_status}" CLONE_FAIL_RM_TARGET="${post_target}" CLONE_REAL_RM="${clone_real_rm}" \
        GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="${step_summary}" \
        bash -c 'source "$1"; WORK_DIR="$2"; BUILD_SCRIPT="$3"; main --repo https://example.invalid/config.git --source-slug post-cleanup --mode "$4"' \
        _ "${source_builder}" "${clone_parent}" "${clone_probe}" "${mode}" >"${tmp_dir}/post-${mode}-${build_status}.out" 2>&1; then
      status=0
    else status=$?; fi
    reason='clone cleanup failed'
    [ "${build_status}" = 0 ] || reason="${mode} failed; clone cleanup failed"
    if [ "${status}" != 1 ] || ! grep -Fq "${reason}" "${step_summary}" ||
        ! grep -q 'failed to clear clone destination' "${tmp_dir}/post-${mode}-${build_status}.out" ||
        grep -q '=== SUCCESS:' "${tmp_dir}/post-${mode}-${build_status}.out"; then
      echo "post-build cleanup ${mode}/${build_status}: failure status/reason lost or success published" >&2
      post_failed=1
    fi
    grep -q 'host cleanup blocked' "${clone_log}" || fail 'post-build cleanup injection was not reached'
    grep -q 'builder reached' "${clone_log}" || fail 'post-build test never reached the builder'
    [ -f "${post_target}/fresh.txt" ] || fail 'post-build injection did not retain the blocked copy'
    "${clone_real_rm}" -rf "${post_target}"
  done
done

# A partial docker cp must also retain its clone failure plus a host cleanup failure.
clone_log="${tmp_dir}/post-partial.commands"
step_summary="${tmp_dir}/post-partial.summary"
if PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE=partial \
    CLONE_FAIL_RM_TARGET="${post_target}" CLONE_REAL_RM="${clone_real_rm}" \
    GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="${step_summary}" \
    bash -c 'source "$1"; WORK_DIR="$2"; BUILD_SCRIPT="$3"; main --repo https://example.invalid/config.git --source-slug post-cleanup' \
    _ "${source_builder}" "${clone_parent}" "${clone_probe}" >"${tmp_dir}/post-partial.out" 2>&1; then
  post_failed=1
fi
if ! grep -Fq 'clone failed; clone cleanup failed' "${step_summary}"; then
  echo 'partial clone copy lost its cleanup failure reason' >&2; post_failed=1
fi
[ -f "${post_target}/fresh.txt" ] || fail 'partial copy failure injection never reached host'
if grep -q 'builder reached' "${clone_log}"; then fail 'partial clone reached the builder'; fi
"${clone_real_rm}" -rf "${post_target}"

# Local source directories are never owned clone copies, including on build failure.
printf 'fresh source\n' > "${local_one}/fresh.txt"
for build_status in 0 23; do
  clone_log="${tmp_dir}/post-local-${build_status}.commands"
  : > "${clone_log}"
  if PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE=success \
      CLONE_BUILD_EXIT="${build_status}" CLONE_FAIL_RM_TARGET="${local_one}" CLONE_REAL_RM="${clone_real_rm}" \
      bash -c 'source "$1"; BUILD_SCRIPT="$2"; main --path "$3" --source-slug local-control' \
      _ "${source_builder}" "${clone_probe}" "${local_one}" >"${tmp_dir}/post-local-${build_status}.out" 2>&1; then
    status=0
  else status=$?; fi
  expected=0
  [ "${build_status}" = 0 ] || expected=1
  [ "${status}" = "${expected}" ] || fail 'local source control returned the wrong status'
  grep -qx 'fresh source' "${local_one}/fresh.txt" || fail 'local source was removed'
  if grep -q 'host cleanup blocked' "${clone_log}"; then fail 'local source was targeted for cleanup'; fi
done

# Once host removal is repaired, success and failure paths both remove the copy.
rm "${clone_bin}/rm"
for mode in build validate; do
  for build_status in 0 23; do
    clone_log="${tmp_dir}/post-repaired-${mode}-${build_status}.commands"
    step_summary="${tmp_dir}/post-repaired-${mode}-${build_status}.summary"
    if PATH="${clone_bin}:${PATH}" CLONE_TEST_LOG="${clone_log}" CLONE_TEST_PHASE=success \
        CLONE_BUILD_EXIT="${build_status}" GITHUB_STEP_SUMMARY="${step_summary}" \
        bash -c 'source "$1"; WORK_DIR="$2"; BUILD_SCRIPT="$3"; main --repo https://example.invalid/config.git --source-slug post-cleanup --mode "$4"' \
        _ "${source_builder}" "${clone_parent}" "${clone_probe}" "${mode}" >"${tmp_dir}/post-repaired-${mode}-${build_status}.out" 2>&1; then
      status=0
    else status=$?; fi
    expected=0
    [ "${build_status}" = 0 ] || expected=1
    [ "${status}" = "${expected}" ] || fail 'repaired cleanup changed the build result'
    [ ! -e "${post_target}" ] || fail 'repaired host removal left the clone behind'
  done
done
[ "${post_failed}" = 0 ] || fail 'post-build or partial-clone cleanup failures were accepted'

# Cleanup owns only immediate children of the resolved clone root.
foreign_clone="${tmp_dir}/foreign clone"
mkdir -p "${foreign_clone}"
printf 'preserve foreign content\n' > "${foreign_clone}/keep.txt"
for rejected in "${foreign_clone}" "${clone_parent}" "${clone_parent}/.."; do
  if bash -c 'source "$1"; WORK_DIR="$2"; clear_clone_directory "$3"' \
      _ "${source_builder}" "${clone_parent}" "${rejected}" >"${tmp_dir}/cleanup-root-guard.out" 2>&1; then
    fail 'cleanup accepted a path outside its owned clone child'
  fi
  assert_file_contains "${tmp_dir}/cleanup-root-guard.out" 'refusing to clear path outside clone root' 'cleanup root guard was not reached'
  grep -qx 'preserve foreign content' "${foreign_clone}/keep.txt" || fail 'foreign cleanup control was removed'
done

echo "[test-auto-build-external] ok"
