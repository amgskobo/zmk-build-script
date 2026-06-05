# ZMK Build Script

[日本語版 README](README.ja.md)

Small Docker + Bash helper for building current-layout ZMK keyboard repositories.

The script intentionally supports only the modern ZMK layout:

```text
your-zmk-config/
+-- build.yaml
+-- config/
|   +-- west.yml
|   +-- <keyboard>.conf
|   +-- <keyboard>.keymap
|   +-- boards/...        # legacy compatibility path; do not use for new repos
+-- zephyr/
|   +-- module.yml        # optional module metadata
+-- boards/...            # standard user/module board and shield definitions
+-- dts/...               # optional, requires build.settings.dts_root: .
+-- snippets/<name>/...   # optional, requires build.settings.snippet_root: .
```

The script follows ZMK's search paths instead of banning `config/boards`, but
new repos should use root `boards/` or an external module. Root module content
under `dts/` or `snippets/` must be declared in `zephyr/module.yml`. When a
legacy target repo has root module content plus root `module.yml` but no
`zephyr/module.yml`, the container creates a transient `zephyr/module.yml` from
the current root layout. The source repo is not modified.

## Key Features

- Cross-platform host flow: Windows, macOS, and Linux use the same Docker + Bash
  script entrypoint.
- Host CPU independent: AMD64/x86_64 and ARM64 hosts run through Docker; the
  `zmk-build-arm` image name refers to the firmware toolchain, not the host CPU.
- Local module override: `-m <dir>` and `local_modules/` can overlay matching
  west projects or be added as extra ZMK modules.
- Persistent west workspace: dependencies are reused between runs, while the
  target config is copied fresh each time.
- Safe overlay restore: local west project overrides are backed up and restored
  on the next build.
- Target parallel build: `--jobs N` / `ZMK_BUILD_JOBS=N` can build `build.yaml`
  targets in parallel. External full/pristine workflow runs default this to 1
  to avoid stacking target parallelism on top of Ninja's own compile
  parallelism.
- One artifact per target: `.uf2` is preferred, with `.bin` / `.hex` fallback
  support.
- CI coverage: representative ZMK 4.1 HWMv2 boards, target-shape parsing, and
  multiple local module override paths are validated.

## Requirements

- Docker Desktop or Docker Engine
- Bash

On Windows, use Git Bash. PowerShell can launch Git Bash, but the script itself
must run under Bash. Use a normal Bash environment with standard Unix tools
available.

## Use On Windows, macOS, And Linux

The same script works on all three host OSes as long as Docker is running and
the command is executed by Bash.

Host CPU architecture is normally not part of the script contract. AMD64/x86_64
and ARM64 hosts both run the same command through Docker. The `zmk-build-arm`
image name refers to the ARM firmware toolchain used for ZMK boards, not a
requirement that the host machine itself is ARM.

If Docker cannot choose a working image platform automatically, or if an ARM64
host needs the amd64 image, set:

```bash
ZMK_DOCKER_PLATFORM=linux/amd64 ./build.sh ../your-zmk-config --pristine
```

When building multiple repositories at the same time, set a different
`ZMK_DOCKER_CACHE_VOLUME` per repository to isolate the persistent west
workspace inside Docker. Single-repository builds can keep the default
`zmk-cache` volume.

Build output is also mirrored into the build container's own log stream. With
`ZMK_KEEP_CONTAINER=1`, you can inspect the same stream later with
`docker logs -f <container>` or Docker Desktop.

### Windows

1. Install Docker Desktop and Git for Windows.
2. Start Docker Desktop and wait until the Linux engine is ready.
3. Run from Git Bash:

```bash
./build.sh ../your-zmk-config --pristine
```

PowerShell is fine as a launcher, but call Git Bash explicitly so `bash` does
not resolve to WSL by accident:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' ./build.sh ../your-zmk-config --pristine
```

### macOS

1. Install Docker Desktop or another Docker Engine setup.
2. Start Docker.
3. Run from Terminal:

```bash
./build.sh ../your-zmk-config --pristine
```

### Linux

1. Install Docker Engine or Docker Desktop.
2. Make sure `docker ps` works from your user shell.
3. Run from Bash:

```bash
./build.sh ../your-zmk-config --pristine
```

## Build

```bash
./build.sh ../your-zmk-config --pristine
```

When `build.yaml` contains multiple targets, each target can use its own build
directory and run in parallel:

```bash
./build.sh ../your-zmk-config --pristine --jobs 2
ZMK_BUILD_JOBS=2 ./build.sh ../your-zmk-config --pristine
```

`--jobs` controls target-level parallelism only. Each target still runs its own
`west build`, and Ninja may parallelize compilation inside that target. Use
`--jobs 1` for cold `--pristine` builds on constrained runners.

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
.build/
+-- run-YYYY-MM-DD_HH-MM-SS-pid-PID/
    +-- example_corne_left.uf2
    +-- build.log
    +-- build-summary.txt
```

Example: `.build/run-2026-05-21_20-50-31-pid-1234/`.
Run directory names are part of the output contract and must follow
`run-YYYY-MM-DD_HH-MM-SS-pid-PID`; output checks sort valid run directories by
that name and fail if a `build-summary.txt` appears outside this convention.

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

Generated west project directories are filtered per copy source, so cached
dependencies are skipped without dropping intentional module content.

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
Windows, macOS, or Linux machines. Self-hosted Docker jobs require runners with
the OS label (`Windows`, `macOS`, or `Linux`), `zmk-docker`, and
`zmk-docker-active`.

## Docker Image

The default tag mode is `auto`. In auto mode the script reads
`config/west.yml`, detects the `zmk` project revision, and chooses the Docker
image tag:

- `main`, `master`, or unknown revision -> `stable`
- `v0.3` / `0.3` / `v0.3-*` / `0.3-*` -> `3.5-branch`
- `v4.1` / `4.1` / `v4.1-*` / `4.1-*` -> `4.1-branch`

For current ZMK `main`, this resolves to:

```text
zmkfirmware/zmk-build-arm:stable
```

Explicit overrides always win:

```bash
ZMK_BUILD_IMAGE=zmkfirmware/zmk-build-arm:stable ./build.sh ../your-zmk-config
ZMK_BUILD_IMAGE_TAG=4.1-branch ./build.sh ../your-zmk-config
ZMK_DOCKER_PLATFORM=linux/amd64 ./build.sh ../your-zmk-config
ZMK_DOCKER_CACHE_VOLUME=zmk-cache-my-keyboard ./build.sh ../your-zmk-config
ZMK_BUILD_JOBS=2 ./build.sh ../your-zmk-config
ZMK_WEST_UPDATE_ATTEMPTS=5 ./build.sh ../your-zmk-config
ZMK_EXTERNAL_CLONE_ATTEMPTS=5 bash ./scripts/build-external-source.sh --repo https://github.com/example/zmk-config.git
```

## External Repository Auto Builds

Put one source per line in `repos.txt`. A source may be a ZMK config repository
URL or a local path. The `Auto Build External ZMK Repos` workflow runs a matrix
job per source. `build.sh` always handles exactly one target directory; source
parallelism lives in `scripts/auto-build-external.sh` or the GitHub Actions job
matrix. Each source job starts one `build.sh` process via
`scripts/build-external-source.sh`, with slug-specific clone directories, Docker
cache volumes, container names, and artifact uploads. URL sources are cloned in a
Docker container and copied back to the host with `docker cp`, so no extra
required host dependency is added. URL clone is retried 3 times by default; set
`ZMK_EXTERNAL_CLONE_ATTEMPTS=N` to adjust it. Source lists also support
`repo:<url>` / `path:<dir>` prefixes. Relative paths are resolved from the
source list file's directory. For local multi-source runs, `--source-jobs N` /
`ZMK_EXTERNAL_SOURCE_JOBS=N` controls how many source processes may run at once;
the wrapper fills an open slot as soon as any source finishes. `--jobs N` still
controls target-level parallelism inside each source. For external full/pristine
builds, the GitHub workflow defaults `build_jobs` to 1, and scheduled runs use
the same fallback. Raise it manually only when the selected runners have enough
CPU/memory headroom.

```bash
bash ./scripts/auto-build-external.sh repos.txt --source-jobs 2 --jobs 2 --pristine
bash ./scripts/build-external-source.sh --repo https://github.com/example/zmk-config.git --jobs 2
bash ./scripts/build-external-source.sh --path ../your-zmk-config --source-slug your-zmk-config
```

In GitHub Actions, failures are isolated to the build job and the matching
artifact name. For local multi-source runs, the wrapper only starts one script
process per source, so `build.sh` keeps a single-build log stream. Scheduled
runs use GitHub Actions UTC cron syntax, with the JST conversion kept in the
workflow comments. The auto-build workflow has two jobs:

1. **sources** (on `ubuntu-latest`): Resolves `repos.txt` into a JSON matrix
   via `auto-build-external.sh --list-json` and passes it through
   `job outputs`.
2. **build** (matrix per source): Each source runs
   `build-external-source.sh` as an independent job on
   `runs-on: [self-hosted, zmk-docker, zmk-docker-active]`.

GitHub Actions label routing dispatches each build matrix job to any online
runner that carries both custom labels. Multiple idle runners can pick up
different sources in parallel. The OS is not pinned in the workflow; the
picked runner's OS is read from `runner.os` and is used to branch shell steps
(Git Bash on Windows, Bash on macOS / Linux) and to label the uploaded
artifact. Manual workflow runs expose `source_jobs`, which maps to
`strategy.max-parallel` and caps how many source matrix jobs run at once
(scheduled runs default to 4). Manual runs also expose `build_jobs`; it controls
target-level parallelism inside each source job and defaults to 1 for
full/pristine safety. If all matching runners are offline, jobs sit queued until
a runner comes online; `concurrency` with `cancel-in-progress: true` ensures
scheduled runs do not pile up on top of stale queued runs. To offload a specific
host, remove its `zmk-docker-active` label or stop the runner.

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
9. Builds each generated `build.yaml` target, optionally in parallel with one
   build directory per target.
10. Copies one firmware artifact per target back to `.build/`.
11. Writes `build.log` and `build-summary.txt`, including a failure excerpt when
   validation or firmware build fails.
