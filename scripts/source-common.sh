#!/usr/bin/env bash
# Shared source classification and naming; sourced by the two external entry points.

trim_line() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

validate_positive_int() {
    local label="$1" value="$2"
    case "${value}" in
        ""|*[!0-9]*) ;;
        *[1-9]*) return 0 ;;
    esac
    echo "ERROR: ${label} must be a positive integer: ${value}" >&2
    exit 1
}

is_repo_url() {
    case "$1" in
        http://*|https://*|ssh://*|git://*|file://*|git@*:*)
            return 0
            ;;
    esac
    return 1
}

is_absolute_path() {
    case "$1" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*|\\\\*)
            return 0
            ;;
    esac
    return 1
}

sanitize_slug() {
    local value="$1" slug
    slug="$(
        printf '%s' "${value}" |
            tr '[:upper:]' '[:lower:]' |
            sed -e 's/[^a-z0-9_.-]/-/g' \
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

# Runs in the clone container before Windows docker cp. NUL traversal preserves every filename.
prune_windows_clone_paths() {
    local root="$1" slug="$2" path base stem upper bad LC_ALL=C
    while IFS= read -r -d '' path; do
        [ "${path}" != "${root}" ] || continue
        base="${path##*/}"
        bad=0
        case "${base}" in
            *' '|*.|*[$'\001'-$'\037']*|*'<'*|*'>'*|*':'*|*'"'*|*'\'*|*'|'*|*'?'*|*'*'*) bad=1 ;;
        esac
        stem="${base%%.*}"
        upper="$(printf '%s' "${stem}" | tr '[:lower:]' '[:upper:]')"
        case "${upper}" in CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]|COM¹|COM²|COM³|LPT¹|LPT²|LPT³) bad=1 ;; esac
        [ "${bad}" = 1 ] || continue
        printf '[source:%s] Removed Windows-incompatible clone path: %q\n' "${slug}" "${path#"${root}/"}" >&2
        rm -rf -- "${path}" || return
    done < <(find "${root}" -depth -print0)
}
