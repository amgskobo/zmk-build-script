#!/usr/bin/env bash
set -euo pipefail

# build-external-source.sh - URL または local path 1 件を単体 build.sh process へ渡す。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

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
  ./scripts/build-external-source.sh --repo <git-url> [--source-slug <slug>] [--jobs N]
  ./scripts/build-external-source.sh --path <zmk-config-root> [--source-slug <slug>] [--jobs N]
  ./scripts/build-external-source.sh <git-url-or-path> [--jobs N]

Runs exactly one source build. Use auto-build-external.sh or GitHub Actions
matrix to start multiple copies in parallel.
EOF
}

trim_line() {
    printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

validate_positive_int() {
    local label="$1" value="$2"
    case "${value}" in
        ""|*[!0-9]*|0)
            echo "ERROR: ${label} must be a positive integer: ${value}" >&2
            exit 1
            ;;
    esac
}

is_repo_url() {
    case "$1" in
        http://*|https://*|ssh://*|git@*:*)
            return 0
            ;;
    esac
    return 1
}

is_absolute_path() {
    case "$1" in
        /*|[A-Za-z]:*)
            return 0
            ;;
    esac
    return 1
}

sanitize_slug() {
    local value="$1" slug
    slug="$(
        printf '%s' "${value}" |
            tr '\\' '/' |
            tr '[:upper:]' '[:lower:]' |
            sed -e 's#/#-#g' \
                -e 's/[^a-z0-9_.-]/-/g' \
                -e 's/--*/-/g' \
                -e 's/^[.-]*//' \
                -e 's/[.-]*$//'
    )"
    [ -n "${slug}" ] || slug="source"
    printf '%s\n' "${slug}"
}

repo_slug_base() {
    local url="$1" clean path
    clean="$(trim_line "${url}")"
    clean="${clean%/}"
    clean="${clean%.git}"
    case "${clean}" in
        git@*:*)
            path="${clean#*:}"
            ;;
        *://*)
            path="${clean#*://}"
            path="${path#*/}"
            ;;
        *)
            path="${clean}"
            ;;
    esac
    path="${path%.git}"
    sanitize_slug "${path}"
}

path_slug_base() {
    local path="$1" normalized base
    normalized="$(trim_line "${path}")"
    normalized="${normalized%/}"
    normalized="$(printf '%s' "${normalized}" | tr '\\' '/')"
    base="${normalized##*/}"
    [ -n "${base}" ] || base="path"
    sanitize_slug "${base}"
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

gha_escape() {
    local value="$1"
    value="${value//%/%25}"
    value="${value//$'\r'/%0D}"
    value="${value//$'\n'/%0A}"
    printf '%s' "${value}"
}

markdown_cell() {
    local value="$1"
    value="${value//|/\\|}"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    printf '%s' "${value}"
}

docker_no_pathconv() {
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker "$@"
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
    local slug="$1" source="$2" reason="$3"
    local title message
    title="External ${ZMK_EXTERNAL_MODE} failed: ${slug}"
    message="source=${source}; ${reason}"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::error title=%s::%s\n' "$(gha_escape "${title}")" "$(gha_escape "${message}")"
    else
        echo "ERROR: ${title} (${message})" >&2
    fi
}

write_github_step_summary() {
    local result="$1" reason="${2:-}" summary_file="${GITHUB_STEP_SUMMARY:-}"
    local cache_volume
    [ -n "${summary_file}" ] || return 0
    cache_volume="${ZMK_EXTERNAL_CACHE_PREFIX}-${SOURCE_SLUG}"
    {
        echo "## External ZMK source build"
        echo
        echo "| result | slug | type | source | cache volume |"
        echo "| --- | --- | --- | --- | --- |"
        printf '| %s | `%s` | %s | `%s` | `%s` |\n' \
            "$(markdown_cell "${result}")" \
            "$(markdown_cell "${SOURCE_SLUG}")" \
            "$(markdown_cell "${SOURCE_TYPE}")" \
            "$(markdown_cell "${SOURCE_VALUE}")" \
            "$(markdown_cell "${cache_volume}")"
        if [ -n "${reason}" ]; then
            echo
            printf 'Reason: `%s`\n' "$(markdown_cell "${reason}")"
        fi
        echo
    } >> "${summary_file}"
}

cleanup_clone_container() {
    [ -n "${clone_container_name:-}" ] || return 0
    docker_no_pathconv rm -f "${clone_container_name}" >/dev/null 2>&1 || true
}

clone_repo_with_docker() {
    local source="$1" slug="$2" clone_dir="$3"
    local clone_parent clone_dir_for_docker attempt prune_clone_paths=0

    clone_parent="$(dirname "${clone_dir}")"
    mkdir -p "${clone_parent}"
    clone_container_name="zmk-source-clone-${slug:0:80}-pid-$$"
    trap cleanup_clone_container EXIT
    host_is_windows && prune_clone_paths=1

    echo "[source:${slug}] Clone image: ${ZMK_EXTERNAL_CLONE_IMAGE}"
    echo "[source:${slug}] Cloning: ${source}"
    attempt=1
    while [ "${attempt}" -le "${ZMK_EXTERNAL_CLONE_ATTEMPTS}" ]; do
        rm -rf "${clone_dir}"
        docker_no_pathconv rm -f "${clone_container_name}" >/dev/null 2>&1 || true
        if docker_no_pathconv create --name "${clone_container_name}" \
            "${ZMK_EXTERNAL_CLONE_IMAGE}" \
            /bin/sh -lc '
                git clone --depth=1 "$1" /tmp/source || exit "$?"
                [ "$2" = "1" ] || exit 0
                pruned_file="$(mktemp)"
                find /tmp/source -depth \( -name "*[[:space:]]" -o -name "*." \) -print > "${pruned_file}"
                if [ -s "${pruned_file}" ]; then
                    echo "[source:$3] Removed Windows-incompatible clone path(s) before docker cp:" >&2
                    while IFS= read -r path; do
                        display="${path#/tmp/source/}"
                        rm -rf -- "${path}"
                        echo "[source:$3]   - ${display}" >&2
                    done < "${pruned_file}"
                fi
                rm -f "${pruned_file}"
            ' \
            _ "${source}" "${prune_clone_paths}" "${slug}" >/dev/null &&
            docker_no_pathconv start -a "${clone_container_name}"; then
            break
        fi
        cleanup_clone_container
        rm -rf "${clone_dir}"
        if [ "${attempt}" -ge "${ZMK_EXTERNAL_CLONE_ATTEMPTS}" ]; then
            clone_container_name=""
            trap - EXIT
            return 1
        fi
        echo "[source:${slug}] Clone failed; retrying (${attempt}/${ZMK_EXTERNAL_CLONE_ATTEMPTS})" >&2
        attempt="$((attempt + 1))"
    done
    mkdir -p "${clone_dir}"
    clone_dir_for_docker="$(docker_host_path "${clone_dir}")"
    if ! docker_no_pathconv cp "${clone_container_name}:/tmp/source/." "${clone_dir_for_docker}"; then
        cleanup_clone_container
        clone_container_name=""
        trap - EXIT
        rm -rf "${clone_dir}"
        return 1
    fi

    cleanup_clone_container
    clone_container_name=""
    trap - EXIT
}

build_single_source() {
    local target_dir clone_dir cache_volume container_slug
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
    [ "${ZMK_EXTERNAL_PRISTINE}" != "1" ] || docker volume rm "${cache_volume}" 2>/dev/null || true

    if [ "${SOURCE_TYPE}" = "repo" ]; then
        clone_dir="${WORK_DIR}/${SOURCE_SLUG}"
        if ! clone_repo_with_docker "${SOURCE_VALUE}" "${SOURCE_SLUG}" "${clone_dir}"; then
            echo "=== FAILED: clone ${SOURCE_SLUG} ===" >&2
            emit_failure_annotation "${SOURCE_SLUG}" "${SOURCE_VALUE}" "clone failed"
            write_github_step_summary "failure" "clone failed"
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
        [ "${ZMK_EXTERNAL_PRISTINE}" != "1" ] || build_command+=(--pristine)
    fi
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
        echo "=== SUCCESS: ${SOURCE_SLUG} ==="
        [ "${SOURCE_TYPE}" != "repo" ] || rm -rf "${clone_dir}"
        write_github_step_summary "success"
        return 0
    fi

    echo "=== FAILED: ${ZMK_EXTERNAL_MODE} ${SOURCE_SLUG} ===" >&2
    emit_failure_annotation "${SOURCE_SLUG}" "${SOURCE_VALUE}" "${ZMK_EXTERNAL_MODE} failed"
    [ "${SOURCE_TYPE}" != "repo" ] || rm -rf "${clone_dir}"
    write_github_step_summary "failure" "${ZMK_EXTERNAL_MODE} failed"
    return 1
}

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
