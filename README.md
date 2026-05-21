# ZMK Build Script

Small Docker + Bash helper for building current-layout ZMK keyboard repositories.

The script intentionally supports only the modern ZMK layout:

```text
your-zmk-config/
+-- build.yaml
+-- config/
|   +-- west.yml
|   +-- <keyboard>.conf
|   +-- <keyboard>.keymap
|   +-- boards/...        # accepted for ZMK config compatibility
+-- zephyr/
|   +-- module.yml        # optional module metadata
+-- boards/...            # optional module/user board and shield definitions
+-- dts/...               # optional, requires build.settings.dts_root: .
+-- snippets/<name>/...   # optional, requires build.settings.snippet_root: .
```

The script follows ZMK's search paths instead of banning `config/boards`. Root
module content under `dts/` or `snippets/` must be declared in `zephyr/module.yml`.
When a legacy target repo has root module content plus root `module.yml` but no
`zephyr/module.yml`, the container creates a transient `zephyr/module.yml` from
the current root layout. The source repo is not modified.

## Requirements

- Docker Desktop or Docker Engine
- Bash

On Windows, use Git Bash. PowerShell can launch Git Bash, but the script itself
must run under Bash. Use a normal Bash environment with standard Unix tools
available.

## Build

```bash
./build.sh ../your-zmk-config --pristine
```

The target repository must have `build.yaml` with an `include:` list:

```yaml
include:
  - board: nice_nano/nrf52840/zmk
    shield: corne_left nice_view_adapter
    snippet: studio-rpc-usb-uart
    artifact-name: example_corne_left
```

Supported per-target keys:

| Key | Meaning |
| --- | --- |
| `board` | Required. Passed to `west build -b`. |
| `shield` | Optional. Passed as `-DSHIELD=...`. |
| `snippet` | Optional. Passed with `west build -S`. |
| `cmake-args` | Optional. Parsed with `shlex.split`. |
| `extra-cmake-args` | Optional. Appended after `cmake-args`. |
| `artifact-name` | Optional output base name. |
| `skip` | Optional for `include:` entries. Skips the target when true. |

Top-level `board:` and `shield:` arrays are expanded as a matrix. `include:`
entries may also use board/shield arrays. `exclude:` removes matching generated
targets, and `defaults:` supplies missing target values. `artifact-name` may use
`{board}`, `{shield}`, and `{snippet}` placeholders.

Each build target copies back one firmware file only. Preference order is
`.uf2`, `ZMK_FALLBACK_BINARY` (default `.bin`), `.hex`, then `.bin`.

Artifacts are saved under:

```text
.build/run-YYYY-MM-DD_HH-MM-SS-pid-PID/
+-- example_corne_left.uf2
+-- build.log
+-- build-summary.txt
```

Example: `.build/run-2026-05-21_20-50-31-pid-1234/`.

## Validate

```bash
./build.sh validate ../your-zmk-config
```

Validation parses `build.yaml` inside the ZMK Docker image and prints the target
list. It also writes `build.log` and `build-summary.txt` under `.build/`.

Use `--settings-reset` to add a `settings_reset` build target for each board that
does not already have one:

```bash
./build.sh validate ../your-zmk-config --settings-reset
```

## CI Coverage

The CI fixture focuses on two representative ZMK 4.1 HWMv2 boards:

- `nice_nano/nrf52840/zmk`
- `xiao_ble/nrf52840/zmk`

Both boards build `settings_reset`; `nice_nano` covers Corne left/right plus the
heavier snippet, multi-shield, and CMake argument targets, while `xiao_ble`
covers the XIAO-specific `tester_xiao` shield. This covers the build script's
common board, shield, snippet, CMake argument, settings reset, and artifact
collection paths. It is not an exhaustive build of every upstream ZMK board.

Target-shape parsing is covered separately by
`.github/fixtures/target-shapes-zmk-config`, which is validate-only. It exercises
top-level matrix expansion, include matrix expansion, `defaults`, `exclude`,
`skip`, alias keys, placeholders, and `--settings-reset` de-duplication without
adding more firmware build targets.

Local west project override is covered by
`.github/fixtures/module-override-zmk-config`. CI copies the resolved
`zmk-studio-messages` and `zcbor` west projects from the cache, passes both
back with `-m`, also passes one extra module, asserts both
`Overlaying local west project` and `Adding local extra module` paths, and
builds one studio-enabled firmware target so multiple `-m` inputs and nested
paths such as `proto/zmk` stay covered. The follow-up build restores the
recorded overlay projects from workspace-local backups instead of resetting the
full Docker volume.

## Extra Snippets

```bash
./build.sh ../your-zmk-config -S zmk-usb-logging
```

Extra snippets are appended to every parsed target.

Root snippets must follow Zephyr module rules. Put them at repo root under
`snippets/` and declare the root in `zephyr/module.yml`:

```yaml
build:
  settings:
    snippet_root: .
```

## Local Modules

```bash
./build.sh ../your-zmk-config -m ../zmk-input-matrix
```

Modules passed with `-m` are copied into Docker. If the directory name matches a
west project name, that project is overlaid after `west update`. Otherwise it is
passed to ZMK through `ZMK_EXTRA_MODULES`. Modules in this tool's
`local_modules/` directory are loaded the same way.

If a previous local overlay left files in the persistent west workspace, the
matching project directory is cleared before `west update` so the next checkout
does not conflict with stale local files.

## Clean

```bash
./build.sh clean
```

Removes generated `.build` runs while keeping `.build/.gitkeep`.

## Self-hosted Runners

The hosted `Compatibility` workflow is the default release gate. Use
`SELF_HOSTED_RUNNERS.md` only when you need Docker validation on your own
Windows, macOS, or Linux machines.

## Docker Image

Default image:

```text
zmkfirmware/zmk-build-arm:stable
```

Overrides:

```bash
ZMK_BUILD_IMAGE=zmkfirmware/zmk-build-arm:stable ./build.sh ../your-zmk-config
ZMK_BUILD_IMAGE_TAG=4.1-branch ./build.sh ../your-zmk-config
ZMK_DOCKER_PLATFORM=linux/amd64 ./build.sh ../your-zmk-config
```

## What The Script Does

1. Copies the target repo into `/root/zmk-config` in Docker.
2. Skips top-level local/generated directories such as `.cache`, `.ccache`, `.vscode`,
   `build`, `dist`, `node_modules`, `out`, `tmp`, and `zmk_search`.
3. Normalizes legacy root `module.yml` to a transient `zephyr/module.yml` when
   root module content needs to be exposed to Zephyr.
4. Copies only `config/` into the persistent west workspace.
5. Builds with `ZMK_CONFIG=/root/zmk-config/config` so ZMK can see both
   `config/boards` and root `boards`.
6. If `zephyr/module.yml` exists, passes `/root/zmk-config` through
   `ZMK_EXTRA_MODULES`.
7. Runs `west update` only when the workspace needs it.
8. Restores any previous local west project overlays from backup, then applies
   `local_modules/` and `-m` module overrides.
9. Builds each generated `build.yaml` target.
10. Copies one firmware artifact per target back to `.build/`.
11. Writes `build.log` and `build-summary.txt`, including a failure excerpt when
   validation or firmware build fails.
