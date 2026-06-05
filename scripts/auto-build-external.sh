#!/usr/bin/env bash
set -euo pipefail

# auto-build-external.sh - source list を解決し、source ごとに build script を別 process で起動する。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CALLER_DIR="$(pwd -P)"

SOURCES_FILE="$REPO_ROOT/repos.txt"
SOURCE_BUILDER="${ZMK_EXTERNAL_SOURCE_BUILDER:-$SCRIPT_DIR/build-external-source.sh}"
ZMK_EXTERNAL_CACHE_PREFIX="${ZMK_EXTERNAL_CACHE_PREFIX:-zmk-cache-external}"
ZMK_EXTERNAL_MODE="${ZMK_EXTERNAL_MODE:-build}"
BUILD_JOBS="${ZMK_BUILD_JOBS:-1}"
SOURCE_JOBS="${ZMK_EXTERNAL_SOURCE_JOBS:-1}"
ZMK_EXTERNAL_PRISTINE="${ZMK_EXTERNAL_PRISTINE:-0}"
ZMK_EXTERNAL_SETTINGS_RESET="${ZMK_EXTERNAL_SETTINGS_RESET:-0}"

source_types=()
source_values=()
slugs=()
used_slugs=()
build_snippets=()
build_modules=()
positionals=()
loaded_default_sources=0
UNIQUE_SLUG=""
CLASSIFIED_TYPE=""
CLASSIFIED_VALUE=""

usage() {
    cat <<'EOF'
Usage:
  ./scripts/auto-build-external.sh [sources.txt | source ...] [--jobs N] [--source-jobs N]
  ./scripts/auto-build-external.sh --repo <git-url> [--source-slug <slug>] [--jobs N] [--source-jobs N]
  ./scripts/auto-build-external.sh --path <zmk-config-root> [--source-slug <slug>] [--jobs N] [--source-jobs N]
  ./scripts/auto-build-external.sh --list [sources.txt | source ...]
  ./scripts/auto-build-external.sh --list-json [sources.txt | source ...]

sources.txt accepts one source per line. Each source may be a Git URL or a
local zmk-config path. Optional prefixes are supported: repo:<url>, path:<dir>.
Actual builds are one build-external-source.sh process per source.
--jobs controls target-level parallelism inside each source.
--source-jobs controls how many sources the local wrapper starts at once.
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

path_under_repo() {
    local path="$1"
    case "${path}" in
        "${REPO_ROOT}"|"${REPO_ROOT}"/*)
            return 0
            ;;
    esac
    return 1
}

repo_relative_path() {
    local path="$1"
    case "${path}" in
        "${REPO_ROOT}")
            printf '.\n'
            ;;
        "${REPO_ROOT}"/*)
            printf '%s\n' "${path#"${REPO_ROOT}/"}"
            ;;
        *)
            printf '%s\n' "${path}"
            ;;
    esac
}

resolve_cli_path() {
    local path="$1"
    if is_absolute_path "${path}"; then
        printf '%s\n' "${path}"
    else
        printf '%s\n' "${CALLER_DIR}/${path}"
    fi
}

resolve_list_path() {
    local file_dir="$1" path="$2" resolved
    if is_absolute_path "${path}"; then
        printf '%s\n' "${path}"
        return 0
    fi
    resolved="${file_dir}/${path}"
    if path_under_repo "${file_dir}"; then
        repo_relative_path "${resolved}"
    else
        printf '%s\n' "${resolved}"
    fi
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

make_unique_slug() {
    local base="$1" slug suffix existing found
    slug="${base}"
    suffix=2
    while :; do
        found=0
        if [ ${#used_slugs[@]} -gt 0 ]; then
            for existing in "${used_slugs[@]}"; do
                if [ "${existing}" = "${slug}" ]; then
                    found=1
                    break
                fi
            done
        fi
        [ "${found}" = "0" ] && break
        slug="${base}-${suffix}"
        suffix=$((suffix + 1))
    done
    used_slugs+=("${slug}")
    UNIQUE_SLUG="${slug}"
}

classify_source() {
    local raw trimmed
    raw="$1"
    trimmed="$(trim_line "${raw}")"
    case "${trimmed}" in
        repo:*)
            CLASSIFIED_TYPE="repo"
            CLASSIFIED_VALUE="${trimmed#repo:}"
            ;;
        url:*)
            CLASSIFIED_TYPE="repo"
            CLASSIFIED_VALUE="${trimmed#url:}"
            ;;
        path:*)
            CLASSIFIED_TYPE="path"
            CLASSIFIED_VALUE="${trimmed#path:}"
            ;;
        *)
            if is_repo_url "${trimmed}"; then
                CLASSIFIED_TYPE="repo"
            else
                CLASSIFIED_TYPE="path"
            fi
            CLASSIFIED_VALUE="${trimmed}"
            ;;
    esac
    CLASSIFIED_VALUE="$(trim_line "${CLASSIFIED_VALUE}")"
}

add_source() {
    local type="$1" value="$2" slug_override="${3:-}" base slug
    [ -n "${value}" ] || return 0
    case "${type}" in
        repo|path) ;;
        *) echo "ERROR: source type must be repo or path: ${type}" >&2; exit 1 ;;
    esac
    if [ -n "${slug_override}" ]; then
        base="$(sanitize_slug "${slug_override}")"
    elif [ "${type}" = "repo" ]; then
        base="$(repo_slug_base "${value}")"
    else
        base="$(path_slug_base "${value}")"
    fi
    make_unique_slug "${base}"
    slug="${UNIQUE_SLUG}"
    source_types+=("${type}")
    source_values+=("${value}")
    slugs+=("${slug}")
}

add_auto_source() {
    local raw="$1" slug_override="${2:-}"
    classify_source "${raw}"
    if [ "${CLASSIFIED_TYPE}" = "path" ]; then
        CLASSIFIED_VALUE="$(resolve_cli_path "${CLASSIFIED_VALUE}")"
    fi
    add_source "${CLASSIFIED_TYPE}" "${CLASSIFIED_VALUE}" "${slug_override}"
}

load_sources_file() {
    local file="$1" line trimmed file_dir type value
    if [ ! -f "${file}" ]; then
        echo "ERROR: source list not found: ${file}" >&2
        echo "Create a file with one Git URL or local path per line." >&2
        exit 1
    fi
    file_dir="$(cd "$(dirname "${file}")" && pwd -P)"
    while IFS= read -r line || [ -n "${line}" ]; do
        trimmed="$(trim_line "${line}")"
        case "${trimmed}" in
            ""|\#*) continue ;;
        esac
        classify_source "${trimmed}"
        type="${CLASSIFIED_TYPE}"
        value="${CLASSIFIED_VALUE}"
        if [ "${type}" = "path" ]; then
            value="$(resolve_list_path "${file_dir}" "${value}")"
        fi
        add_source "${type}" "${value}"
    done < "${file}"
}

load_default_sources() {
    [ "${loaded_default_sources}" = "0" ] || return 0
    loaded_default_sources=1
    load_sources_file "${SOURCES_FILE}"
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\t'/\\t}"
    printf '%s' "${value}"
}

print_list() {
    local i cache_volume
    [ ${#source_values[@]} -gt 0 ] || return 0
    for i in "${!source_values[@]}"; do
        cache_volume="${ZMK_EXTERNAL_CACHE_PREFIX}-${slugs[$i]}"
        printf '%s\t%s\t%s\t%s\n' "${slugs[$i]}" "${cache_volume}" "${source_types[$i]}" "${source_values[$i]}"
    done
}

print_list_json() {
    local i cache_volume comma=""
    if [ ${#source_values[@]} -eq 0 ]; then
        printf '{"include":[]}'
        return 0
    fi

    printf '{"include":['
    for i in "${!source_values[@]}"; do
        cache_volume="${ZMK_EXTERNAL_CACHE_PREFIX}-${slugs[$i]}"
        printf '%s{"slug":"%s","cache_volume":"%s","type":"%s","source":"%s"}' \
            "${comma}" \
            "$(json_escape "${slugs[$i]}")" \
            "$(json_escape "${cache_volume}")" \
            "$(json_escape "${source_types[$i]}")" \
            "$(json_escape "${source_values[$i]}")"
        comma=","
    done
    printf ']}\n'
}

validate_settings() {
    case "${ZMK_EXTERNAL_MODE}" in
        build|validate) ;;
        *)
            echo "ERROR: ZMK_EXTERNAL_MODE must be build or validate: ${ZMK_EXTERNAL_MODE}" >&2
            exit 1
            ;;
    esac
    validate_positive_int "build jobs" "${BUILD_JOBS}"
    validate_positive_int "source jobs" "${SOURCE_JOBS}"
}

builder_args_for_source() {
    local i="$1" snippet module
    if [ "${source_types[$i]}" = "repo" ]; then
        printf '%s\0%s\0' --repo "${source_values[$i]}"
    else
        printf '%s\0%s\0' --path "${source_values[$i]}"
    fi
    printf '%s\0%s\0' --source-slug "${slugs[$i]}"
    printf '%s\0%s\0' --mode "${ZMK_EXTERNAL_MODE}"
    printf '%s\0%s\0' --jobs "${BUILD_JOBS}"
    [ "${ZMK_EXTERNAL_PRISTINE}" != "1" ] || printf '%s\0' --pristine
    [ "${ZMK_EXTERNAL_SETTINGS_RESET}" != "1" ] || printf '%s\0' --settings-reset
    if [ ${#build_snippets[@]} -gt 0 ]; then
        for snippet in "${build_snippets[@]}"; do
            printf '%s\0%s\0' -S "${snippet}"
        done
    fi
    if [ ${#build_modules[@]} -gt 0 ]; then
        for module in "${build_modules[@]}"; do
            printf '%s\0%s\0' -m "${module}"
        done
    fi
}

run_source_processes() {
    local failed=0 completed=0 active=0 next_index=0 i status_dir
    local pids=()
    local pid_indexes=()
    local statuses=()
    local status_files=()
    local args=()

    if [ ${#source_values[@]} -eq 0 ]; then
        echo "No sources to build." >&2
        return 0
    fi

    status_dir="$(mktemp -d)"

    for i in "${!source_values[@]}"; do
        statuses[$i]="pending"
    done

    start_source_process() {
        local source_index="$1" status_file
        args=()
        while IFS= read -r -d '' arg; do
            args+=("${arg}")
        done < <(builder_args_for_source "${source_index}")

        status_file="${status_dir}/${source_index}.status"
        rm -f "${status_file}"
        echo "Started ${slugs[$source_index]} (${source_types[$source_index]}): ${source_values[$source_index]}"
        (
            set +e
            bash "${SOURCE_BUILDER}" "${args[@]}"
            status="$?"
            printf '%s\n' "${status}" > "${status_file}"
            exit "${status}"
        ) &
        pids+=("$!")
        pid_indexes+=("${source_index}")
        status_files+=("${status_file}")
        statuses[$source_index]="running"
        active=$((active + 1))
    }

    collect_finished_sources() {
        local wait_for_one="$1" found j pid source_index status_file status wait_status
        while :; do
            found=0
            if [ ${#pids[@]} -gt 0 ]; then
                for j in "${!pids[@]}"; do
                    status_file="${status_files[$j]}"
                    [ -f "${status_file}" ] || continue
                    pid="${pids[$j]}"
                    source_index="${pid_indexes[$j]}"
                    if wait "${pid}"; then
                        wait_status=0
                    else
                        wait_status=$?
                    fi
                    status="$(cat "${status_file}" 2>/dev/null || printf '%s' "${wait_status}")"
                    if [ "${status}" = "0" ]; then
                        statuses[$source_index]="success"
                    else
                        statuses[$source_index]="failure"
                        failed=$((failed + 1))
                    fi
                    echo "Finished ${slugs[$source_index]}: ${statuses[$source_index]}"
                    unset "pids[$j]"
                    unset "pid_indexes[$j]"
                    unset "status_files[$j]"
                    completed=$((completed + 1))
                    active=$((active - 1))
                    found=1
                done
            fi
            [ "${found}" = "1" ] && return 0
            [ "${wait_for_one}" != "1" ] && return 0
            sleep 1
        done
    }

    echo "Starting ${#source_values[@]} source build process(es) (source jobs=${SOURCE_JOBS})"
    while [ "${completed}" -lt "${#source_values[@]}" ]; do
        while [ "${active}" -lt "${SOURCE_JOBS}" ] && [ "${next_index}" -lt "${#source_values[@]}" ]; do
            start_source_process "${next_index}"
            next_index=$((next_index + 1))
        done
        collect_finished_sources 1
        collect_finished_sources 0
    done

    rm -rf "${status_dir}"

    echo ""
    echo "External build summary:"
    for i in "${!source_values[@]}"; do
        printf '  - %s: %s (%s)\n' "${slugs[$i]}" "${statuses[$i]}" "${source_values[$i]}"
    done
    echo "=== Done: ${failed} failure(s) ==="
    [ "${failed}" = "0" ]
}

mode="run"
last_source_index=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --list)
            mode="list"
            ;;
        --list-json|--matrix-json)
            mode="list-json"
            ;;
        --repo)
            [ "$#" -ge 2 ] || { echo "ERROR: --repo requires a value" >&2; exit 1; }
            add_source "repo" "$2"
            last_source_index="$((${#source_values[@]} - 1))"
            shift
            ;;
        --path)
            [ "$#" -ge 2 ] || { echo "ERROR: --path requires a value" >&2; exit 1; }
            add_source "path" "$(resolve_cli_path "$2")"
            last_source_index="$((${#source_values[@]} - 1))"
            shift
            ;;
        -j|--jobs)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
            BUILD_JOBS="$2"
            shift
            ;;
        --source-jobs)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
            SOURCE_JOBS="$2"
            shift
            ;;
        --mode)
            [ "$#" -ge 2 ] || { echo "ERROR: --mode requires a value" >&2; exit 1; }
            ZMK_EXTERNAL_MODE="$2"
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
        --repos-file|--sources-file)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
            SOURCES_FILE="$2"
            load_sources_file "${SOURCES_FILE}"
            loaded_default_sources=1
            shift
            ;;
        --repo-slug|--source-slug)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
            if [ -z "${last_source_index}" ]; then
                echo "ERROR: $1 must follow --repo or --path" >&2
                exit 1
            fi
            used_slugs=()
            slugs[$last_source_index]="$(sanitize_slug "$2")"
            for i in "${!slugs[@]}"; do
                make_unique_slug "${slugs[$i]}"
                slugs[$i]="${UNIQUE_SLUG}"
            done
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

if [ ${#positionals[@]} -gt 0 ]; then
    if [ ${#positionals[@]} -eq 1 ] &&
        [ -f "${positionals[0]}" ] &&
        ! is_repo_url "${positionals[0]}"; then
        load_sources_file "${positionals[0]}"
        loaded_default_sources=1
    else
        for source in "${positionals[@]}"; do
            add_auto_source "${source}"
        done
    fi
fi

if [ ${#source_values[@]} -eq 0 ]; then
    load_default_sources
fi

case "${mode}" in
    list)
        print_list
        exit 0
        ;;
    list-json)
        print_list_json
        exit 0
        ;;
esac

validate_settings
run_source_processes
