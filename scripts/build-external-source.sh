#!/usr/bin/env bash
set -euo pipefail

# build-external-source.sh - URL または local path 1 件を単体 build.sh process へ渡す。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
source "${SCRIPT_DIR}/source-common.sh"

BUILD_SCRIPT="$REPO_ROOT/build.sh"
WORK_DIR="$REPO_ROOT/.build/external"
ZMK_EXTERNAL_CACHE_PREFIX="${ZMK_EXTERNAL_CACHE_PREFIX:-zmk-cache-external}"
ZMK_EXTERNAL_CLONE_IMAGE="${ZMK_EXTERNAL_CLONE_IMAGE:-zmkfirmware/zmk-build-arm:stable}"
ZMK_EXTERNAL_CLONE_ATTEMPTS="${ZMK_EXTERNAL_CLONE_ATTEMPTS:-3}"
ZMK_EXTERNAL_MODE="${ZMK_EXTERNAL_MODE:-build}"
BUILD_JOBS="${ZMK_BUILD_JOBS:-1}"
ZMK_EXTERNAL_PRISTINE="${ZMK_EXTERNAL_PRISTINE:-0}"
ZMK_EXTERNAL_SETTINGS_RESET="${ZMK_EXTERNAL_SETTINGS_RESET:-0}"

SOURCE_TYPE=""
SOURCE_VALUE=""
SOURCE_SLUG=""
build_snippets=()
build_modules=()
positionals=()

usage() {
    cat <<'EOF'
Usage:
  bash scripts/build-external-source.sh --repo <git-url> [--source-slug <slug>] [--jobs N]
  bash scripts/build-external-source.sh --path <zmk-config-root> [--source-slug <slug>] [--jobs N]
  bash scripts/build-external-source.sh <git-url-or-path> [--jobs N]

Runs exactly one source build. Use auto-build-external.sh or GitHub Actions
matrix to start multiple copies in parallel.

Options:
  --mode build|validate   Select firmware build or configuration validation (default: build).
  --pristine              Reset the selected source cache before building.
  --settings-reset        Add missing settings_reset targets.
  -S, --snippet NAME      Append a snippet to every target; repeatable.
  -m, --module DIR        Pass an explicit module directory; repeatable.

See README.md or README.ja.md for environment variables and runner setup.
EOF
}

classify_source() {
    local raw trimmed
    raw="$1"
    trimmed="$(trim_line "${raw}")"
    case "${trimmed}" in
        repo:*)
            SOURCE_TYPE="repo"
            SOURCE_VALUE="${trimmed#repo:}"
            ;;
        url:*)
            SOURCE_TYPE="repo"
            SOURCE_VALUE="${trimmed#url:}"
            ;;
        path:*)
            SOURCE_TYPE="path"
            SOURCE_VALUE="${trimmed#path:}"
            ;;
        *)
            if is_repo_url "${trimmed}"; then
                SOURCE_TYPE="repo"
            else
                SOURCE_TYPE="path"
            fi
            SOURCE_VALUE="${trimmed}"
            ;;
    esac
    SOURCE_VALUE="$(trim_line "${SOURCE_VALUE}")"
}

resolve_path_source() {
    local path="$1"
    if is_absolute_path "${path}"; then
        printf '%s\n' "${path}"
    else
        printf '%s\n' "${REPO_ROOT}/${path}"
    fi
}

docker_no_pathconv() {
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker "$@"
}

require_docker() {
    command -v docker >/dev/null 2>&1 || { echo "ERROR: Missing required command: docker" >&2; exit 1; }
    docker_no_pathconv info >/dev/null 2>&1 || { echo "ERROR: Docker daemon is not available." >&2; exit 1; }
}

host_is_windows() {
    local os
    os="$(uname -s 2>/dev/null || true)"
    case "${os}" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac
    return 1
}

docker_host_path() {
    local path="$1" os
    os="$(uname -s 2>/dev/null || true)"
    case "${os}" in
        MINGW*|MSYS*|CYGWIN*)
            (cd "${path}" && pwd -W) | sed 's#\\#/#g'
            ;;
        *)
            (cd "${path}" && pwd -P)
            ;;
    esac
}

emit_failure_annotation() {
    # Direct callers can publish sanitized notices. CI wrappers capture these
    # privately and publish their fixed reports instead.
    local slug="$1" source="$2" reason="$3"
    local title message
    title="External ${ZMK_EXTERNAL_MODE} failed: ${slug}"
    message="source=${source}; ${reason}"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::error title=External source execution failed::%s\n' "$(public_failure_reason "${reason}")"
    else
        echo "ERROR: ${title} (${message})" >&2
    fi
}

public_failure_reason() {
    case "$1" in
        'clone failed'|'build failed'|'validate failed'|'clone cleanup failed'|\
        'clone failed; clone cleanup failed'|'build failed; clone cleanup failed'|'validate failed; clone cleanup failed') printf '%s' "$1" ;;
        'path not found:'*) printf '%s' 'path not found' ;;
        *) printf '%s' 'source execution failed' ;;
    esac
}

write_github_step_summary() {
    local result="$1" reason="${2:-}" summary_file="${GITHUB_STEP_SUMMARY:-}"
    local public_mode=unknown
    [ -n "${summary_file}" ] || return 0
    case "${result}" in success|failure) ;; *) result=failure ;; esac
    case "${ZMK_EXTERNAL_MODE}" in build|validate) public_mode="${ZMK_EXTERNAL_MODE}" ;; esac
    {
        echo "## External ZMK source build"
        echo
        echo "| result | mode |"
        echo "| --- | --- |"
        printf '| %s | %s |\n' \
            "${result}" "${public_mode}"
        if [ -n "${reason}" ]; then
            echo
            printf 'Reason: `%s`\n' "$(public_failure_reason "${reason}")"
        fi
        echo
    } >> "${summary_file}"
}

cleanup_clone_container() {
    [ "${clone_container_created:-0}" = 1 ] || return 0
    if ! docker_no_pathconv rm -f "${clone_container_id}" >/dev/null; then
        echo "ERROR: failed to remove clone container: ${clone_container_id}" >&2
        return 1
    fi
    clone_container_created=0
    clone_container_id=""
}

clear_clone_directory() {
    local clone_dir="$1" root parent
    root="$(cd "${WORK_DIR}" && pwd -P)" || return 1
    parent="$(cd "$(dirname "${clone_dir}")" && pwd -P)" || return 1
    if [ "${parent}" != "${root}" ] || [ -z "${clone_dir##*/}" ] ||
        [ "${clone_dir##*/}" = . ] || [ "${clone_dir##*/}" = .. ]; then
        echo "ERROR: refusing to clear path outside clone root: ${clone_dir}" >&2
        return 1
    fi
    clone_dir="${parent}/${clone_dir##*/}"
    if ! rm -rf -- "${clone_dir}"; then
        echo "ERROR: failed to clear clone destination: ${clone_dir}" >&2
        return 1
    fi
}

clone_repo_with_docker() {
    local source="$1" slug="$2" clone_dir="$3"
    local clone_parent clone_dir_for_docker clone_container_name attempt prune_clone_paths=0

    clone_parent="$(dirname "${clone_dir}")"
    mkdir -p "${clone_parent}" || return 1
    clone_container_name="zmk-source-clone-${slug:0:80}-pid-$$"
    clone_container_created=0
    clone_container_id=""
    trap cleanup_clone_container EXIT
    host_is_windows && prune_clone_paths=1

    echo "[source:${slug}] Clone image: ${ZMK_EXTERNAL_CLONE_IMAGE}"
    echo "[source:${slug}] Cloning: ${source}"
    attempt=1
    while [ "${attempt}" -le "${ZMK_EXTERNAL_CLONE_ATTEMPTS}" ]; do
        if ! clear_clone_directory "${clone_dir}"; then
            trap - EXIT
            return 1
        fi
        if clone_container_id="$(docker_no_pathconv create --name "${clone_container_name}" \
            "${ZMK_EXTERNAL_CLONE_IMAGE}" \
            /bin/bash -lc "$(declare -f prune_windows_clone_paths)"'
                git clone --depth=1 "$1" /tmp/source || exit "$?"
                [ "$2" != 1 ] || prune_windows_clone_paths /tmp/source "$3"
            ' \
            _ "${source}" "${prune_clone_paths}" "${slug}" | tr -d '\r')"; then
            if [ "${#clone_container_id}" -ne 64 ] || [[ "${clone_container_id}" == *[!0-9a-f]* ]]; then
                echo "ERROR: Docker create did not return a clone container ID" >&2
                clone_container_id=""
                trap - EXIT
                return 1
            fi
            clone_container_created=1
            if docker_no_pathconv start -a "${clone_container_id}"; then
                break
            fi
        fi
        cleanup_clone_container || return 1
        if ! clear_clone_directory "${clone_dir}"; then
            trap - EXIT
            return 1
        fi
        if [ "${attempt}" -ge "${ZMK_EXTERNAL_CLONE_ATTEMPTS}" ]; then
            trap - EXIT
            return 1
        fi
        echo "[source:${slug}] Clone failed; retrying (${attempt}/${ZMK_EXTERNAL_CLONE_ATTEMPTS})" >&2
        attempt="$((attempt + 1))"
    done
    mkdir -p "${clone_dir}"
    clone_dir_for_docker="$(docker_host_path "${clone_dir}")"
    if ! docker_no_pathconv cp "${clone_container_id}:/tmp/source/." "${clone_dir_for_docker}"; then
        cleanup_clone_container || return 1
        trap - EXIT
        clear_clone_directory "${clone_dir}" || return 1
        return 1
    fi

    cleanup_clone_container || return 1
    trap - EXIT
}

build_single_source() {
    local target_dir clone_dir cache_volume container_slug reason failure_phase
    local build_status=0 cleanup_failed=0
    local build_command=()
    local build_env=()

    validate_positive_int "build jobs" "${BUILD_JOBS}"
    validate_positive_int "clone attempts" "${ZMK_EXTERNAL_CLONE_ATTEMPTS}"
    case "${ZMK_EXTERNAL_MODE}" in
        build|validate) ;;
        *)
            echo "ERROR: --mode must be build or validate: ${ZMK_EXTERNAL_MODE}" >&2
            exit 1
            ;;
    esac

    cache_volume="${ZMK_EXTERNAL_CACHE_PREFIX}-${SOURCE_SLUG}"
    echo "=== Source: ${SOURCE_SLUG} ==="
    echo "[source:${SOURCE_SLUG}] Type: ${SOURCE_TYPE}"
    echo "[source:${SOURCE_SLUG}] Source: ${SOURCE_VALUE}"
    echo "[source:${SOURCE_SLUG}] Docker cache volume: ${cache_volume}"
    if [ "${SOURCE_TYPE}" = "repo" ] || [ "${ZMK_EXTERNAL_PRISTINE}" = "1" ]; then
        require_docker
    fi
    if [ "${SOURCE_TYPE}" = "repo" ]; then
        clone_dir="${WORK_DIR}/${SOURCE_SLUG}"
        if ! clone_repo_with_docker "${SOURCE_VALUE}" "${SOURCE_SLUG}" "${clone_dir}"; then
            reason="clone failed"
            clear_clone_directory "${clone_dir}" || reason="clone failed; clone cleanup failed"
            echo "=== FAILED: clone ${SOURCE_SLUG} ===" >&2
            emit_failure_annotation "${SOURCE_SLUG}" "${SOURCE_VALUE}" "${reason}"
            write_github_step_summary "failure" "${reason}"
            return 1
        fi
        target_dir="${clone_dir}"
    else
        target_dir="$(resolve_path_source "${SOURCE_VALUE}")"
        if [ ! -d "${target_dir}" ]; then
            echo "=== FAILED: path not found ${SOURCE_SLUG}: ${target_dir} ===" >&2
            emit_failure_annotation "${SOURCE_SLUG}" "${SOURCE_VALUE}" "path not found: ${target_dir}"
            write_github_step_summary "failure" "path not found: ${target_dir}"
            return 1
        fi
        target_dir="$(cd "${target_dir}" && pwd -P)"
        echo "[source:${SOURCE_SLUG}] Using local path: ${target_dir}"
    fi

    build_command=("${BUILD_SCRIPT}")
    if [ "${ZMK_EXTERNAL_MODE}" = "validate" ]; then
        build_command+=(validate "${target_dir}")
    else
        build_command+=("${target_dir}")
    fi
    [ "${ZMK_EXTERNAL_PRISTINE}" != "1" ] || build_command+=(--pristine)
    build_command+=(--jobs "${BUILD_JOBS}")
    [ "${ZMK_EXTERNAL_SETTINGS_RESET}" != "1" ] || build_command+=(--settings-reset)
    if [ ${#build_snippets[@]} -gt 0 ]; then
        for snippet in "${build_snippets[@]}"; do
            build_command+=(-S "${snippet}")
        done
    fi
    if [ ${#build_modules[@]} -gt 0 ]; then
        for module in "${build_modules[@]}"; do
            build_command+=(-m "${module}")
        done
    fi

    container_slug="$(sanitize_slug "${SOURCE_SLUG}")"
    build_env=(ZMK_DOCKER_CACHE_VOLUME="${cache_volume}")
    if [ -z "${ZMK_CONTAINER_NAME:-}" ]; then
        build_env+=(ZMK_CONTAINER_NAME="zmk-build-${container_slug:0:80}-pid-$$")
    fi

    if env "${build_env[@]}" "${build_command[@]}"; then
        build_status=0
    else
        build_status=$?
    fi
    if [ "${SOURCE_TYPE}" = repo ]; then
        clear_clone_directory "${clone_dir}" || cleanup_failed=1
    fi
    if [ "${build_status}" = 0 ] && [ "${cleanup_failed}" = 0 ]; then
        echo "=== SUCCESS: ${SOURCE_SLUG} ==="
        write_github_step_summary "success"
        return 0
    fi

    reason="${ZMK_EXTERNAL_MODE} failed"
    failure_phase="${ZMK_EXTERNAL_MODE}"
    if [ "${build_status}" = 0 ]; then
        reason="clone cleanup failed"
        failure_phase=cleanup
    elif [ "${cleanup_failed}" != 0 ]; then
        reason="${reason}; clone cleanup failed"
    fi
    echo "=== FAILED: ${failure_phase} ${SOURCE_SLUG} ===" >&2
    emit_failure_annotation "${SOURCE_SLUG}" "${SOURCE_VALUE}" "${reason}"
    write_github_step_summary "failure" "${reason}"
    return 1
}

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --repo)
                [ "$#" -ge 2 ] || { echo "ERROR: --repo requires a value" >&2; exit 1; }
                SOURCE_TYPE="repo"
                SOURCE_VALUE="$2"
                shift
                ;;
            --path)
                [ "$#" -ge 2 ] || { echo "ERROR: --path requires a value" >&2; exit 1; }
                SOURCE_TYPE="path"
                SOURCE_VALUE="$2"
                shift
                ;;
            --repo-slug|--source-slug)
                [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
                SOURCE_SLUG="$(sanitize_slug "$2")"
                shift
                ;;
            --mode)
                [ "$#" -ge 2 ] || { echo "ERROR: --mode requires a value" >&2; exit 1; }
                ZMK_EXTERNAL_MODE="$2"
                shift
                ;;
            -j|--jobs)
                [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
                BUILD_JOBS="$2"
                shift
                ;;
            --pristine)
                ZMK_EXTERNAL_PRISTINE=1
                ;;
            --settings-reset)
                ZMK_EXTERNAL_SETTINGS_RESET=1
                ;;
            -S|--snippet)
                [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
                build_snippets+=("$2")
                shift
                ;;
            -m|--module)
                [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
                build_modules+=("$2")
                shift
                ;;
            --help|-h|help)
                usage
                exit 0
                ;;
            -*)
                echo "ERROR: unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
            *)
                positionals+=("$1")
                ;;
        esac
        shift
    done

    if [ -z "${SOURCE_VALUE}" ]; then
        if [ ${#positionals[@]} -ne 1 ]; then
            echo "ERROR: exactly one source is required" >&2
            usage >&2
            exit 1
        fi
        classify_source "${positionals[0]}"
    elif [ ${#positionals[@]} -gt 0 ]; then
        echo "ERROR: source was specified more than once" >&2
        usage >&2
        exit 1
    fi

    if [ -z "${SOURCE_SLUG}" ]; then
        if [ "${SOURCE_TYPE}" = "repo" ]; then
            SOURCE_SLUG="$(repo_slug_base "${SOURCE_VALUE}")"
        else
            SOURCE_SLUG="$(path_slug_base "${SOURCE_VALUE}")"
        fi
    fi

    case "${SOURCE_TYPE}" in
        repo|path) ;;
        *)
            echo "ERROR: source type must be repo or path" >&2
            exit 1
            ;;
    esac

    build_single_source
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
