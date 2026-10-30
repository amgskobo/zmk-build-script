#!/usr/bin/env bash
# Docker build helper for ZMK configs and explicit Zephyr applications.
set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: build.sh requires Bash." >&2
    exit 1
fi

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

die() {
    printf "${RED}Error: %s${NC}\n" "$*" >&2
    exit 1
}

msg() {
    printf "${GRAY}%s${NC}\n" "$*"
}

usage() {
    cat <<'EOF'
Usage:
  ./build.sh <zmk-config-root> [--pristine] [--settings-reset] [--jobs N] [-S snippet] [-m module-dir]
  ./build.sh validate <zmk-config-root> [--pristine] [--settings-reset] [--jobs N] [-S snippet] [-m module-dir]
  ./build.sh clean

Supported target layout:
  zmk-config/
    build.yaml
    config/west.yml
    config/<keyboard>.conf
    config/<keyboard>.keymap
    boards/...              # optional user config board/shield definitions
    zephyr/module.yml       # optional module metadata
    snippets/<name>/...     # optional, auto-normalized for target repos

Environment:
  ZMK_BUILD_IMAGE            Full Docker image override.
  ZMK_BUILD_IMAGE_REPOSITORY Docker image repository (default: zmkfirmware/zmk-build-arm).
  ZMK_BUILD_IMAGE_TAG        Docker image tag (default: auto; main -> stable, v0.3 -> 3.5-branch, 4.1 -> 4.1-branch).
  ZMK_DOCKER_PLATFORM        Optional docker --platform value.
  ZMK_DOCKER_CACHE_VOLUME    Docker volume mounted at /workspaces (default: zmk-cache).
  ZMK_CCACHE_DIR             ccache directory inside the container (default: /workspaces/.ccache, on the cache volume).
  ZMK_BUILD_JOBS             Number of build.yaml targets to build in parallel (default: 1).
  ZMK_WEST_UPDATE_ATTEMPTS   Number of west update attempts before failing (default: 3).
  ZMK_FALLBACK_BINARY        Fallback firmware extension after uf2 (default: bin).
  ZMK_COPY_IGNORED           Set to 1 to copy files that Git ignores too (default: skipped in a Git working tree).
EOF
}

validate_positive_int() {
    local label="$1" value="$2"
    case "${value}" in
        ""|*[!0-9]*) ;;
        *[1-9]*) return 0 ;;
    esac
    die "${label} must be a positive integer: ${value}"
}

validate_firmware_extension() {
    case "$1" in
        ""|.*|-*|*[!A-Za-z0-9._-]*) die "invalid firmware extension: $1" ;;
    esac
}

firmware_files() {
    find "$1" -maxdepth 1 -type f \( -name '*.uf2' -o -name '*.hex' -o -name '*.bin' \
        -o -name "*.${ZMK_FALLBACK_BINARY:-bin}" \) ! -iname build.log ! -iname build-summary.txt -print
}

name_in() {
    local wanted="$1" candidate
    shift
    for candidate in "$@"; do
        [ "${candidate}" != "${wanted}" ] || return 0
    done
    return 1
}

if [ "${ZMK_IN_CONTAINER:-0}" = "1" ]; then
    log() { printf "${GRAY}[container] %s${NC}\n" "$*"; }
    fail() { printf "${RED}[container] ERROR: %s${NC}\n" "$*" >&2; exit 1; }

    SOURCE_DIR="${SOURCE_DIR:-/root/zmk-config}"
    WORK_DIR="${WORK_DIR:-/workspaces/zmk-config}"
    BUILD_DIR="${BUILD_DIR:-${WORK_DIR}/.build}"
    OUTPUT_DIR="${OUTPUT_DIR:-${SOURCE_DIR}/.build}"
    CONFIG_DIR="${CONFIG_DIR:-config}"
    BUILD_YAML="${BUILD_YAML:-build.yaml}"
    MANIFEST_STAMP="${WORK_DIR}/.west/manifest.sha256"
    LOCAL_OVERLAY_STAMP="${WORK_DIR}/.west/local-overlays.tsv"
    LOCAL_OVERLAY_BACKUP_DIR="${WORK_DIR}/.west/local-overlay-backups"
    PRISTINE="${PRISTINE:-0}"
    SETTINGS_RESET="${SETTINGS_RESET:-0}"
    BUILD_JOBS="${BUILD_JOBS:-${ZMK_BUILD_JOBS:-1}}"
    WEST_UPDATE_ATTEMPTS="${ZMK_WEST_UPDATE_ATTEMPTS:-3}"
    USER_ZMK_EXTRA_MODULES="${USER_ZMK_EXTRA_MODULES:-}"
    ZMK_FALLBACK_BINARY="${ZMK_FALLBACK_BINARY:-bin}"
    EXTERNAL_MODULES_DIR="${EXTERNAL_MODULES_DIR:-/root/external_modules}"
    FIRMWARE_EXTENSIONS=(uf2 "${ZMK_FALLBACK_BINARY}" hex bin)
    FIELD_SEP=$'\037'
    EXTRA_MODULE_PATHS=()
    WEST_UPDATE_FAILED=0
    WEST_UPDATE_FAILED_PROJECTS=""

    ensure_zmk_layout() {
        [ -f "${SOURCE_DIR}/${CONFIG_DIR}/west.yml" ] ||
            fail "current ZMK layout requires ${CONFIG_DIR}/west.yml"

        # An explicit application is a standalone Zephyr app in the input tree.
        # Resolve it before touching the persistent workspace.
        APPLICATION_SOURCE="$(python3 - "${SOURCE_DIR}" "${BUILD_YAML}" <<'PY'
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1]).resolve()
with (root / sys.argv[2]).open(encoding="utf-8") as source:
    document = yaml.safe_load(source) or {}
value = document.get("application") if isinstance(document, dict) else None
if value is None:
    print("zmk/app")
else:
    if not isinstance(value, str) or not value.strip() or "\\" in value:
        sys.exit("application must be a relative directory in the target repository")
    path = pathlib.PurePosixPath(value)
    resolved = (root / path).resolve()
    if path.is_absolute() or ".." in path.parts or ":" in value or not resolved.is_relative_to(root):
        sys.exit("application must stay inside the target repository")
    if not (resolved / "CMakeLists.txt").is_file():
        sys.exit("application requires CMakeLists.txt: " + value)
    print(resolved)
PY
        )" || fail "invalid application layout"

        normalize_target_module_metadata

        validate_module_roots "${SOURCE_DIR}" "target" "target"
    }

    normalize_target_module_metadata() {
        local module_yml="${SOURCE_DIR}/zephyr/module.yml"
        local cmake_path="" kconfig_path="" need_board_root=0 need_dts_root=0 need_snippet_root=0

        if [ -d "${SOURCE_DIR}/zephyr" ] &&
            find "${SOURCE_DIR}/zephyr" -mindepth 1 ! -name module.yml -print -quit | grep -q .; then
            log "Allowing legacy zephyr/ module content in target repo"
        fi

        # Standalone applications own their CMake/Kconfig entry points. Only infer
        # module build files for ZMK; preserve explicit declarations in either mode.
        if [ "${APPLICATION_SOURCE}" = "zmk/app" ]; then
            if [ -f "${SOURCE_DIR}/CMakeLists.txt" ]; then
                cmake_path="."
            elif [ -f "${SOURCE_DIR}/zephyr/CMakeLists.txt" ]; then
                cmake_path="zephyr"
            fi

            if [ -f "${SOURCE_DIR}/Kconfig" ]; then
                kconfig_path="Kconfig"
            elif [ -f "${SOURCE_DIR}/zephyr/Kconfig" ]; then
                kconfig_path="zephyr/Kconfig"
            fi
        fi

        [ ! -d "${SOURCE_DIR}/boards" ] || need_board_root=1
        [ ! -d "${SOURCE_DIR}/dts" ] || need_dts_root=1
        [ ! -d "${SOURCE_DIR}/snippets" ] || need_snippet_root=1

        if [ ! -f "${module_yml}" ]; then
            if [ -z "${cmake_path}" ] &&
                [ -z "${kconfig_path}" ] &&
                [ "${need_board_root}" = "0" ] &&
                [ "${need_dts_root}" = "0" ] &&
                [ "${need_snippet_root}" = "0" ] &&
                [ ! -f "${SOURCE_DIR}/module.yml" ]; then
                return 0
            fi
            log "Normalizing target module metadata to zephyr/module.yml"
            mkdir -p "${SOURCE_DIR}/zephyr"
        fi

        if ! python3 - "${module_yml}" "${SOURCE_DIR}/module.yml" \
            "${cmake_path}" "${kconfig_path}" \
            "${need_board_root}" "${need_dts_root}" "${need_snippet_root}" <<'PY'
import os
import sys
import yaml

module_yml, legacy_module_yml, cmake_path, kconfig_path, board_root, dts_root, snippet_root = sys.argv[1:]

source_yml = module_yml if os.path.exists(module_yml) else legacy_module_yml
if os.path.exists(source_yml):
    with open(source_yml, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    data = {} if data is None else data
else:
    data = {}

if not isinstance(data, dict):
    print("target: module metadata must be a map.", file=sys.stderr)
    sys.exit(1)

build = data.get("build")
if build is None:
    build = {}
    data["build"] = build
if not isinstance(build, dict):
    print("target: module metadata build must be a map.", file=sys.stderr)
    sys.exit(1)

changed = not os.path.exists(module_yml)

if cmake_path and not build.get("cmake"):
    build["cmake"] = cmake_path
    changed = True
if kconfig_path and not build.get("kconfig"):
    build["kconfig"] = kconfig_path
    changed = True

needed_settings = []
if board_root == "1":
    needed_settings.append("board_root")
if dts_root == "1":
    needed_settings.append("dts_root")
if snippet_root == "1":
    needed_settings.append("snippet_root")

if needed_settings:
    settings = build.get("settings")
    if settings is None:
        settings = {}
        build["settings"] = settings
        changed = True
    if not isinstance(settings, dict):
        print("target: module metadata build.settings must be a map.", file=sys.stderr)
        sys.exit(1)
    for setting in needed_settings:
        if settings.get(setting) not in (".", "./"):
            settings[setting] = "."
            changed = True

if changed:
    os.makedirs(os.path.dirname(module_yml), exist_ok=True)
    with open(module_yml, "w", encoding="utf-8", newline="\n") as f:
        yaml.safe_dump(data, f, sort_keys=False)
PY
        then
            fail "failed to normalize target module metadata"
        fi
    }

    validate_module_roots() {
        local root="$1" label="$2" kind="$3"
        local need_settings=() need_build_keys=()

        if [ "${kind}" = "module" ] && [ -d "${root}/boards" ]; then
            need_settings+=(board_root)
        fi
        if [ -d "${root}/dts" ]; then
            need_settings+=(dts_root)
        fi
        if [ -d "${root}/snippets" ]; then
            need_settings+=(snippet_root)
        fi
        if [ "${kind}" = "module" ] && [ -f "${root}/CMakeLists.txt" ]; then
            need_build_keys+=(cmake)
        fi
        if [ "${kind}" = "module" ] && [ -f "${root}/Kconfig" ]; then
            need_build_keys+=(kconfig)
        fi

        local module_yml="${root}/zephyr/module.yml"
        if [ ! -f "${module_yml}" ] && [ ${#need_settings[@]} -eq 0 ] && [ ${#need_build_keys[@]} -eq 0 ]; then
            return 0
        fi
        [ -f "${module_yml}" ] ||
            fail "${label}: root module content requires zephyr/module.yml"

        python3 - "${module_yml}" "${label}" \
            "${need_settings[*]}" "${need_build_keys[*]}" <<'PY'
import sys
import yaml

module_yml, label, settings_arg, build_keys_arg = sys.argv[1:]
required_settings = [name for name in settings_arg.split() if name]
required_build_keys = [name for name in build_keys_arg.split() if name]

with open(module_yml, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f)
data = {} if data is None else data

if not isinstance(data, dict):
    print(f"{label}: zephyr/module.yml must be a map.", file=sys.stderr)
    sys.exit(1)

build = data.get("build")
build = {} if build is None else build
if not isinstance(build, dict):
    print(f"{label}: zephyr/module.yml build must be a map.", file=sys.stderr)
    sys.exit(1)

settings = build.get("settings")
settings = {} if settings is None else settings
if not isinstance(settings, dict):
    print(f"{label}: zephyr/module.yml build.settings must be a map.", file=sys.stderr)
    sys.exit(1)

missing_settings = [name for name in required_settings if settings.get(name) not in (".", "./")]
missing_build_keys = [name for name in required_build_keys if not build.get(name)]
if missing_settings or missing_build_keys:
    joined = []
    joined.extend(f"build.settings.{name}: ." for name in missing_settings)
    joined.extend(f"build.{name}" for name in missing_build_keys)
    print(f"{label}: root module content requires {', '.join(joined)}", file=sys.stderr)
    sys.exit(1)
PY
    }

    clear_dir() {
        local dir="$1" entry
        shopt -s nullglob dotglob
        for entry in "${dir:?}"/*; do
            if ! rm -rf "${entry}"; then
                shopt -u nullglob dotglob
                return 1
            fi
        done
        shopt -u nullglob dotglob
    }

    copy_tree() {
        local src="$1" dst="$2" exclude
        local excludes=()
        shift 2
        for exclude in "$@"; do excludes+=(--exclude "${exclude}"); done
        mkdir -p "${dst}" || return
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete ${excludes[@]+"${excludes[@]}"} "${src}/" "${dst}/"
        else
            clear_dir "${dst}" || return
            (cd "${src}" && tar cf - ${excludes[@]+"${excludes[@]}"} .) | (cd "${dst}" && tar xf -)
        fi
    }

    sync_config_to_workspace() {
        log "Syncing config into persistent west workspace"
        mkdir -p "${WORK_DIR}"
        copy_tree "${SOURCE_DIR}/${CONFIG_DIR}" "${WORK_DIR}/${CONFIG_DIR}"
    }

    manifest_digest() {
        local resolved
        # Resolve with west so local and project imports share west's own semantics.
        resolved="$(west manifest --resolve)" || return 1
        if command -v sha256sum >/dev/null 2>&1; then
            printf '%s\n' "${resolved}" | sha256sum | awk '{print $1}'
        else
            printf '%s\n' "${resolved}" | cksum | awk '{print $1":"$2}'
        fi
    }

    manifest_stamp_value() {
        local digest
        digest="$(manifest_digest)" || return 1
        printf 'complete-resolved:%s\n' "${digest}"
    }

    manifest_changed() {
        local current
        [ -f "${MANIFEST_STAMP}" ] || return 0
        current="$(manifest_stamp_value)" || return 0
        [ "${current}" != "$(cat "${MANIFEST_STAMP}")" ]
    }

    stamp_manifest() {
        local current
        current="$(manifest_stamp_value)" || fail "failed to resolve west manifest after dependency update"
        mkdir -p "$(dirname "${MANIFEST_STAMP}")"
        printf '%s\n' "${current}" > "${MANIFEST_STAMP}"
    }

    workspace_project_list() {
        local projects
        if ! projects="$(cd "${WORK_DIR}" && west list -f $'{name}\t{path}')"; then
            # Preserve partial diagnostics, but never use partial output as a project set.
            [ -z "${projects}" ] || printf '%s\n' "${projects}" >&2
            return 1
        fi
        printf '%s\n' "${projects}"
    }

    prune_workspace_roots() {
        local keep=(.west .build "${CONFIG_DIR}")
        local projects name path root entry
        if ! projects="$(workspace_project_list)"; then
            log "Skipping workspace pruning because the west project list is unavailable"
            return 1
        fi
        while IFS=$'\t' read -r name path; do
            [ "${name}" = "manifest" ] && continue
            root="${path%%/*}"
            [ -z "${root}" ] || keep+=("${root}")
        done <<< "${projects}"

        shopt -s nullglob dotglob
        for entry in "${WORK_DIR}"/*; do
            name="$(basename "${entry}")"
            case "${name}" in .|..) continue ;; esac
            name_in "${name}" "${keep[@]}" && continue
            log "Removing stale workspace entry: ${name}"
            rm -rf "${entry}" || fail "failed to prune workspace entry: ${name}"
        done
        shopt -u nullglob dotglob
    }

    missing_workspace_projects() {
        local projects name path
        projects="$(workspace_project_list)" || return 1
        while IFS=$'\t' read -r name path; do
            [ "${name}" = "manifest" ] && continue
            [ -n "${path}" ] || continue
            if [ ! -d "${WORK_DIR}/${path}" ] || [ -z "$(ls -A "${WORK_DIR}/${path}" 2>/dev/null)" ]; then
                printf '%s\t%s\n' "${name}" "${path}"
            fi
        done <<< "${projects}"
    }

    workspace_projects_missing() {
        local missing
        missing="$(missing_workspace_projects)" || return 0
        [ -n "${missing}" ]
    }

    west_update_failed_projects() {
        local log_path="$1"
        sed -nE \
            -e 's/^ERROR: update failed for projects?:[[:space:]]*//p' \
            -e 's/^ERROR: update failed for project[[:space:]]+//p' \
            "${log_path}" |
            tr ',' '\n' |
            awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print}'
    }

    verify_west_update_result() {
        [ "${WEST_UPDATE_FAILED:-0}" = "1" ] || return 0

        local missing_after missing_list="" name path failed_projects unresolved="" supplied=""
        missing_after="$(missing_workspace_projects)" ||
            fail "cannot verify workspace project list after west update failure"
        if [ -n "${missing_after}" ]; then
            while IFS=$'\t' read -r name path; do
                [ -n "${name}" ] || continue
                missing_list="${missing_list}${missing_list:+, }${name} (${path})"
            done <<< "${missing_after}"
            fail "west update failed and workspace still has missing project(s): ${missing_list}"
        fi

        failed_projects="${WEST_UPDATE_FAILED_PROJECTS}"
        [ -n "${failed_projects}" ] ||
            fail "west update failed; refusing to continue with potentially stale dependencies"

        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            if local_overlay_recorded_for "${name}"; then
                supplied="${supplied}${supplied:+, }${name}"
            else
                unresolved="${unresolved}${unresolved:+, }${name}"
            fi
        done <<< "${failed_projects}"

        [ -z "${unresolved}" ] ||
            fail "west update failed for project(s) without local override: ${unresolved}"

        # Local inputs permit this build, but do not verify failed upstream checkouts.
        log "Continuing after west update failure because failed project(s) were supplied locally: ${supplied}"
    }

    clear_local_overlay_projects() {
        local mod name project_path
        while IFS= read -r -d '' mod; do
            [ -n "${mod}" ] || continue
            name="$(basename "${mod}")"
            if project_path="$(project_path_for_name "${name}")" && [ -e "${WORK_DIR}/${project_path}" ]; then
                log "Clearing stale module input overlay: ${name} -> ${project_path}"
                rm -rf "${WORK_DIR:?}/${project_path}"
            fi
        done < <(module_input_dirs)
    }

    clear_recorded_local_overlays() {
        local name project_path state backup_path need_update=1
        [ -f "${LOCAL_OVERLAY_STAMP}" ] || return 1

        while IFS=$'\t' read -r name project_path state; do
            [ -n "${project_path}" ] || continue
            case "/${project_path}/" in
                //*|*/../*) fail "invalid recorded module input overlay path: ${project_path}" ;;
            esac
            backup_path="${LOCAL_OVERLAY_BACKUP_DIR}/${name}"
            case "${state}" in
                restored)
                    mark_overlay_restore_state "${name}" "${project_path}" restored ||
                        fail "failed to record restored module input overlay: ${name}"
                    rm -rf "${backup_path}" || fail "failed to remove restored overlay backup: ${name}"
                    continue ;;
                ""|refresh) ;;
                *) fail "invalid recorded module input overlay state" ;;
            esac
            if [ -d "${backup_path}" ]; then
                log "Restoring previous module input overlay from backup: ${name} -> ${project_path}"
                # This function runs in an if condition, which disables implicit errexit.
                # Stop before discarding recovery state when either copy backend fails.
                copy_tree "${backup_path}" "${WORK_DIR}/${project_path}" ||
                    fail "failed to restore module input overlay: ${name} -> ${project_path}"
                mark_overlay_restore_state "${name}" "${project_path}" restored ||
                    fail "failed to record restored module input overlay: ${name}"
                rm -rf "${backup_path}" || fail "failed to remove restored overlay backup: ${name}"
            elif [ -e "${WORK_DIR}/${project_path}" ]; then
                mark_overlay_restore_state "${name}" "${project_path}" refresh ||
                    fail "failed to record module input overlay refresh: ${name}"
                log "Clearing previous module input overlay: ${name} -> ${project_path}"
                rm -rf "${WORK_DIR:?}/${project_path}" || fail "failed to clear previous module input overlay: ${name}"
                need_update=0
            else
                mark_overlay_restore_state "${name}" "${project_path}" refresh ||
                    fail "failed to record module input overlay refresh: ${name}"
                need_update=0
            fi
        done < "${LOCAL_OVERLAY_STAMP}"
        rm -f "${LOCAL_OVERLAY_STAMP}" || fail "failed to clear module input overlay records"
        return "${need_update}"
    }

    mark_overlay_restore_state() {
        python3 - "${LOCAL_OVERLAY_STAMP}" "$1" "$2" "$3" <<'PY'
import os
import pathlib
import sys
import tempfile

stamp = pathlib.Path(sys.argv[1])
name, path, state = sys.argv[2:]
lines = stamp.read_text(encoding="utf-8").splitlines()
updated = []
found = False
for line in lines:
    fields = line.split("\t")
    if fields[:2] == [name, path]:
        fields = [name, path, state]
        found = True
    updated.append("\t".join(fields))
if not found:
    sys.exit("overlay recovery record is missing")
temporary = None
try:
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=stamp.parent, delete=False) as output:
        temporary = output.name
        output.write("\n".join(updated) + "\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, stamp)
    directory = os.open(stamp.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    if temporary and os.path.exists(temporary):
        os.unlink(temporary)
PY
    }

    backup_module_input_overlay_project() {
        local name="$1" project_path="$2" backup_path
        backup_path="${LOCAL_OVERLAY_BACKUP_DIR}/${name}"
        rm -rf "${backup_path}"
        if [ -e "${WORK_DIR}/${project_path}" ]; then
            log "Backing up west project before module input overlay: ${name} -> ${project_path}"
            copy_tree "${WORK_DIR}/${project_path}" "${backup_path}"
        fi
    }

    record_module_input_overlay() {
        local name="$1" project_path="$2"
        mkdir -p "$(dirname "${LOCAL_OVERLAY_STAMP}")"
        printf '%s\t%s\n' "${name}" "${project_path}" >> "${LOCAL_OVERLAY_STAMP}"
    }

    local_overlay_recorded_for() {
        local wanted="$1" name project_path
        [ -f "${LOCAL_OVERLAY_STAMP}" ] || return 1
        while IFS=$'\t' read -r name project_path; do
            [ "${name}" = "${wanted}" ] && return 0
        done < "${LOCAL_OVERLAY_STAMP}"
        return 1
    }

    acquire_workspace_lock() {
        mkdir -p "${WORK_DIR}"
        # Keep the inode outside the workspace: pruning or build cleanup must not unlink it.
        # The parent shell retains this open description after Python acquires the lock.
        exec 9>"${WORK_DIR}/../.zmk-build.lock"
        python3 - <<'PY'
import fcntl
import sys

try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit("persistent workspace is already in use by another build")
PY
    }

    ensure_west_workspace() {
        sync_config_to_workspace
        cd "${WORK_DIR}"

        local need_full_update=0 west_update_attempt west_update_log stale_locks
        if [ ! -d .west ]; then
            log "Initializing west workspace"
            west init -l "${CONFIG_DIR}"
            need_full_update=1
        fi

        if clear_recorded_local_overlays; then
            need_full_update=1
        fi
        if ! prune_workspace_roots; then
            need_full_update=1
        fi
        clear_local_overlay_projects

        if manifest_changed || { [ "${APPLICATION_SOURCE}" = "zmk/app" ] && [ ! -d zmk ]; } ||
            ! west list >/dev/null 2>&1 || workspace_projects_missing; then
            need_full_update=1
        fi

        if [ "${need_full_update}" = "1" ]; then
            log "Updating west dependencies"
            validate_positive_int "ZMK_WEST_UPDATE_ATTEMPTS" "${WEST_UPDATE_ATTEMPTS}"
            # A failed/interrupted update must never leave an old ready marker in place.
            rm -f "${MANIFEST_STAMP}" || fail "failed to invalidate dependency update marker"
            WEST_UPDATE_FAILED=0
            WEST_UPDATE_FAILED_PROJECTS=""
            west_update_log="$(mktemp)"
            : > "${west_update_log}"
            for west_update_attempt in $(seq 1 "${WEST_UPDATE_ATTEMPTS}"); do
                [ "${west_update_attempt}" = "1" ] ||
                    log "Retrying west update (${west_update_attempt}/${WEST_UPDATE_ATTEMPTS})"
                stale_locks="$(find "${WORK_DIR}" -path '*/.git/index.lock' -type f 2>/dev/null || true)"
                if [ -n "${stale_locks}" ]; then
                    log "Removing stale git index.lock files"
                    find "${WORK_DIR}" -path '*/.git/index.lock' -type f -exec rm -f -- {} +
                fi
                if west update --fetch-opt=--filter=tree:0 2>&1 | tee "${west_update_log}"; then
                    WEST_UPDATE_FAILED=0
                    break
                fi
                WEST_UPDATE_FAILED=1
            done
            if [ "${WEST_UPDATE_FAILED}" = "1" ]; then
                WEST_UPDATE_FAILED_PROJECTS="$(west_update_failed_projects "${west_update_log}")"
                log "west update failed after ${WEST_UPDATE_ATTEMPTS} attempt(s); checking explicit module inputs before continuing"
            fi
            rm -f "${west_update_log}"
            west zephyr-export || true
            if [ "${WEST_UPDATE_FAILED}" != "1" ]; then
                prune_workspace_roots || fail "cannot verify workspace project list after dependency update"
                stamp_manifest
            fi
        fi
    }

    module_input_dirs() {
        local mod
        if [ -d "${EXTERNAL_MODULES_DIR}" ]; then
            for mod in "${EXTERNAL_MODULES_DIR}"/* "${EXTERNAL_MODULES_DIR}"/.[!.]* "${EXTERNAL_MODULES_DIR}"/..?*; do
                [ -d "${mod}" ] && printf '%s\0' "${mod}"
            done
        fi
    }

    project_path_for_name() {
        local wanted="$1"
        local line name path
        line="$(cd "${WORK_DIR}" && west list "${wanted}" -f $'{name}\t{path}' 2>/dev/null)" || return 1
        IFS=$'\t' read -r name path <<EOF
${line}
EOF
        [ "${name}" = "${wanted}" ] && [ -n "${path}" ] || return 1
        printf '%s\n' "${path}"
    }

    validate_module_inputs() {
        local mod name seen=()
        while IFS= read -r -d '' mod; do
            [ -n "${mod}" ] || continue
            name="$(basename "${mod}")"
            if name_in "${name}" ${seen[@]+"${seen[@]}"}; then
                fail "duplicate module input name: ${name}"
            fi
            seen+=("${name}")
            validate_module_roots "${mod}" "module input ${name}" "module"
        done < <(module_input_dirs)
    }

    sync_module_inputs() {
        local mod name project_path extra_path
        EXTRA_MODULE_PATHS=()

        while IFS= read -r -d '' mod; do
            [ -n "${mod}" ] || continue
            name="$(basename "${mod}")"
            if project_path="$(project_path_for_name "${name}")"; then
                log "Overlaying module input west project: ${name} -> ${project_path}"
                backup_module_input_overlay_project "${name}" "${project_path}"
                # Record recovery before the first destination mutation, including partial copy failures.
                record_module_input_overlay "${name}" "${project_path}"
                copy_tree "${mod}" "${WORK_DIR}/${project_path}" .git .build
            else
                extra_path="/workspaces/module-inputs/${name}"
                log "Adding module input as extra module: ${name}"
                copy_tree "${mod}" "${extra_path}" .git .build
                EXTRA_MODULE_PATHS+=("${extra_path}")
            fi
        done < <(module_input_dirs)
    }

    parse_build_yaml() {
        local host_snippets="${1:-}"
        python3 - "${SOURCE_DIR}/${BUILD_YAML}" "${host_snippets}" "${SETTINGS_RESET}" "${ZMK_FALLBACK_BINARY}" <<'PY'
from itertools import product
import re
import shlex
import sys
import yaml

yaml_path, host_snippets, settings_reset, fallback = sys.argv[1:]

with open(yaml_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f)
data = {} if data is None else data

if not isinstance(data, dict):
    print("ERROR: build.yaml must be a map.", file=sys.stderr)
    sys.exit(2)

defaults = data.get("defaults")
defaults = {} if defaults is None else defaults
if not isinstance(defaults, dict):
    print("ERROR: build.yaml defaults must be a map.", file=sys.stderr)
    sys.exit(2)

ALIASES = {
    "board": ("board",),
    "shield": ("shield",),
    "snippet": ("snippet",),
    "cmake-args": ("cmake-args", "cmake_args"),
    "extra-cmake-args": ("extra-cmake-args", "extra_cmake_args"),
    "artifact-name": ("artifact-name", "artifact_name"),
    "skip": ("skip",),
}

def raw(mapping, key):
    for alias in ALIASES[key]:
        if alias in mapping:
            return mapping[alias]
    return None

def raw_with_default(mapping, key):
    value = raw(mapping, key)
    if value is not None:
        return value
    return raw(defaults, key)

def scalar(value, key, allow_empty=False):
    if value is None and allow_empty:
        return ""
    if isinstance(value, (str, int, float, bool)):
        text = str(value).strip()
        if text or allow_empty:
            return text
        print(f"ERROR: {key} may not be empty.", file=sys.stderr)
        sys.exit(2)
    print(f"ERROR: {key} must be a scalar.", file=sys.stderr)
    sys.exit(2)

def scalar_list(value, key, allow_empty=False):
    if value is None:
        return [""] if allow_empty else []
    if isinstance(value, list):
        values = [scalar(item, key, allow_empty=allow_empty) for item in value]
        return values or ([""] if allow_empty else [])
    return [scalar(value, key, allow_empty=allow_empty)]

def joined(value, key):
    if value is None:
        return ""
    if isinstance(value, list):
        # CMake lists contain literal argv entries, including empty/padded strings.
        items = [item if key in {"cmake-args", "extra-cmake-args"} and isinstance(item, str)
                 else scalar(item, key) for item in value]
        return " ".join(shlex.quote(item) for item in items)
    return scalar(value, key, allow_empty=True)

def truthy(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (str, int, float)):
        return str(value).strip().lower() in {"1", "true", "yes", "on"}
    return False

def safe_name(value):
    value = re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("._-")
    if not value or value in {".", ".."}:
        print("ERROR: artifact-name is empty or unsafe.", file=sys.stderr)
        sys.exit(2)
    if value.split(".", 1)[0].upper() in {"CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"}:
        print(f"ERROR: artifact-name uses a Windows reserved name: {value}", file=sys.stderr)
        sys.exit(2)
    return value

def format_artifact(template, board, shield, snippet):
    if not template:
        template = f"{shield + '-' if shield else ''}{board}-zmk"
    return (
        template
        .replace("{board}", board)
        .replace("{shield}", shield)
        .replace("{snippet}", snippet)
    )

def merged_target(mapping, board, shield):
    yaml_snippet = joined(raw_with_default(mapping, "snippet"), "snippet")
    snippet = yaml_snippet
    if host_snippets:
        snippet = " ".join(part for part in (snippet, host_snippets) if part)

    cmake_args = joined(raw_with_default(mapping, "cmake-args"), "cmake-args")
    extra_cmake_args = joined(raw_with_default(mapping, "extra-cmake-args"), "extra-cmake-args")
    if extra_cmake_args:
        cmake_args = " ".join(part for part in (cmake_args, extra_cmake_args) if part)

    artifact_template = scalar(raw_with_default(mapping, "artifact-name"), "artifact-name", allow_empty=True)
    artifact = safe_name(format_artifact(artifact_template, board, shield, snippet))
    exclude_artifact = safe_name(format_artifact(artifact_template, board, shield, yaml_snippet))
    return {
        "board": board,
        "shield": shield,
        "snippet": snippet,
        "cmake-args": cmake_args,
        "artifact-name": artifact,
        "_exclude-snippet": yaml_snippet,
        "_exclude-artifact-name": exclude_artifact,
    }

def add_matrix_targets(source, require_board):
    if truthy(raw(source, "skip")):
        return []
    board_values = scalar_list(raw_with_default(source, "board"), "board")
    if not board_values:
        if require_board:
            print("ERROR: build target requires board.", file=sys.stderr)
            sys.exit(2)
        return []
    shield_values = scalar_list(raw_with_default(source, "shield"), "shield", allow_empty=True)
    targets = []
    for board, shield in product(board_values, shield_values):
        targets.append(merged_target(source, board, shield))
    return targets

targets = []
if raw(data, "board") is not None:
    targets.extend(add_matrix_targets(data, require_board=False))

entries = data.get("include")
entries = [] if entries is None else entries
if not isinstance(entries, list):
    print("ERROR: build.yaml include must be a list.", file=sys.stderr)
    sys.exit(2)

for item in entries:
    if not isinstance(item, dict):
        print("ERROR: each include entry must be a map.", file=sys.stderr)
        sys.exit(2)
    targets.extend(add_matrix_targets(item, require_board=True))

exclusions = data.get("exclude")
exclusions = [] if exclusions is None else exclusions
if not isinstance(exclusions, list):
    print("ERROR: build.yaml exclude must be a list.", file=sys.stderr)
    sys.exit(2)

for exclusion in exclusions:
    if not isinstance(exclusion, dict):
        print("ERROR: each exclude entry must be a map.", file=sys.stderr)
        sys.exit(2)

def exclusion_matches(exclusion, target):
    compared = False
    for key in ("board", "shield", "snippet", "artifact-name"):
        value = raw(exclusion, key)
        if value is None:
            continue
        compared = True
        options = scalar_list(value, key, allow_empty=True)
        target_value = target.get(f"_exclude-{key}", target[key])
        if target_value not in options:
            return False
    return compared

targets = [
    target for target in targets
    if not any(exclusion_matches(exclusion, target) for exclusion in exclusions)
]

if settings_reset == "1":
    reset_boards = []
    for target in targets:
        board = target["board"]
        if board not in reset_boards:
            reset_boards.append(board)
    existing_reset_boards = {
        target["board"] for target in targets
        if target["shield"].split() == ["settings_reset"]
    }
    for board in reset_boards:
        if board in existing_reset_boards:
            continue
        targets.append({
            "board": board,
            "shield": "settings_reset",
            "snippet": "",
            "cmake-args": "",
            "artifact-name": safe_name(f"settings_reset-{board}-zmk"),
        })

seen = set()
for target in targets:
    board = target["board"]
    shield = target["shield"]
    snippet = target["snippet"]
    cmake_args = target["cmake-args"]
    artifact = target["artifact-name"]
    key = artifact.lower()
    if f"{artifact}.{fallback}".lower() in {"build.log", "build-summary.txt"}:
        print(f"ERROR: artifact-name collides with build log or summary: {artifact}", file=sys.stderr)
        sys.exit(2)
    if key in seen:
        print(f"ERROR: duplicate artifact-name after normalization: {artifact}", file=sys.stderr)
        sys.exit(2)
    seen.add(key)
    try:
        shlex.split(cmake_args)
    except ValueError as error:
        print(f"ERROR: invalid cmake-args: {error}", file=sys.stderr)
        sys.exit(2)

    fields = [board, shield, snippet, cmake_args, artifact]
    for field in fields:
        if any(char in field for char in "\0\x1f\n\r"):
            print("ERROR: build.yaml values may not contain control separators or newlines.", file=sys.stderr)
            sys.exit(2)
    print("\x1f".join(fields))
PY
    }

    print_targets() {
        local targets="$1"
        local board shield snippet cmake_args artifact

        echo -e "${CYAN}Parsed build targets:${NC}"
        if [ ! -s "${targets}" ]; then
            echo "- No build targets."
            return 0
        fi

        while IFS="${FIELD_SEP}" read -r board shield snippet cmake_args artifact || [ -n "${board:-}" ]; do
            [ -n "${board}" ] || continue
            echo "- ${artifact}"
            echo "  board: ${board}"
            echo "  shield: ${shield:-<none>}"
            echo "  snippet: ${snippet:-<none>}"
            echo "  cmake-args: ${cmake_args:-<none>}"
        done < "${targets}"
    }

    append_cmake_args() {
        local cmake_args="$1"
        local decoded arg
        [ -n "${cmake_args}" ] || return 0

        # A NUL stream preserves empty arguments without command-substitution trimming.
        decoded="$(mktemp)"
        if ! python3 - "${cmake_args}" > "${decoded}" <<'PY'
import shlex
import sys

for arg in shlex.split(sys.argv[1]):
    sys.stdout.buffer.write(arg.encode("utf-8") + b"\0")
PY
        then
            rm -f "${decoded}"
            fail "failed to parse cmake-args"
        fi

        while IFS= read -r -d '' arg; do
            build_cmd+=("${arg}")
        done < "${decoded}"
        rm -f "${decoded}"
    }

    extra_modules_arg() {
        local joined="${USER_ZMK_EXTRA_MODULES}"
        local path
        append_extra_module_path() {
            local new_path="$1"
            [ -n "${new_path}" ] || return 0
            case ";${joined};" in
                *";${new_path};"*) return 0 ;;
            esac
            if [ -n "${joined}" ]; then
                joined="${joined};${new_path}"
            else
                joined="${new_path}"
            fi
        }

        if [ -f "${SOURCE_DIR}/zephyr/module.yml" ]; then
            append_extra_module_path "${SOURCE_DIR}"
        fi
        for path in ${EXTRA_MODULE_PATHS[@]+"${EXTRA_MODULE_PATHS[@]}"}; do
            append_extra_module_path "${path}"
        done
        printf '%s' "${joined}"
    }

    select_firmware_artifact() {
        local artifact="$1" build_dir="$2"
        local ext name candidate
        local names=(zmk merged zephyr.signed zephyr app_update)

        mkdir -p "${OUTPUT_DIR}"
        for ext in "${FIRMWARE_EXTENSIONS[@]}"; do
            for name in "${names[@]}"; do
                candidate="${build_dir}/zephyr/${name}.${ext}"
                if [ -f "${candidate}" ]; then
                    cp "${candidate}" "${OUTPUT_DIR}/${artifact}.${ext}"
                    log "Output: ${OUTPUT_DIR}/${artifact}.${ext}"
                    return 0
                fi
            done
            while IFS= read -r candidate || [ -n "${candidate}" ]; do
                [ -n "${candidate}" ] || continue
                cp "${candidate}" "${OUTPUT_DIR}/${artifact}.${ext}"
                log "Output: ${OUTPUT_DIR}/${artifact}.${ext}"
                return 0
            done < <(find "${build_dir}/zephyr" -maxdepth 1 -type f -name "*.${ext}" | sort)
        done

        fail "no firmware artifact found"
    }

    build_one() (
        local board="$1" shield="$2" snippet="$3" cmake_args="$4" artifact="$5"
        local extra_modules p_arg snippet_item build_dir status

        echo -e "\n${CYAN}>>> Building: ${artifact}${NC}"
        log "BOARD=${board} SHIELD=${shield:-<none>} SNIPPET=${snippet:-<none>}"

        cd "${WORK_DIR}"
        p_arg="-p=auto"
        [ "${PRISTINE}" = "1" ] && p_arg="-p"
        build_dir="${BUILD_DIR}/${artifact}"
        # Each target owns its exit trap, including failures before artifact copy.
        trap 'status=$?; trap - EXIT
            if ! rm -rf "${build_dir}"; then
                log "ERROR: failed to remove target build directory: ${build_dir}" >&2
                [ "${status}" != "0" ] || status=1
            fi
            exit "${status}"' EXIT
        rm -rf "${build_dir}"

        if [ "${APPLICATION_SOURCE}" != "zmk/app" ]; then
            # Do not let an image's ambient package/cache select another Zephyr tree.
            ZEPHYR_BASE="$(west list zephyr -f '{abspath}')" || fail "cannot resolve Zephyr project"
            [ -f "${ZEPHYR_BASE}/share/zephyr-package/cmake/ZephyrConfig.cmake" ] ||
                fail "resolved Zephyr project has no package configuration"
            export ZEPHYR_BASE
        fi
        build_cmd=(west build "${p_arg}" -s "${APPLICATION_SOURCE}" -d "${build_dir}" -b "${board}")
        for snippet_item in ${snippet}; do
            build_cmd+=(-S "${snippet_item}")
        done
        build_cmd+=(--)
        [ -n "${shield}" ] && build_cmd+=(-DSHIELD="${shield}")
        if [ "${APPLICATION_SOURCE}" = "zmk/app" ]; then
            build_cmd+=(-DZMK_CONFIG="${SOURCE_DIR}/${CONFIG_DIR}")
        else
            build_cmd+=(-DZephyr_DIR="${ZEPHYR_BASE}/share/zephyr-package/cmake")
        fi
        extra_modules="$(extra_modules_arg)"
        if [ -n "${extra_modules}" ]; then
            if [ "${APPLICATION_SOURCE}" = "zmk/app" ]; then
                build_cmd+=(-DZMK_EXTRA_MODULES="${extra_modules}")
            else
                build_cmd+=(-DZEPHYR_EXTRA_MODULES="${extra_modules}")
            fi
        fi
        append_cmake_args "${cmake_args}"

        "${build_cmd[@]}"
        select_firmware_artifact "${artifact}" "${build_dir}"
    )

    wait_for_build_batch() {
        local failed=0 i pid log_path artifact status
        for i in "${!BUILD_PIDS[@]}"; do
            pid="${BUILD_PIDS[$i]}"
            log_path="${BUILD_LOGS[$i]}"
            artifact="${BUILD_ARTIFACTS[$i]}"
            if wait "${pid}"; then
                status=0
            else
                status=$?
                failed=$((failed + 1))
            fi
            [ ! -f "${log_path}" ] || cat "${log_path}"
            if [ "${status}" != "0" ]; then
                echo -e "${RED}[container] ERROR: target failed: ${artifact}${NC}" >&2
            fi
        done
        BUILD_PIDS=()
        BUILD_LOGS=()
        BUILD_ARTIFACTS=()
        # Shell exit statuses wrap at 256; keep the full count as data.
        BUILD_BATCH_FAILURES="${failed}"
    }

    container_validate() {
        local host_snippets="${1:-}"
        local targets
        ensure_zmk_layout
        validate_module_inputs
        [ -f "${SOURCE_DIR}/${BUILD_YAML}" ] || fail "build.yaml not found"
        targets="$(mktemp)"
        parse_build_yaml "${host_snippets}" > "${targets}"
        print_targets "${targets}"
        rm -f "${targets}"
        echo -e "${GREEN}build.yaml is valid.${NC}"
    }

    container_build() {
        local host_snippets="${1:-}"
        local targets board shield snippet cmake_args artifact built failed target_log_dir target_log

        ensure_zmk_layout
        [ -f "${SOURCE_DIR}/${BUILD_YAML}" ] || fail "build.yaml not found"
        validate_positive_int "BUILD_JOBS" "${BUILD_JOBS}"
        validate_module_inputs
        rm -rf "${OUTPUT_DIR}"
        mkdir -p "${OUTPUT_DIR}"

        targets="$(mktemp)"
        parse_build_yaml "${host_snippets}" > "${targets}"
        [ -s "${targets}" ] || fail "build.yaml contains no build targets"

        acquire_workspace_lock
        ensure_west_workspace
        sync_module_inputs
        cd "${WORK_DIR}"
        verify_west_update_result
        west zephyr-export || true
        rm -rf "${BUILD_DIR}"
        mkdir -p "${BUILD_DIR}"

        built=0
        failed=0
        if [ "${BUILD_JOBS}" -gt 1 ]; then
            log "Building targets in parallel (jobs=${BUILD_JOBS})"
            target_log_dir="$(mktemp -d)"
            BUILD_PIDS=()
            BUILD_LOGS=()
            BUILD_ARTIFACTS=()
            while IFS="${FIELD_SEP}" read -r board shield snippet cmake_args artifact || [ -n "${board:-}" ]; do
                [ -n "${board}" ] || continue
                target_log="${target_log_dir}/${artifact}.log"
                (build_one "${board}" "${shield}" "${snippet}" "${cmake_args}" "${artifact}") > "${target_log}" 2>&1 &
                BUILD_PIDS+=("$!")
                BUILD_LOGS+=("${target_log}")
                BUILD_ARTIFACTS+=("${artifact}")
                built=$((built + 1))
                if [ ${#BUILD_PIDS[@]} -ge "${BUILD_JOBS}" ]; then
                    wait_for_build_batch
                    failed=$((failed + BUILD_BATCH_FAILURES))
                    [ "${failed}" = "0" ] || break
                fi
            done < "${targets}"
            if [ "${failed}" = "0" ] && [ ${#BUILD_PIDS[@]} -gt 0 ]; then
                wait_for_build_batch
                failed=$((failed + BUILD_BATCH_FAILURES))
            fi
            rm -rf "${target_log_dir}"
        else
            while IFS="${FIELD_SEP}" read -r board shield snippet cmake_args artifact || [ -n "${board:-}" ]; do
                [ -n "${board}" ] || continue
                build_one "${board}" "${shield}" "${snippet}" "${cmake_args}" "${artifact}"
                built=$((built + 1))
            done < "${targets}"
        fi
        rm -f "${targets}"
        [ "${failed}" = "0" ] || fail "${failed} target build(s) failed"

        echo -e "\n${GREEN}Build complete: ${built} target(s).${NC}"
    }

    case "${1:-}" in
        validate)
            shift
            container_validate "${1:-}"
            ;;
        build)
            shift
            container_build "${1:-}"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            fail "container command must be build or validate"
            ;;
    esac
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="build"
TARGET_DIR=""
TARGET_ARGS=()
PRISTINE=0
HOST_SNIPPETS=""
SETTINGS_RESET=0
BUILD_JOBS="${ZMK_BUILD_JOBS:-1}"
MODULES=()

clean_artifacts() {
    mkdir -p "${SCRIPT_DIR}/.build"
    (
        cd "${SCRIPT_DIR}/.build"
        shopt -s nullglob dotglob
        for entry in * .*; do
            case "${entry}" in
                .|..|.gitkeep) continue ;;
            esac
            rm -rf "${entry}"
        done
    )
    touch "${SCRIPT_DIR}/.build/.gitkeep"
    echo -e "${GREEN}Cleaned .build artifacts.${NC}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        validate)
            MODE="validate"
            ;;
        clean)
            clean_artifacts
            exit 0
            ;;
        --pristine)
            PRISTINE=1
            ;;
        --settings-reset)
            SETTINGS_RESET=1
            ;;
        -j|--jobs)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            BUILD_JOBS="$2"
            shift
            ;;
        -S|--snippet)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            HOST_SNIPPETS="${HOST_SNIPPETS}${HOST_SNIPPETS:+ }$2"
            shift
            ;;
        -m|--module)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            MODULES+=("$2")
            shift
            ;;
        --help|-h|help)
            usage
            exit 0
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            TARGET_ARGS+=("$1")
            ;;
    esac
    shift
done

[ ${#TARGET_ARGS[@]} -eq 1 ] || die "exactly one target directory is required"
TARGET_DIR="${TARGET_ARGS[0]}"
[ -d "${TARGET_DIR}" ] || die "target directory not found: ${TARGET_DIR}"
TARGET_DIR="$(cd "${TARGET_DIR}" && pwd)"

validate_host_layout() {
    [ -f "${TARGET_DIR}/config/west.yml" ] ||
        die "current ZMK layout requires repo root with config/west.yml"
    [ -f "${TARGET_DIR}/build.yaml" ] || die "build.yaml not found"
}

validate_host_module_metadata() {
    local root="$1" label="$2"
    [ -d "${root}/boards" ] || [ -d "${root}/dts" ] || [ -d "${root}/snippets" ] ||
        [ -f "${root}/CMakeLists.txt" ] || [ -f "${root}/Kconfig" ] || return 0
    [ -f "${root}/zephyr/module.yml" ] ||
        die "${label}: root module content requires zephyr/module.yml"

    # YAML layout and required keys are checked structurally in the container. Grepping
    # host-side text would reject valid inline maps and quoted keys.
}

require_host_commands() {
    local missing=0 cmd
    for cmd in "$@"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            echo "Missing required command: ${cmd}" >&2
            missing=1
        fi
    done
    [ "${missing}" = "0" ] || exit 1
}

require_tar_exclude() {
    tar cf - --exclude 'zmk-capability-probe' -T /dev/null >/dev/null 2>&1 ||
        die "tar must support --exclude"
}

validate_one_module_input() {
    local mod="$1" label_prefix="$2" name
    [ -d "${mod}" ] || die "module input directory not found: ${mod}"
    name="$(basename "${mod}")"
    if name_in "${name}" ${VALIDATED_MODULE_NAMES[@]+"${VALIDATED_MODULE_NAMES[@]}"}; then
        die "duplicate module input name: ${name}"
    fi
    validate_host_module_metadata "${mod}" "${label_prefix} ${name}"
    VALIDATED_MODULE_NAMES+=("${name}")
}

validate_module_inputs() {
    local mod index=0
    VALIDATED_MODULE_NAMES=()
    for mod in ${MODULES[@]+"${MODULES[@]}"}; do
        [ -d "${mod}" ] || die "module input directory not found: ${mod}"
        mod="$(cd -- "${mod}" && pwd)"
        validate_one_module_input "${mod}" "module input"
        MODULES[${index}]="${mod}"
        index=$((index + 1))
    done
}

trim_manifest_scalar() {
    local value="$1"
    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "${value}" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    printf '%s\n' "${value}"
}

detect_zmk_revision() {
    local manifest="${TARGET_DIR}/config/west.yml" revision
    [ -f "${manifest}" ] || return 1
    revision="$(
        awk '
            function clean_scalar(value) {
                sub(/[[:space:]]*#.*/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if ((value ~ /^".*"$/) || (value ~ /^\047.*\047$/)) {
                    value = substr(value, 2, length(value) - 2)
                }
                return value
            }
            /^[[:space:]]*-[[:space:]]*name[[:space:]]*:/ {
                name = $0
                sub(/^[[:space:]]*-[[:space:]]*name[[:space:]]*:[[:space:]]*/, "", name)
                in_zmk = (clean_scalar(name) == "zmk")
                next
            }
            in_zmk && /^[[:space:]]*revision[[:space:]]*:/ {
                sub(/^[[:space:]]*revision[[:space:]]*:[[:space:]]*/, "", $0)
                print
                exit
            }
        ' "${manifest}"
    )"
    [ -n "${revision}" ] || return 1
    trim_manifest_scalar "${revision}"
}

docker_tag_for_zmk_revision() {
    local revision="$1"
    case "${revision}" in
        ""|main|master)
            printf '%s\n' "stable"
            ;;
        v0.3|v0.3.*|v0.3-*|0.3|0.3.*|0.3-*)
            printf '%s\n' "3.5-branch"
            ;;
        v4.1|v4.1.*|v4.1-*|4.1|4.1.*|4.1-*)
            printf '%s\n' "4.1-branch"
            ;;
        *)
            printf '%s\n' "stable"
            ;;
    esac
}

resolve_docker_image() {
    local tag="${1:-${ZMK_BUILD_IMAGE_TAG:-auto}}"
    if [ -n "${ZMK_BUILD_IMAGE:-}" ]; then
        printf '%s\n' "${ZMK_BUILD_IMAGE}"
    else
        printf '%s:%s\n' "${ZMK_BUILD_IMAGE_REPOSITORY:-zmkfirmware/zmk-build-arm}" "${tag}"
    fi
}

run_id="run-$(date +%Y-%m-%d_%H-%M-%S)-pid-$$"
container_name="zmk-build-${run_id}"
container_name="${ZMK_CONTAINER_NAME:-${container_name}}"
container_created=0
container_id=""
container_create_output=""
active_phase_pid=""
run_signal_status=0
run_phase=""

handle_run_signal() {
    trap '' INT TERM
    run_signal_status="$2"
    RUN_FAILURE_REASON="interrupted by $1"
    # Finish create so its returned identity can be acquired before cleanup.
    [ "${run_phase}" != create ] || return 0
    exit "${run_signal_status}"
}

run_logged_command() {
    local capture="$1" status=0
    shift
    (
        trap - EXIT
        if [ "${run_phase}" = create ]; then
            # The entire receipt pipeline must survive a terminal/process-group signal.
            trap '' INT TERM
        else
            trap - INT TERM
        fi
        if [ -n "${capture}" ]; then
            "$@" 2>&1 | tee -a "${LOG_FILE}" "${capture}"
        else
            "$@" 2>&1 | tee -a "${LOG_FILE}"
        fi
    ) &
    active_phase_pid=$!
    if wait "${active_phase_pid}"; then status=0; else status=$?; fi
    if [ "${run_phase}" = create ] && [ "${run_signal_status}" != 0 ]; then
        if [ "${status}" -ge 128 ]; then
            if wait "${active_phase_pid}"; then status=0; else status="${run_signal_status}"; fi
        elif [ "${status}" != 0 ]; then
            status="${run_signal_status}"
        fi
    fi
    active_phase_pid=""
    return "${status}"
}

cleanup_container() {
    if [ "${container_created}" = "1" ] && [ "${ZMK_KEEP_CONTAINER:-0}" != "1" ]; then
        if ! docker rm -f "${container_id}" >>"${LOG_FILE}" 2>&1; then
            echo "ERROR: failed to remove build container: ${container_id}" | tee -a "${LOG_FILE}" >&2
            return 1
        fi
        container_created=0
    fi
    return 0
}
finish_run() {
    local status="$?" cleanup_failed=0 reason="${RUN_FAILURE_REASON:-host setup failed}"
    trap - EXIT
    if [ "${run_signal_status}" != 0 ] && [ "${container_created}" = 1 ] && [ "${ZMK_KEEP_CONTAINER:-0}" = 1 ] && [ "${run_phase}" != created ]; then
        if ! docker stop -t 1 "${container_id}" >>"${LOG_FILE}" 2>&1; then
            echo 'ERROR: failed to stop interrupted build container' >>"${LOG_FILE}"
            cleanup_failed=1
        fi
    fi
    if ! cleanup_container; then
        cleanup_failed=1
        if [ "${status}" = 0 ]; then
            status=1
            reason="container cleanup failed"
        else
            reason="${SUMMARY_REASON:-${reason}}"
        fi
    fi
    if [ -n "${active_phase_pid}" ]; then
        kill -TERM "${active_phase_pid}" 2>/dev/null || true
        wait "${active_phase_pid}" 2>/dev/null || true
    fi
    if [ "${status}" -ne 0 ] && [ -n "${artifact_dir:-}" ] &&
        { [ "${SUMMARY_WRITTEN:-0}" != "1" ] || [ "${cleanup_failed}" = 1 ]; }; then
        write_summary "FAILED" "${reason}" || true
    fi
    [ -z "${container_create_output}" ] || rm -f "${container_create_output}"
    exit "${status}"
}
trap finish_run EXIT
trap 'handle_run_signal SIGINT 130' INT
trap 'handle_run_signal SIGTERM 143' TERM

is_generated_dependency_tree() {
    local path="$1"
    [ -d "${path}" ] || return 1
    [ -e "${path}/.git" ] && return 0
    find "${path}" -mindepth 2 -maxdepth 4 -name .git -print -quit 2>/dev/null | grep -q .
}

build_tar_excludes() {
    local source_dir="${1:-${TARGET_DIR}}" generated_dir
    # Nested VCS/cache markers are excluded at every depth. Select root entries explicitly:
    # BSD tar treats even "./build" as an unanchored pattern and would also remove nested/build.
    SOURCE_TAR_EXCLUDES=(--exclude .git --exclude .west --exclude __pycache__)
    SOURCE_ROOT_EXCLUDES=(.zmk .build .cache .ccache .vscode build dist node_modules out tmp zmk_search)
    if [ -d "${source_dir}/.west" ]; then
        for generated_dir in zmk modules tools bootloader optional; do
            if is_generated_dependency_tree "${source_dir}/${generated_dir}"; then
                SOURCE_ROOT_EXCLUDES+=("${generated_dir}")
            fi
        done
    fi
}

is_excluded_source_root() {
    local path="${1#./}" excluded
    path="${path%%/*}"
    for excluded in "${SOURCE_ROOT_EXCLUDES[@]}"; do
        [ "${path}" != "${excluded}" ] || return 0
    done
    return 1
}

# Write the files of ${dir} that Git shows (tracked, plus untracked and not ignored) as a NUL-separated "./path" list.
# Returns 1 when the list cannot be used, so that the caller copies the whole directory: ZMK_COPY_IGNORED=1, no git,
# not a Git working tree, git failing (for example "dubious ownership"), or no file left.
git_visible_file_list() {
    local dir="$1" out="$2" raw file
    [ "${ZMK_COPY_IGNORED:-0}" != "1" ] || return 1
    command -v git >/dev/null 2>&1 || return 1
    # BSD tar supports --null but omits it from its short help; probe an empty file list instead.
    tar cf - --null -T /dev/null >/dev/null 2>&1 || return 1
    raw="${out}.raw"
    # Native git.exe does not understand MSYS paths while path conversion is off, so enter the directory first.
    if ! (cd "${dir}" && git rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
        git ls-files -z --cached --others --exclude-standard) >"${raw}" 2>/dev/null; then
        rm -f "${raw}"
        return 1
    fi
    # A tracked file deleted from the work tree is still listed; tar would fail on it.
    while IFS= read -r -d '' file; do
        if ! is_excluded_source_root "${file}" && { [ -e "${dir}/${file}" ] || [ -L "${dir}/${file}" ]; }; then
            printf './%s\0' "${file}"
        fi
    done <"${raw}" >"${out}"
    rm -f "${raw}"
    [ -s "${out}" ]
}

# Write ${dir} as a tar stream. A Git working tree is copied without the files its ignore rules match (artifacts/,
# web/node_modules/ ...), which can be gigabytes; anything else is copied whole. SOURCE_TAR_EXCLUDES apply to both.
tar_source_dir() {
    local dir="$1" list path name status=0
    local entries=()
    build_tar_excludes "${dir}"
    list="$(mktemp "${TMPDIR:-/tmp}/zmk-source-list.XXXXXX")"
    if git_visible_file_list "${dir}" "${list}"; then
        echo "Copying only the files Git shows for ${dir} (ZMK_COPY_IGNORED=1 copies ignored files too)" >&2
        (cd "${dir}" && tar cf - "${SOURCE_TAR_EXCLUDES[@]}" --null -T "${list}") || status=$?
    else
        for path in "${dir}"/* "${dir}"/.[!.]* "${dir}"/..?*; do
            [ -e "${path}" ] || [ -L "${path}" ] || continue
            name="${path##*/}"
            is_excluded_source_root "${name}" && continue
            entries+=("./${name}")
        done
        if [ "${#entries[@]}" -gt 0 ]; then
            (cd "${dir}" && tar cf - "${SOURCE_TAR_EXCLUDES[@]}" "${entries[@]}") || status=$?
        else
            (cd "${dir}" && tar cf - --exclude '*' .) || status=$?
        fi
    fi
    rm -f "${list}" "${list}.raw"
    return "${status}"
}

copy_target_to_container() {
    docker exec "${container_id}" mkdir -p /root/zmk-config
    tar_source_dir "${TARGET_DIR}" |
        docker exec -i "${container_id}" tar --no-same-owner -xf - -C /root/zmk-config

    tr -d '\r' < "$0" |
        docker exec -i "${container_id}" /bin/bash -c 'cat > /root/zmk-config/build.sh && chmod +x /root/zmk-config/build.sh'

    local mod name
    [ "${#MODULES[@]}" -gt 0 ] || return 0
    for mod in ${MODULES[@]+"${MODULES[@]}"}; do
        name="$(basename "${mod}")"
        msg "Copying module: ${name}"
        tar_source_dir "${mod}" |
            docker exec -i "${container_id}" /bin/bash -c 'mkdir -p "/root/external_modules/$1" && tar --no-same-owner -xf - -C "/root/external_modules/$1"' _ "${name}"
    done
}

copy_artifacts_from_container() {
    local artifact_dir="$1"
    mkdir -p "${artifact_dir}"
    if ! docker exec "${container_id}" tar -C /root/zmk-config/.build -cf - . |
        (cd "${artifact_dir}" && tar xf -); then
        echo "failed to copy build output from the container" >&2
        return 1
    fi
    if ! firmware_files "${artifact_dir}" | grep -q .; then
        echo "no firmware artifact was copied from the container" >&2
        return 1
    fi
}

failure_excerpt() {
    if [ -f "${LOG_FILE}" ]; then
        tail -n 160 "${LOG_FILE}" | sed -E $'s/\x1B\\[[0-9;?]*[ -/]*[@-~]//g'
    fi
}

built_target_count() {
    if [ -f "${LOG_FILE}" ]; then
        sed -E $'s/\x1B\\[[0-9;?]*[ -/]*[@-~]//g' "${LOG_FILE}" |
            tr -d '\r' |
            sed -n 's/.*Build complete: \([0-9][0-9]*\) target(s)\..*/\1/p' |
            tail -n 1
    fi
}

firmware_artifact_count() {
    firmware_files "${artifact_dir}" |
        sed '/^$/d' |
        wc -l |
        tr -d '[:space:]'
}

write_summary() {
    local status="$1" reason="${2:-}" elapsed built_targets
    elapsed="$(( $(date +%s) - RUN_STARTED_AT ))"
    built_targets="$(built_target_count)"
    if [ -z "${built_targets}" ] && [ "${MODE}" = "build" ] && [ "${status}" = "SUCCESS" ]; then
        built_targets="$(firmware_artifact_count)"
    fi

    {
        echo "ZMK Build Summary"
        echo "================="
        echo
        echo "Status: ${status}"
        [ -z "${reason}" ] || echo "Reason: ${reason}"
        echo "Mode: ${MODE}"
        echo "Target: ${TARGET_DIR}"
        echo "Docker image: ${zmk_build_image}"
        echo "Docker cache volume: ${zmk_cache_volume}"
        echo "Elapsed: ${elapsed}s"
        if [ -n "${built_targets}" ]; then
            echo "Built targets: ${built_targets}"
        fi
        echo "Pristine: ${PRISTINE}"
        echo "Build jobs: ${BUILD_JOBS}"
        echo "Fallback binary: ${ZMK_FALLBACK_BINARY:-bin}"
        echo "Extra snippets: ${HOST_SNIPPETS:-<none>}"
        if [ ${#MODULES[@]} -gt 0 ]; then
            echo "Module inputs:"
            printf '  - %s\n' "${MODULES[@]}"
        else
            echo "Module inputs: <none>"
        fi
        echo
        echo "Files"
        echo "-----"
        echo "- build.log"
        if firmware_files "${artifact_dir}" | grep -q .; then
            firmware_files "${artifact_dir}" |
                sort |
                while IFS= read -r file; do
                    echo "- $(basename "${file}")"
                done
        fi
        if [ "${status}" != "SUCCESS" ]; then
            echo
            echo "Failure excerpt"
            echo "---------------"
            failure_excerpt
        fi
    } > "${artifact_dir}/build-summary.txt"
    SUMMARY_WRITTEN=1
    SUMMARY_REASON="${reason}"
}

reset_cache_volume() {
    local volumes volume
    if ! volumes="$(docker volume ls --format '{{.Name}}' 2>&1)"; then
        printf '%s\n' "${volumes}" | tee -a "${LOG_FILE}" >&2
        return 1
    fi
    while IFS= read -r volume; do
        [ "${volume}" = "${zmk_cache_volume}" ] || continue
        if ! docker volume rm "${zmk_cache_volume}" 2>&1 | tee -a "${LOG_FILE}"; then
            return 1
        fi
        return 0
    done <<< "${volumes}"
    msg "Cache volume is not present; starting fresh: ${zmk_cache_volume}" | tee -a "${LOG_FILE}"
}

validate_host_layout
validate_module_inputs
validate_positive_int "build jobs" "${BUILD_JOBS}"
validate_positive_int "ZMK_WEST_UPDATE_ATTEMPTS" "${ZMK_WEST_UPDATE_ATTEMPTS:-3}"
validate_firmware_extension "${ZMK_FALLBACK_BINARY:-bin}"
require_host_commands docker tar
require_tar_exclude

requested_image_tag="${ZMK_BUILD_IMAGE_TAG:-auto}"
resolved_image_tag="${requested_image_tag}"
detected_zmk_revision=""
if [ -z "${ZMK_BUILD_IMAGE:-}" ] && [ "${requested_image_tag}" = "auto" ]; then
    detected_zmk_revision="$(detect_zmk_revision || true)"
    resolved_image_tag="$(docker_tag_for_zmk_revision "${detected_zmk_revision}")"
fi
zmk_build_image="$(resolve_docker_image "${resolved_image_tag}")"
zmk_cache_volume="${ZMK_DOCKER_CACHE_VOLUME:-zmk-cache}"
# ccache lives on the cache volume so that it survives the throw-away build container (see README.md).
zmk_ccache_dir="${ZMK_CCACHE_DIR:-/workspaces/.ccache}"
RUN_STARTED_AT="$(date +%s)"
artifact_dir="${SCRIPT_DIR}/.build/${run_id}"
LOG_FILE="${artifact_dir}/build.log"
mkdir -p "${artifact_dir}"
touch "${LOG_FILE}"
touch "${SCRIPT_DIR}/.build/.gitkeep" 2>>"${LOG_FILE}"

echo -e "${CYAN}Starting ZMK ${MODE}...${NC}"
msg "Target: ${TARGET_DIR}"
if [ -z "${ZMK_BUILD_IMAGE:-}" ] && [ "${requested_image_tag}" = "auto" ]; then
    msg "Detected ZMK revision: ${detected_zmk_revision:-<unknown>} (Docker tag: ${resolved_image_tag})"
fi
msg "Docker image: ${zmk_build_image}"
msg "Docker cache volume: ${zmk_cache_volume}"
msg "Build jobs: ${BUILD_JOBS}"
msg "Container: ${container_name}"

if [ "${PRISTINE}" = 1 ]; then
    RUN_FAILURE_REASON="cache reset failed"
    reset_cache_volume || die "failed to reset Docker cache volume: ${zmk_cache_volume}"
fi

RUN_FAILURE_REASON="container creation failed"
run_phase=create
docker_create_args=(create --name "${container_name}")
if [ -n "${ZMK_DOCKER_PLATFORM:-}" ]; then
    docker_create_args+=(--platform "${ZMK_DOCKER_PLATFORM}")
fi
# Keep platform and default paths on one set of volume/environment arguments.
container_create_output="$(mktemp "${TMPDIR:-/tmp}/zmk-container-create.XXXXXX")"
run_logged_command "${container_create_output}" docker "${docker_create_args[@]}" \
    -v "${zmk_cache_volume}:/workspaces" \
    -e ZMK_IN_CONTAINER=1 \
    -e PRISTINE="${PRISTINE}" \
    -e SETTINGS_RESET="${SETTINGS_RESET}" \
    -e BUILD_JOBS="${BUILD_JOBS}" \
    -e ZMK_WEST_UPDATE_ATTEMPTS="${ZMK_WEST_UPDATE_ATTEMPTS:-3}" \
    -e ZMK_FALLBACK_BINARY="${ZMK_FALLBACK_BINARY:-bin}" \
    -e CCACHE_DIR="${zmk_ccache_dir}" \
    -e CCACHE_IGNOREOPTIONS='-specs=*' \
    -e USER_ZMK_EXTRA_MODULES="${ZMK_EXTRA_MODULES:-}" \
    "${zmk_build_image}" /bin/sh -lc ': > /tmp/zmk-build-stream.log; tail -n +1 -f /tmp/zmk-build-stream.log'
container_id="$(tr -d '\r' < "${container_create_output}" | awk 'length($0) == 64 && $0 !~ /[^0-9a-f]/ && !found {print; found=1}')"
[ -n "${container_id}" ] || die "Docker create did not return a container ID"
container_created=1
run_phase=created
[ "${run_signal_status}" = 0 ] || exit "${run_signal_status}"
rm -f "${container_create_output}"
container_create_output=""
RUN_FAILURE_REASON="container start failed"
run_phase=start
run_logged_command "" docker start "${container_id}"

RUN_FAILURE_REASON="source copy failed"
run_phase=copy
run_logged_command "" copy_target_to_container
RUN_FAILURE_REASON="${MODE} execution failed"
run_phase=execute

if [ "${MODE}" = "validate" ]; then
    if run_logged_command "" docker exec "${container_id}" /bin/bash -lc 'set -o pipefail; cd /root/zmk-config && ./build.sh validate "$@" 2>&1 | tee -a /tmp/zmk-build-stream.log' _ "${HOST_SNIPPETS}"; then
        write_summary "SUCCESS"
        echo -e "${CYAN}${artifact_dir}${NC}"
        exit 0
    fi
    write_summary "FAILED" "validation failed"
    echo -e "${RED}Validation failed. See: ${artifact_dir}${NC}" >&2
    exit 1
fi

if ! run_logged_command "" docker exec "${container_id}" /bin/bash -lc 'set -o pipefail; cd /root/zmk-config && ./build.sh build "$@" 2>&1 | tee -a /tmp/zmk-build-stream.log' _ "${HOST_SNIPPETS}"; then
    write_summary "FAILED" "firmware build failed"
    echo -e "${RED}Build failed. See: ${artifact_dir}${NC}" >&2
    exit 1
fi

run_phase=artifact
if ! run_logged_command "" copy_artifacts_from_container "${artifact_dir}"; then
    write_summary "FAILED" "artifact copy failed"
    echo -e "${RED}Artifact copy failed. See: ${artifact_dir}${NC}" >&2
    exit 1
fi

write_summary "SUCCESS"

echo -e "\n${GREEN}Artifacts:${NC}"
firmware_files "${artifact_dir}" | sort | while IFS= read -r file; do
    printf '  - %s\n' "$(basename "${file}")"
done
echo -e "${CYAN}${artifact_dir}${NC}"
