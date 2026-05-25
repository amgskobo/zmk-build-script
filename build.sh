#!/usr/bin/env bash
# ZMK local build helper for current ZMK config/module layout.
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
  ./build.sh <zmk-config-root> [--pristine] [--settings-reset] [-S snippet] [-m module-dir]
  ./build.sh validate <zmk-config-root> [--settings-reset] [-S snippet] [-m module-dir]
  ./build.sh clean

Supported target layout:
  zmk-config/
    build.yaml
    config/west.yml
    config/<keyboard>.conf
    config/<keyboard>.keymap
    boards/...              # optional user config board/shield definitions
    zephyr/module.yml       # optional module metadata
    snippets/<name>/...     # optional, requires snippet_root in module.yml

Environment:
  ZMK_BUILD_IMAGE            Full Docker image override.
  ZMK_BUILD_IMAGE_REPOSITORY Docker image repository (default: zmkfirmware/zmk-build-arm).
  ZMK_BUILD_IMAGE_TAG        Docker image tag (default: auto; main -> stable, v0.3 -> 3.5-branch, 4.1 -> 4.1-branch).
  ZMK_DOCKER_PLATFORM        Optional docker --platform value.
  ZMK_FALLBACK_BINARY        Fallback firmware extension after uf2 (default: bin).
EOF
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
    MANIFEST_FILE="${WORK_DIR}/${CONFIG_DIR}/west.yml"
    MANIFEST_STAMP="${WORK_DIR}/.west/manifest.sha256"
    LOCAL_OVERLAY_STAMP="${WORK_DIR}/.west/local-overlays.tsv"
    LOCAL_OVERLAY_BACKUP_DIR="${WORK_DIR}/.west/local-overlay-backups"
    PRISTINE="${PRISTINE:-0}"
    SETTINGS_RESET="${SETTINGS_RESET:-0}"
    USER_ZMK_EXTRA_MODULES="${USER_ZMK_EXTRA_MODULES:-}"
    ZMK_FALLBACK_BINARY="${ZMK_FALLBACK_BINARY:-bin}"
    LOCAL_MODULES_DIR="${LOCAL_MODULES_DIR:-/root/local_modules}"
    EXTERNAL_MODULES_DIR="${EXTERNAL_MODULES_DIR:-/root/external_modules}"
    FIRMWARE_EXTENSIONS=(uf2 "${ZMK_FALLBACK_BINARY}" hex bin)
    FIELD_SEP=$'\037'
    EXTRA_MODULE_PATHS=()
    WEST_UPDATE_FAILED=0
    WEST_UPDATE_FAILED_PROJECTS=""
    WEST_UPDATE_MISSING_PROJECTS=""

    ensure_zmk_layout() {
        [ -f "${SOURCE_DIR}/${CONFIG_DIR}/west.yml" ] ||
            fail "current ZMK layout requires ${CONFIG_DIR}/west.yml"

        normalize_legacy_target_module

        if [ -d "${SOURCE_DIR}/zephyr" ] &&
            find "${SOURCE_DIR}/zephyr" -mindepth 1 -print -quit | grep -q .; then
            [ -f "${SOURCE_DIR}/zephyr/module.yml" ] ||
                fail "zephyr/ may only contain module.yml in current ZMK module layout"
            if find "${SOURCE_DIR}/zephyr" -mindepth 1 ! -name module.yml -print -quit | grep -q .; then
                fail "zephyr/ may only contain module.yml. Move module source to repo root."
            fi
        fi

        validate_module_roots "${SOURCE_DIR}" "target" "target"
    }

    normalize_legacy_target_module() {
        [ ! -f "${SOURCE_DIR}/zephyr/module.yml" ] || return 0
        [ -f "${SOURCE_DIR}/module.yml" ] || return 0

        if [ ! -f "${SOURCE_DIR}/CMakeLists.txt" ] &&
            [ ! -f "${SOURCE_DIR}/Kconfig" ] &&
            [ ! -d "${SOURCE_DIR}/boards" ] &&
            [ ! -d "${SOURCE_DIR}/dts" ] &&
            [ ! -d "${SOURCE_DIR}/snippets" ]; then
            return 0
        fi

        log "Normalizing legacy root module.yml to zephyr/module.yml"
        mkdir -p "${SOURCE_DIR}/zephyr"
        {
            echo "build:"
            [ -f "${SOURCE_DIR}/CMakeLists.txt" ] && echo "  cmake: ."
            [ -f "${SOURCE_DIR}/Kconfig" ] && echo "  kconfig: Kconfig"
            if [ -d "${SOURCE_DIR}/boards" ] ||
                [ -d "${SOURCE_DIR}/dts" ] ||
                [ -d "${SOURCE_DIR}/snippets" ]; then
                echo "  settings:"
                [ -d "${SOURCE_DIR}/boards" ] && echo "    board_root: ."
                [ -d "${SOURCE_DIR}/dts" ] && echo "    dts_root: ."
                [ -d "${SOURCE_DIR}/snippets" ] && echo "    snippet_root: ."
            fi
        } > "${SOURCE_DIR}/zephyr/module.yml"
        return 0
    }

    validate_module_roots() {
        local root="$1" label="$2" kind="$3"
        local need_settings=()

        if [ "${kind}" = "module" ] && [ -d "${root}/boards" ]; then
            need_settings+=(board_root)
        fi
        if [ -d "${root}/dts" ]; then
            need_settings+=(dts_root)
        fi
        if [ -d "${root}/snippets" ]; then
            need_settings+=(snippet_root)
        fi

        [ ${#need_settings[@]} -gt 0 ] || return 0
        local module_yml="${root}/zephyr/module.yml"
        [ -f "${module_yml}" ] ||
            fail "${label}: root ${need_settings[*]} requires zephyr/module.yml with build.settings entries"

        python3 - "${module_yml}" "${label}" "${need_settings[@]}" <<'PY'
import sys
import yaml

module_yml, label, *required = sys.argv[1:]

with open(module_yml, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

if not isinstance(data, dict):
    print(f"{label}: zephyr/module.yml must be a map.", file=sys.stderr)
    sys.exit(1)

build = data.get("build") or {}
if not isinstance(build, dict):
    print(f"{label}: zephyr/module.yml build must be a map.", file=sys.stderr)
    sys.exit(1)

settings = build.get("settings") or {}
if not isinstance(settings, dict):
    print(f"{label}: zephyr/module.yml build.settings must be a map.", file=sys.stderr)
    sys.exit(1)

missing = [name for name in required if settings.get(name) not in (".", "./")]
if missing:
    joined = ", ".join(f"build.settings.{name}: ." for name in missing)
    print(f"{label}: root module content requires {joined}", file=sys.stderr)
    sys.exit(1)
PY
    }

    clear_dir() {
        local dir="$1" entry
        shopt -s nullglob dotglob
        for entry in "${dir:?}"/*; do
            rm -rf "${entry}"
        done
        shopt -u nullglob dotglob
    }

    copy_tree() {
        local src="$1" dst="$2"
        mkdir -p "${dst}"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete "${src}/" "${dst}/"
        else
            clear_dir "${dst}"
            (cd "${src}" && tar cf - .) | (cd "${dst}" && tar xf -)
        fi
    }

    copy_module_tree() {
        local src="$1" dst="$2"
        mkdir -p "${dst}"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete --exclude .git --exclude .build "${src}/" "${dst}/"
        else
            clear_dir "${dst}"
            (cd "${src}" && tar cf - --exclude .git --exclude .build .) | (cd "${dst}" && tar xf -)
        fi
    }

    sync_config_to_workspace() {
        log "Syncing config into persistent west workspace"
        mkdir -p "${WORK_DIR}"
        copy_tree "${SOURCE_DIR}/${CONFIG_DIR}" "${WORK_DIR}/${CONFIG_DIR}"
    }

    manifest_digest() {
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "${MANIFEST_FILE}" | awk '{print $1}'
        else
            cksum "${MANIFEST_FILE}" | awk '{print $1":"$2}'
        fi
    }

    manifest_changed() {
        [ ! -f "${MANIFEST_STAMP}" ] || [ "$(manifest_digest)" != "$(cat "${MANIFEST_STAMP}")" ]
    }

    stamp_manifest() {
        mkdir -p "$(dirname "${MANIFEST_STAMP}")"
        manifest_digest > "${MANIFEST_STAMP}"
    }

    prune_workspace_roots() {
        cd "${WORK_DIR}"
        local keep=" .west .build ${CONFIG_DIR} "
        local name path root entry

        if [ -d .west ] && west list >/dev/null 2>&1; then
            while IFS=$'\t' read -r name path; do
                [ "${name}" = "manifest" ] && continue
                root="${path%%/*}"
                [ -n "${root}" ] && keep="${keep}${root} "
            done < <(west list -f $'{name}\t{path}')
        fi

        shopt -s nullglob dotglob
        for entry in "${WORK_DIR}"/* "${WORK_DIR}"/.*; do
            name="$(basename "${entry}")"
            case "${name}" in
                .|..) continue ;;
            esac
            [[ "${keep}" == *" ${name} "* ]] && continue
            log "Removing stale workspace entry: ${name}"
            rm -rf "${entry}"
        done
        shopt -u nullglob dotglob
    }

    missing_workspace_projects() {
        local name path
        cd "${WORK_DIR}"
        while IFS=$'\t' read -r name path; do
            [ "${name}" = "manifest" ] && continue
            if [ ! -d "${WORK_DIR}/${path}" ] || [ -z "$(ls -A "${WORK_DIR}/${path}" 2>/dev/null)" ]; then
                printf '%s\t%s\n' "${name}" "${path}"
            fi
        done < <(west list -f $'{name}\t{path}')
    }

    workspace_projects_missing() {
        [ -n "$(missing_workspace_projects)" ]
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
        missing_after="$(missing_workspace_projects || true)"
        if [ -n "${missing_after}" ]; then
            while IFS=$'\t' read -r name path; do
                [ -n "${name}" ] || continue
                missing_list="${missing_list}${missing_list:+, }${name} (${path})"
            done <<< "${missing_after}"
            fail "west update failed and workspace still has missing project(s): ${missing_list}"
        fi

        failed_projects="${WEST_UPDATE_FAILED_PROJECTS}"
        if [ -z "${failed_projects}" ] && [ -n "${WEST_UPDATE_MISSING_PROJECTS}" ]; then
            failed_projects="$(printf '%s\n' "${WEST_UPDATE_MISSING_PROJECTS}" | awk -F '\t' '{print $1}')"
        fi
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

        log "Continuing after west update failure because failed project(s) were supplied locally: ${supplied}"
        stamp_manifest
    }

    clear_local_overlay_projects() {
        local mod name project_path
        while IFS= read -r mod; do
            [ -n "${mod}" ] || continue
            name="$(basename "${mod}")"
            if project_path="$(project_path_for_name "${name}")" && [ -e "${WORK_DIR}/${project_path}" ]; then
                log "Clearing stale local overlay: ${name} -> ${project_path}"
                rm -rf "${WORK_DIR:?}/${project_path}"
            fi
        done < <(local_module_dirs)
    }

    clear_recorded_local_overlays() {
        local name project_path backup_path need_update=1
        [ -f "${LOCAL_OVERLAY_STAMP}" ] || return 1

        while IFS=$'\t' read -r name project_path; do
            [ -n "${project_path}" ] || continue
            case "${project_path}" in
                /*|*..*) fail "invalid recorded local overlay path: ${project_path}" ;;
            esac
            backup_path="${LOCAL_OVERLAY_BACKUP_DIR}/${name}"
            if [ -d "${backup_path}" ]; then
                log "Restoring previous local overlay from backup: ${name} -> ${project_path}"
                copy_tree "${backup_path}" "${WORK_DIR}/${project_path}"
                rm -rf "${backup_path}"
            elif [ -e "${WORK_DIR}/${project_path}" ]; then
                log "Clearing previous local overlay: ${name} -> ${project_path}"
                rm -rf "${WORK_DIR:?}/${project_path}"
                need_update=0
            else
                need_update=0
            fi
        done < "${LOCAL_OVERLAY_STAMP}"
        rm -f "${LOCAL_OVERLAY_STAMP}"
        return "${need_update}"
    }

    backup_local_overlay_project() {
        local name="$1" project_path="$2" backup_path
        backup_path="${LOCAL_OVERLAY_BACKUP_DIR}/${name}"
        rm -rf "${backup_path}"
        if [ -e "${WORK_DIR}/${project_path}" ]; then
            log "Backing up west project before local overlay: ${name} -> ${project_path}"
            copy_tree "${WORK_DIR}/${project_path}" "${backup_path}"
        fi
    }

    record_local_overlay() {
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

    ensure_west_workspace() {
        sync_config_to_workspace
        cd "${WORK_DIR}"

        local need_full_update=0
        if [ ! -d .west ]; then
            log "Initializing west workspace"
            west init -l "${CONFIG_DIR}"
            need_full_update=1
        fi

        prune_workspace_roots
        if clear_recorded_local_overlays; then
            need_full_update=1
        fi
        clear_local_overlay_projects

        if manifest_changed || [ ! -d zmk ] || ! west list >/dev/null 2>&1 || workspace_projects_missing; then
            need_full_update=1
        fi

        if [ "${need_full_update}" = "1" ]; then
            local west_update_log
            log "Updating west dependencies"
            WEST_UPDATE_FAILED=0
            WEST_UPDATE_FAILED_PROJECTS=""
            WEST_UPDATE_MISSING_PROJECTS=""
            west_update_log="$(mktemp)"
            if ! west update --fetch-opt=--filter=tree:0 2>&1 | tee "${west_update_log}"; then
                WEST_UPDATE_FAILED=1
                WEST_UPDATE_FAILED_PROJECTS="$(west_update_failed_projects "${west_update_log}")"
                WEST_UPDATE_MISSING_PROJECTS="$(missing_workspace_projects || true)"
                log "west update failed; checking local module overrides before continuing"
            fi
            rm -f "${west_update_log}"
            west zephyr-export || true
            [ "${WEST_UPDATE_FAILED}" = "1" ] || stamp_manifest
        fi
    }

    local_module_dirs() {
        local mod
        if [ -d "${LOCAL_MODULES_DIR}" ]; then
            for mod in "${LOCAL_MODULES_DIR}"/*; do
                [ -d "${mod}" ] && printf '%s\n' "${mod}"
            done
        fi
        if [ -d "${EXTERNAL_MODULES_DIR}" ]; then
            for mod in "${EXTERNAL_MODULES_DIR}"/*; do
                [ -d "${mod}" ] && printf '%s\n' "${mod}"
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

    sync_local_modules() {
        local mod name project_path extra_path seen=" "
        EXTRA_MODULE_PATHS=()

        while IFS= read -r mod; do
            [ -n "${mod}" ] || continue
            name="$(basename "${mod}")"
            case "${seen}" in
                *" ${name} "*) fail "duplicate local module name: ${name}" ;;
            esac
            seen="${seen}${name} "
            validate_module_roots "${mod}" "local module ${name}" "module"
            if project_path="$(project_path_for_name "${name}")"; then
                log "Overlaying local west project: ${name} -> ${project_path}"
                backup_local_overlay_project "${name}" "${project_path}"
                copy_module_tree "${mod}" "${WORK_DIR}/${project_path}"
                record_local_overlay "${name}" "${project_path}"
            else
                extra_path="/workspaces/local-extra-modules/${name}"
                log "Adding local extra module: ${name}"
                copy_module_tree "${mod}" "${extra_path}"
                EXTRA_MODULE_PATHS+=("${extra_path}")
            fi
        done < <(local_module_dirs)
    }

    parse_build_yaml() {
        local host_snippets="${1:-}"
        python3 - "${SOURCE_DIR}/${BUILD_YAML}" "${host_snippets}" "${SETTINGS_RESET}" <<'PY'
from itertools import product
import re
import shlex
import sys
import yaml

yaml_path, host_snippets, settings_reset = sys.argv[1], sys.argv[2], sys.argv[3]

with open(yaml_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

if not isinstance(data, dict):
    print("ERROR: build.yaml must be a map.", file=sys.stderr)
    sys.exit(2)

defaults = data.get("defaults") or {}
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
    if value is None:
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
        return " ".join(shlex.quote(str(item).strip()) for item in value if str(item).strip())
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
    if value.upper() in {"CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"}:
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
    snippet = joined(raw_with_default(mapping, "snippet"), "snippet")
    if host_snippets:
        snippet = " ".join(part for part in (snippet, host_snippets) if part)

    cmake_args = joined(raw_with_default(mapping, "cmake-args"), "cmake-args")
    extra_cmake_args = joined(raw_with_default(mapping, "extra-cmake-args"), "extra-cmake-args")
    if extra_cmake_args:
        cmake_args = " ".join(part for part in (cmake_args, extra_cmake_args) if part)

    artifact_template = scalar(raw_with_default(mapping, "artifact-name"), "artifact-name", allow_empty=True)
    artifact = safe_name(format_artifact(artifact_template, board, shield, snippet))
    return {
        "board": board,
        "shield": shield,
        "snippet": snippet,
        "cmake-args": cmake_args,
        "artifact-name": artifact,
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

entries = data.get("include") or []
if not isinstance(entries, list):
    print("ERROR: build.yaml include must be a list.", file=sys.stderr)
    sys.exit(2)

for item in entries:
    if not isinstance(item, dict):
        print("ERROR: each include entry must be a map.", file=sys.stderr)
        sys.exit(2)
    targets.extend(add_matrix_targets(item, require_board=True))

exclusions = data.get("exclude") or []
if not isinstance(exclusions, list):
    print("ERROR: build.yaml exclude must be a list.", file=sys.stderr)
    sys.exit(2)

def exclusion_matches(exclusion, target):
    if not isinstance(exclusion, dict):
        print("ERROR: each exclude entry must be a map.", file=sys.stderr)
        sys.exit(2)
    compared = False
    for key in ("board", "shield", "snippet", "artifact-name"):
        value = raw(exclusion, key)
        if value is None:
            continue
        compared = True
        options = scalar_list(value, key, allow_empty=True)
        if target[key] not in options:
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
    if key in seen:
        print(f"ERROR: duplicate artifact-name after normalization: {artifact}", file=sys.stderr)
        sys.exit(2)
    seen.add(key)

    fields = [board, shield, snippet, cmake_args, artifact]
    for field in fields:
        if "\x1f" in field or "\n" in field or "\r" in field:
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

        if ! decoded="$(python3 - "${cmake_args}" <<'PY'
import shlex
import sys

for arg in shlex.split(sys.argv[1]):
    print(arg)
PY
)"; then
            fail "failed to parse cmake-args"
        fi

        while IFS= read -r arg || [ -n "${arg}" ]; do
            [ -n "${arg}" ] && build_cmd+=("${arg}")
        done <<< "${decoded}"
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
        for path in "${EXTRA_MODULE_PATHS[@]}"; do
            append_extra_module_path "${path}"
        done
        printf '%s' "${joined}"
    }

    select_firmware_artifact() {
        local artifact="$1"
        local ext name candidate
        local names=(zmk merged zephyr.signed zephyr app_update)

        mkdir -p "${OUTPUT_DIR}"
        for ext in "${FIRMWARE_EXTENSIONS[@]}"; do
            for name in "${names[@]}"; do
                candidate="${BUILD_DIR}/zephyr/${name}.${ext}"
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
            done < <(find "${BUILD_DIR}/zephyr" -maxdepth 1 -type f -name "*.${ext}" | sort)
        done

        fail "no firmware artifact found"
    }

    build_one() {
        local board="$1" shield="$2" snippet="$3" cmake_args="$4" artifact="$5"
        local extra_modules p_arg snippet_item

        echo -e "\n${CYAN}>>> Building: ${artifact}${NC}"
        log "BOARD=${board} SHIELD=${shield:-<none>} SNIPPET=${snippet:-<none>}"

        cd "${WORK_DIR}"
        p_arg="-p=auto"
        [ "${PRISTINE}" = "1" ] && p_arg="-p"

        build_cmd=(west build "${p_arg}" -s zmk/app -d "${BUILD_DIR}" -b "${board}")
        for snippet_item in ${snippet}; do
            build_cmd+=(-S "${snippet_item}")
        done
        build_cmd+=(--)
        [ -n "${shield}" ] && build_cmd+=(-DSHIELD="${shield}")
        build_cmd+=(-DZMK_CONFIG="${SOURCE_DIR}/${CONFIG_DIR}")
        extra_modules="$(extra_modules_arg)"
        [ -n "${extra_modules}" ] && build_cmd+=(-DZMK_EXTRA_MODULES="${extra_modules}")
        append_cmake_args "${cmake_args}"

        "${build_cmd[@]}"
        select_firmware_artifact "${artifact}"
        rm -rf "${BUILD_DIR}"
    }

    container_validate() {
        local host_snippets="${1:-}"
        local targets
        ensure_zmk_layout
        [ -f "${SOURCE_DIR}/${BUILD_YAML}" ] || fail "build.yaml not found"
        targets="$(mktemp)"
        parse_build_yaml "${host_snippets}" > "${targets}"
        print_targets "${targets}"
        rm -f "${targets}"
        echo -e "${GREEN}build.yaml is valid.${NC}"
    }

    container_build() {
        local host_snippets="${1:-}"
        local targets board shield snippet cmake_args artifact built

        ensure_zmk_layout
        [ -f "${SOURCE_DIR}/${BUILD_YAML}" ] || fail "build.yaml not found"
        rm -rf "${OUTPUT_DIR}"
        mkdir -p "${OUTPUT_DIR}"

        targets="$(mktemp)"
        parse_build_yaml "${host_snippets}" > "${targets}"
        [ -s "${targets}" ] || fail "build.yaml contains no build targets"

        ensure_west_workspace
        sync_local_modules
        cd "${WORK_DIR}"
        verify_west_update_result
        west zephyr-export || true

        built=0
        while IFS="${FIELD_SEP}" read -r board shield snippet cmake_args artifact || [ -n "${board:-}" ]; do
            [ -n "${board}" ] || continue
            build_one "${board}" "${shield}" "${snippet}" "${cmake_args}" "${artifact}"
            built=$((built + 1))
        done < "${targets}"
        rm -f "${targets}"

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
PRISTINE=0
HOST_SNIPPETS=""
SETTINGS_RESET=0
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
            [ -z "${TARGET_DIR}" ] || die "only one target directory is supported"
            TARGET_DIR="$1"
            ;;
    esac
    shift
done

[ -n "${TARGET_DIR}" ] || die "target directory is required"
[ -d "${TARGET_DIR}" ] || die "target directory not found: ${TARGET_DIR}"
TARGET_DIR="$(cd "${TARGET_DIR}" && pwd)"

validate_host_layout() {
    [ -f "${TARGET_DIR}/config/west.yml" ] ||
        die "current ZMK layout requires repo root with config/west.yml"
    if [ -d "${TARGET_DIR}/zephyr" ] &&
        find "${TARGET_DIR}/zephyr" -mindepth 1 -print -quit | grep -q .; then
        [ -f "${TARGET_DIR}/zephyr/module.yml" ] ||
            die "zephyr/ may only contain module.yml"
        if find "${TARGET_DIR}/zephyr" -mindepth 1 ! -name module.yml -print -quit | grep -q .; then
            die "zephyr/ may only contain module.yml"
        fi
    fi
    validate_host_module_roots "${TARGET_DIR}" "target" "target"
    [ -f "${TARGET_DIR}/build.yaml" ] || die "build.yaml not found"
}

module_yml_mentions_root_setting() {
    local module_yml="$1" setting="$2"
    grep -Eq "^[[:space:]]*${setting}:[[:space:]]*\"?\\./?\"?[[:space:]]*(#.*)?$" "${module_yml}" ||
        grep -Eq "^[[:space:]]*${setting}:[[:space:]]*'?\\./?'?[[:space:]]*(#.*)?$" "${module_yml}"
}

validate_host_module_roots() {
    local root="$1" label="$2" kind="$3"
    local settings=()
    if [ "${kind}" = "module" ] && [ -d "${root}/boards" ]; then
        settings+=(board_root)
    fi
    if [ -d "${root}/dts" ]; then
        settings+=(dts_root)
    fi
    if [ -d "${root}/snippets" ]; then
        settings+=(snippet_root)
    fi
    [ ${#settings[@]} -gt 0 ] || return 0
    local module_yml="${root}/zephyr/module.yml"
    if [ ! -f "${module_yml}" ] && [ "${kind}" = "target" ] && [ -f "${root}/module.yml" ]; then
        return 0
    fi
    [ -f "${module_yml}" ] ||
        die "${label}: root ${settings[*]} requires zephyr/module.yml with build.settings entries"

    local setting
    for setting in "${settings[@]}"; do
        module_yml_mentions_root_setting "${module_yml}" "${setting}" ||
            die "${label}: root module content requires build.settings.${setting}: ."
    done
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

validate_module_inputs() {
    local mod name seen=" "
    [ "${#MODULES[@]}" -gt 0 ] || return 0
    for mod in "${MODULES[@]}"; do
        [ -d "${mod}" ] || die "local module directory not found: ${mod}"
        name="$(basename "${mod}")"
        case "${seen}" in
            *" ${name} "*) die "duplicate local module name: ${name}" ;;
        esac
        validate_host_module_roots "${mod}" "local module ${name}" "module"
        seen="${seen}${name} "
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
        v0.3|v0.3.*|v0.3-branch|0.3|0.3.*)
            printf '%s\n' "3.5-branch"
            ;;
        v4.1|v4.1.*|4.1|4.1.*|4.1-branch)
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

cleanup_container() {
    if [ "${container_created}" = "1" ] && [ "${ZMK_KEEP_CONTAINER:-0}" != "1" ]; then
        docker rm -f "${container_name}" >/dev/null 2>&1 || true
    fi
}
trap cleanup_container EXIT

build_tar_excludes() {
    local source_dir="${1:-${TARGET_DIR}}"
    SOURCE_TAR_EXCLUDES=(
        --exclude .git
        --exclude .west
        --exclude './.zmk'
        --exclude './.build'
        --exclude './.cache'
        --exclude './.ccache'
        --exclude './.vscode'
        --exclude __pycache__
        --exclude './build'
        --exclude './dist'
        --exclude './node_modules'
        --exclude './out'
        --exclude './tmp'
        --exclude './zmk_search'
    )
    if [ -d "${source_dir}/.west" ]; then
        SOURCE_TAR_EXCLUDES+=(
            --exclude './zmk'
            --exclude './modules'
            --exclude './tools'
            --exclude './bootloader'
            --exclude './optional'
        )
    fi
}

copy_target_to_container() {
    docker exec "${container_name}" mkdir -p /root/zmk-config
    build_tar_excludes "${TARGET_DIR}"
    (cd "${TARGET_DIR}" && tar cf - "${SOURCE_TAR_EXCLUDES[@]}" .) |
        docker exec -i "${container_name}" tar --no-same-owner -xf - -C /root/zmk-config

    tr -d '\r' < "$0" |
        docker exec -i "${container_name}" /bin/bash -c 'cat > /root/zmk-config/build.sh && chmod +x /root/zmk-config/build.sh'

    if [ -d "${SCRIPT_DIR}/local_modules" ]; then
        msg "Copying local_modules/"
        local local_mod local_name
        for local_mod in "${SCRIPT_DIR}/local_modules"/*; do
            [ -d "${local_mod}" ] || continue
            local_name="$(basename "${local_mod}")"
            build_tar_excludes "${local_mod}"
            (cd "${local_mod}" && tar cf - "${SOURCE_TAR_EXCLUDES[@]}" .) |
                docker exec -i "${container_name}" /bin/bash -c 'mkdir -p "/root/local_modules/$1" && tar --no-same-owner -xf - -C "/root/local_modules/$1"' _ "${local_name}"
        done
    fi

    local mod name
    [ "${#MODULES[@]}" -gt 0 ] || return 0
    for mod in "${MODULES[@]}"; do
        name="$(basename "${mod}")"
        msg "Copying module: ${name}"
        build_tar_excludes "${mod}"
        (cd "${mod}" && tar cf - "${SOURCE_TAR_EXCLUDES[@]}" .) |
            docker exec -i "${container_name}" /bin/bash -c 'mkdir -p "/root/external_modules/$1" && tar --no-same-owner -xf - -C "/root/external_modules/$1"' _ "${name}"
    done
}

copy_artifacts_from_container() {
    local artifact_dir="$1"
    mkdir -p "${artifact_dir}"
    docker exec "${container_name}" tar -C /root/zmk-config/.build -cf - . |
        (cd "${artifact_dir}" && tar xf -)
    if ! find "${artifact_dir}" -maxdepth 1 -type f \( -name '*.uf2' -o -name '*.hex' -o -name '*.bin' \) | grep -q .; then
        die "no firmware artifact was copied from the container"
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
            sed -n 's/^Build complete: \([0-9][0-9]*\) target(s)\.$/\1/p' |
            tail -n 1
    fi
}

write_summary() {
    local status="$1" reason="${2:-}" elapsed built_targets
    elapsed="$(( $(date +%s) - RUN_STARTED_AT ))"
    built_targets="$(built_target_count)"

    {
        echo "ZMK Build Summary"
        echo "================="
        echo
        echo "Status: ${status}"
        [ -z "${reason}" ] || echo "Reason: ${reason}"
        echo "Mode: ${MODE}"
        echo "Target: ${TARGET_DIR}"
        echo "Docker image: ${zmk_build_image}"
        echo "Elapsed: ${elapsed}s"
        if [ -n "${built_targets}" ]; then
            echo "Built targets: ${built_targets}"
        fi
        echo "Pristine: ${PRISTINE}"
        echo "Extra snippets: ${HOST_SNIPPETS:-<none>}"
        if [ ${#MODULES[@]} -gt 0 ]; then
            echo "Local modules:"
            printf '  - %s\n' "${MODULES[@]}"
        else
            echo "Local modules: <none>"
        fi
        echo
        echo "Files"
        echo "-----"
        echo "- build.log"
        if find "${artifact_dir}" -maxdepth 1 -type f \( -name '*.uf2' -o -name '*.hex' -o -name '*.bin' \) | grep -q .; then
            find "${artifact_dir}" -maxdepth 1 -type f \( -name '*.uf2' -o -name '*.hex' -o -name '*.bin' \) |
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
}

validate_host_layout
validate_module_inputs
require_host_commands docker tar

requested_image_tag="${ZMK_BUILD_IMAGE_TAG:-auto}"
resolved_image_tag="${requested_image_tag}"
detected_zmk_revision=""
if [ -z "${ZMK_BUILD_IMAGE:-}" ] && [ "${requested_image_tag}" = "auto" ]; then
    detected_zmk_revision="$(detect_zmk_revision || true)"
    resolved_image_tag="$(docker_tag_for_zmk_revision "${detected_zmk_revision}")"
fi
zmk_build_image="$(resolve_docker_image "${resolved_image_tag}")"
RUN_STARTED_AT="$(date +%s)"
artifact_dir="${SCRIPT_DIR}/.build/${run_id}"
LOG_FILE="${artifact_dir}/build.log"
mkdir -p "${artifact_dir}"
touch "${SCRIPT_DIR}/.build/.gitkeep"

echo -e "${CYAN}Starting ZMK ${MODE}...${NC}"
msg "Target: ${TARGET_DIR}"
if [ -z "${ZMK_BUILD_IMAGE:-}" ] && [ "${requested_image_tag}" = "auto" ]; then
    msg "Detected ZMK revision: ${detected_zmk_revision:-<unknown>} (Docker tag: ${resolved_image_tag})"
fi
msg "Docker image: ${zmk_build_image}"

docker rm -f "${container_name}" >/dev/null 2>&1 || true
if [ -n "${ZMK_DOCKER_PLATFORM:-}" ]; then
    docker create --name "${container_name}" \
        --platform "${ZMK_DOCKER_PLATFORM}" \
        -v zmk-cache:/workspaces \
        -e ZMK_IN_CONTAINER=1 \
        -e PRISTINE="${PRISTINE}" \
        -e SETTINGS_RESET="${SETTINGS_RESET}" \
        -e ZMK_FALLBACK_BINARY="${ZMK_FALLBACK_BINARY:-bin}" \
        -e USER_ZMK_EXTRA_MODULES="${ZMK_EXTRA_MODULES:-}" \
        "${zmk_build_image}" tail -f /dev/null >/dev/null
else
    docker create --name "${container_name}" \
        -v zmk-cache:/workspaces \
        -e ZMK_IN_CONTAINER=1 \
        -e PRISTINE="${PRISTINE}" \
        -e SETTINGS_RESET="${SETTINGS_RESET}" \
        -e ZMK_FALLBACK_BINARY="${ZMK_FALLBACK_BINARY:-bin}" \
        -e USER_ZMK_EXTRA_MODULES="${ZMK_EXTRA_MODULES:-}" \
        "${zmk_build_image}" tail -f /dev/null >/dev/null
fi
container_created=1
docker start "${container_name}" >/dev/null

copy_target_to_container

if [ "${MODE}" = "validate" ]; then
    if docker exec "${container_name}" /bin/bash -lc 'cd /root/zmk-config && ./build.sh validate "$@"' _ "${HOST_SNIPPETS}" 2>&1 | tee "${LOG_FILE}"; then
        write_summary "SUCCESS"
        echo -e "${CYAN}${artifact_dir}${NC}"
        exit 0
    fi
    write_summary "FAILED" "validation failed"
    echo -e "${RED}Validation failed. See: ${artifact_dir}${NC}" >&2
    exit 1
fi

if ! docker exec "${container_name}" /bin/bash -lc 'cd /root/zmk-config && ./build.sh build "$@"' _ "${HOST_SNIPPETS}" 2>&1 | tee "${LOG_FILE}"; then
    write_summary "FAILED" "firmware build failed"
    echo -e "${RED}Build failed. See: ${artifact_dir}${NC}" >&2
    exit 1
fi

if ! copy_artifacts_from_container "${artifact_dir}"; then
    write_summary "FAILED" "artifact copy failed"
    echo -e "${RED}Artifact copy failed. See: ${artifact_dir}${NC}" >&2
    exit 1
fi

write_summary "SUCCESS"

echo -e "\n${GREEN}Artifacts:${NC}"
find "${artifact_dir}" -maxdepth 1 -type f \( -name '*.uf2' -o -name '*.hex' -o -name '*.bin' \) | sort | while IFS= read -r file; do
    printf '  - %s\n' "$(basename "${file}")"
done
echo -e "${CYAN}${artifact_dir}${NC}"
