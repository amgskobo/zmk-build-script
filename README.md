# ZMK Build Script

[日本語版 README](README.ja.md)

Small Docker + Bash helper for building current-layout ZMK keyboard repositories.

Usage and runner setup are collected here; maintainer contracts are in [AGENTS.md](AGENTS.md).
The entry layout is:

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
new repos should use root `boards/` or an external module. New repositories should declare module roots in `zephyr/module.yml`.
Explicit `-m` modules require that metadata. Target repositories also support
the container-only normalization described below. When a
legacy target repo has root module content plus root `module.yml` but no
`zephyr/module.yml`, the container creates a transient `zephyr/module.yml` from
the current root layout. The source repo is not modified.

## Key Features

- Cross-platform host flow: Windows, macOS, and Linux use the same Docker + Bash
  script entrypoint.
- Host CPU independent: AMD64/x86_64 and ARM64 hosts run through Docker; the
  `zmk-build-arm` image name refers to the firmware toolchain, not the host CPU.
- Explicit module override: each `-m <dir>` can overlay a matching west project
  or be added as an extra ZMK module. `local_modules/` is ignored.
- Persistent west workspace: dependencies are reused between runs, while the
  target config is copied fresh each time.
- Safe overlay restore: explicit module-input west project overrides are backed up and restored
  on the next build. If copying a backup fails, the build stops and retains that
  project's backup and overlay record for recovery.
- Fast repeat builds: a persistent compiler cache (ccache) lives on the cache
  volume, and only the files Git shows are copied into the container, so large
  ignored directories do not slow the copy.
- Target parallel build: `--jobs N` / `ZMK_BUILD_JOBS=N` can build `build.yaml`
  targets in parallel. External full/pristine workflow runs default this to 1
  to avoid stacking target parallelism on top of Ninja's own compile
  parallelism.
- One artifact per target: `.uf2` is preferred, with `.bin` / `.hex` fallback
  support.
- CI coverage: representative ZMK 4.1 HWMv2 boards, target-shape parsing, and
  explicit module override paths are validated.

## Requirements

- Docker Desktop or Docker Engine
- Bash

On Windows, use Git Bash. PowerShell can launch Git Bash, but the script itself
must run under Bash. Use a normal Bash environment with standard Unix tools
available.

## Quick Start

Start Docker's Linux engine, then run in Bash on Windows, macOS, or Linux:

```bash
./build.sh validate ../your-zmk-config
./build.sh ../your-zmk-config
```

On Windows install Git for Windows and launch Git Bash explicitly from PowerShell:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' ./build.sh ../your-zmk-config
```

AMD64/x86_64 and ARM64 hosts use the same entry point; the image name refers to
the firmware toolchain. Set `ZMK_DOCKER_PLATFORM=linux/amd64` if Docker cannot
select a usable platform. Give concurrent repositories different cache volumes.

### Cache and Logs

The compiler cache (ccache) is kept on the same volume in `/workspaces/.ccache`
(`ZMK_CCACHE_DIR` changes the path), so eligible compiler results survive the
throw-away build container. The container sets `CCACHE_IGNOREOPTIONS=-specs=*`
so SDK specs-file lookup does not prevent cache hits. The SDK is part of the
selected Docker image; use a separate cache or `--pristine` when changing the
image or SDK. `--pristine` deletes both the west workspace and compiler cache.

Build output is also mirrored into the build container's own log stream. With
`ZMK_KEEP_CONTAINER=1`, you can inspect the same stream later with
`docker logs -f <container>` or Docker Desktop.

After creation, build and clone operations address the returned container ID,
including cleanup. Reusing a container name cannot redirect an in-progress run.

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

The target needs `build.yaml` with an `include:` list or a top-level matrix:

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
| `cmake-args` | Optional. Strings are parsed with `shlex.split`; list entries are literal arguments. Empty strings and quoted/list whitespace are preserved. |
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

Run directory names are part of the output contract and must follow
`run-YYYY-MM-DD_HH-MM-SS-pid-PID`; output checks sort valid run directories by
that name and fail if a `build-summary.txt` appears outside this convention.

## Options And Environment

```text
./build.sh <zmk-config-root> [--pristine] [--settings-reset] [--jobs N] [-S snippet] [-m module-dir]
./build.sh validate <zmk-config-root> [--settings-reset] [--jobs N] [-S snippet] [-m module-dir]
./build.sh clean
```

| Option | Meaning |
| --- | --- |
| `--pristine` | Build with `west build -p` and delete the whole Docker cache volume first. The compiler cache lives on that volume, so it is deleted too. |
| `--settings-reset` | Add a `settings_reset` target for each board that has none. |
| `--jobs N` | Build `build.yaml` targets N at a time (default 1). |
| `-S snippet` | Append a snippet to every target. |
| `-m module-dir` | Add a module (see Explicit Modules). Repeatable. |

| Environment variable | Meaning (default) |
| --- | --- |
| `ZMK_BUILD_IMAGE` | Full Docker image override. |
| `ZMK_BUILD_IMAGE_REPOSITORY` | Image repository (`zmkfirmware/zmk-build-arm`). |
| `ZMK_BUILD_IMAGE_TAG` | Image tag (`auto`, see Docker Image). |
| `ZMK_DOCKER_PLATFORM` | Docker `--platform` value. |
| `ZMK_DOCKER_CACHE_VOLUME` | Volume mounted at `/workspaces` (`zmk-cache`). |
| `ZMK_CCACHE_DIR` | ccache directory in the container (`/workspaces/.ccache`). |
| `ZMK_COPY_IGNORED` | `1` copies files that Git ignores too. |
| `ZMK_BUILD_JOBS` | Same as `--jobs` (1). |
| `ZMK_WEST_UPDATE_ATTEMPTS` | `west update` attempts (3). |
| `ZMK_FALLBACK_BINARY` | Firmware extension to try after `.uf2` (`bin`). |
| `ZMK_EXTRA_MODULES` | Extra module paths appended to the container's `ZMK_EXTRA_MODULES`. |
| `ZMK_KEEP_CONTAINER` | `1` keeps the build container after the run. |
| `ZMK_CONTAINER_NAME` | Container name. |

The persistent west workspace is pruned on every run: top-level entries that the
manifest does not list are removed. Give each tool or repository that uses the
same Docker image its own `ZMK_DOCKER_CACHE_VOLUME`.

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
`Overlaying module input west project` and `Adding module input as extra module` paths, and
builds a studio-enabled `.bin` target plus a settings-reset `.hex` target, so
multiple `-m` inputs, non-UF2 outputs and nested
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

## Explicit Modules

```bash
./build.sh ../your-zmk-config -m ../local-module
```

Modules passed with `-m` are copied into Docker. If the directory name matches a
west project name, that project is overlaid after `west update`. Otherwise it is
passed to ZMK through `ZMK_EXTRA_MODULES`. Pass every module explicitly with
`-m`; this tool does not load `local_modules/`.

Directory paths such as `module/.` are normalized before naming. Names are
compared in full, including spaces; only identical directory names are rejected
as duplicates.

Generated west project directories are filtered per copy source, so cached
dependencies are skipped without dropping intentional module content.

When a target or `-m` directory is a Git working tree and `git` is available,
only the files Git shows are copied: tracked files and untracked files that
`.gitignore` does not match. Ignored bulk such as `artifacts/` or
`web/node_modules/` stays on the host. Anything else is copied whole. Set
`ZMK_COPY_IGNORED=1` to copy ignored files too.

If a previous local overlay left files in the persistent west workspace, the
matching project directory is cleared before `west update` so the next checkout
does not conflict with stale local files.

## Clean

```bash
./build.sh clean
```

Removes generated `.build` runs while keeping `.build/.gitkeep`.

## Self-hosted Runners

Hosted `Compatibility` is the normal compatibility gate. The manual
`Self-hosted Build` workflow runs the standard fixture on your own machine;
it adds machine-specific Docker smoke evidence. Use `platform: macos`,
`windows`, `linux`, or `all`, and `mode: validate` or `build`. Start with validate
on one online runner, then build. Use `all` after every selected OS is available.

Register through repository Settings → Actions → Runners → New self-hosted
runner, using the current package, token and command shown by GitHub. Keep the
default OS labels and add the custom labels after Docker works for that user:

| Host | Labels |
| --- | --- |
| macOS | `self-hosted`, `macOS`, `zmk-docker`, `zmk-docker-active` |
| Windows | `self-hosted`, `Windows`, `zmk-docker`, `zmk-docker-active` |
| Linux | `self-hosted`, `Linux`, `zmk-docker`, `zmk-docker-active` |

Run `bash .github/scripts/check-runner-tools.sh` and the common Maintenance
checks as the runner user. Windows uses Git Bash at its standard installation
path. With Docker Desktop, verify the same login/session before installing a
runner service. Linux needs daemon access without sudo; after adding the runner
user to the docker group, log in again or restart the runner service.

Keep self-hosted execution limited to trusted workflows. Remove
`zmk-docker-active` or stop the runner to take a host out of external auto builds.
A queued job needs an online, eligible, idle runner; check its account,
repository/organization assignment and labels. If Docker works in Terminal but
fails in Actions, compare the account and session. If tar excludes are missing,
check the runner's normal Bash tools and PATH. A successful run must have matching
mode, log, summary and exactly one firmware per target before upload.

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
`ZMK_EXTERNAL_CLONE_ATTEMPTS=N` to adjust it. If the host clone destination cannot
be cleared, the wrapper stops before cloning or copying so stale files cannot be
merged into the new source. Source lists also support
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

1. Copies the target repo into `/root/zmk-config` in Docker. In a Git working
   tree only the files Git shows are copied (see Explicit Modules).
2. Skips top-level local/generated directories such as `.cache`, `.ccache`, `.vscode`,
   `build`, `dist`, `node_modules`, `out`, `tmp`, and `zmk_search`.
3. Normalizes legacy root `module.yml` to a transient `zephyr/module.yml` when
   root module content needs to be exposed to Zephyr.
4. Copies only `config/` into the persistent west workspace.
5. Builds with `ZMK_CONFIG=/root/zmk-config/config` so ZMK can see both
   `config/boards` and root `boards`.
6. If `zephyr/module.yml` exists, passes `/root/zmk-config` through
   `ZMK_EXTRA_MODULES`.
7. Restores previous overlays before deciding whether the workspace needs `west update`.
   Prunes obsolete workspace roots only after obtaining a complete west project
   list. An unavailable or partial list preserves the cache and requires an update;
   a failed update cannot continue without a complete project list.
   Cache validation uses west's resolved manifest, including imported dependency
   definitions. Changes to those definitions trigger an update; an unresolved
   manifest cannot mark the cache ready. Only a complete update verifies the cache.
   Failed/interrupted updates are retried on the next build even if partial checkout
   directories exist. Older cache markers trigger a fresh verification once.
   Continuation with local overrides requires every failed project from the final
   attempt to be identified and supplied locally.
8. Applies the current explicit module overrides after dependency resolution,
   recording recovery before copying so interrupted overlays can be restored.
9. Builds each generated `build.yaml` target, optionally in parallel with one
   build directory per target, using the compiler cache on the cache volume.
10. Copies one firmware artifact per target back to `.build/`.
11. Writes `build.log` and `build-summary.txt`, including a failure excerpt when
   validation or firmware build fails.

## Maintenance

`build.sh` owns one configuration and its copy/workspace/output flow.
`scripts/auto-build-external.sh` owns source lists, JSON matrices, unique slugs
and the bounded queue; `scripts/build-external-source.sh` clones or selects one
source and invokes the builder. Fixtures and behavior checks stay in `.github/`.
Read [AGENTS.md](AGENTS.md) before changing these contracts.

External wrappers also accept `--mode build|validate`, `--pristine`,
`--settings-reset`, and repeated `-S` / `-m`. Their defaults are:

| Environment | Default |
| --- | --- |
| `ZMK_EXTERNAL_MODE` | `build` |
| `ZMK_EXTERNAL_PRISTINE` | `0` |
| `ZMK_EXTERNAL_SETTINGS_RESET` | `0` |
| `ZMK_EXTERNAL_SOURCE_JOBS` | `1` |
| `ZMK_EXTERNAL_CACHE_PREFIX` | `zmk-cache-external` |
| `ZMK_EXTERNAL_CLONE_IMAGE` | `zmkfirmware/zmk-build-arm:stable` |
| `ZMK_EXTERNAL_CLONE_ATTEMPTS` | `3` |
| `ZMK_EXTERNAL_SOURCE_BUILDER` | `scripts/build-external-source.sh` |

Run the same entry point locally and in CI:

```bash
bash .github/scripts/test.sh shell
bash .github/scripts/test.sh docker
bash .github/scripts/test.sh build
# Or all three, in order:
bash .github/scripts/test.sh all
```

| Layer | Contracts |
| --- | --- |
| `shell` | Bash syntax, LF and Git checkout behavior, whitespace, output validation, source lists/queue/failures, host guards and help |
| `docker` | Actual host copy, Git ignore and opt-outs, generated dependencies, metadata normalization, exact parser traces and invalid schema, controlled overlay/update failure and recovery, retries and stale locks, path guards, ccache hits, Windows clone pruning and copy back |
| `build` | Standard firmware targets, explicit project overlays plus an extra module, restoration without pristine, exact output count and dependency identities |

Each invocation creates `.build/test-<UTC>-pid-<PID>/` with commands, ordered raw
logs, per-case status/timing and source checksums before/after. Existing evidence
is never overwritten. `ZMK_TEST_RESULTS` can select a new directory outside the
repository or inside a Git-ignored directory; visible in-tree evidence is rejected
before testing because it would be included in source checksums.
`ZMK_DOCKER_CACHE_VOLUME` can select a dedicated reusable test cache. The default
is a fresh cache name, removed after the run; an explicitly supplied cache is retained. `ZMK_TEST_PRISTINE=1` resets that test cache before the
standard build; restoration always keeps it. Never point tests at a shared
production cache. Docker tests use the image's Python/PyYAML, with no extra host
installation. Build checks pass the exact output directory to the checker;
concurrent runs cannot change which result is checked.

The shell layer needs Git; the production builder still treats Git as optional.
Use `.gitattributes` and `.editorconfig` for UTF-8/LF. The checker rejects CR in
tracked and visible untracked text, reads Windows bytes without text conversion,
and leaves ignored outputs and binary files untouched. CI checks the checkout
without resetting a user's worktree.

Counts are positive decimal integers; all-zero forms such as `00` are rejected.
Killed source workers count as failures and release their queue slots so other
sources continue. Started runs keep failure summaries even for host setup errors.
Only containers created by that run are cleaned up.

Output checking requires a positive target count and exactly one firmware per
target. The selected fallback is recorded in the summary (older summaries use
`bin`). Extensions omit the leading dot and permit letters, digits, dots,
underscores and hyphens; paths, globs and leading dot/hyphen are rejected.
Workflow uploads cover `.uf2`, `.hex`, `.bin`; add a pattern for other formats.
Explicit module roots require `build.cmake`, `build.kconfig`, and the applicable
`build.settings.*_root` declarations for root content. Module metadata is parsed
as YAML inside Docker, including inline maps, before changing the persistent
workspace or updating dependencies. Windows reserved artifact names
are rejected even when followed by an extension.

Local checks and remote workflows are separate results; changes remain local
until publication is explicitly requested.
