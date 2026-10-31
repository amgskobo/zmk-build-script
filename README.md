# ZMK Build Script

[日本語版 README](README.ja.md)

Docker + Bash builder for ZMK configuration repositories and explicitly selected
standalone Zephyr applications. It builds one repository, reuses dependencies and
compiler results, and saves firmware and logs on the host. Maintainer contracts
are in [AGENTS.md](AGENTS.md).

- [Requirements and quick start](#requirements-and-quick-start)
- [Docker image](#docker-image)
- [Commands and options](#commands-and-options)
- [Parallel builds](#parallel-builds)
- [Build configuration](#build-configuration)
- [Modules, snippets and source copy](#modules-snippets-and-source-copy)
- [External sources](#external-sources)
- [Cache, cleanup and output](#cache-cleanup-and-output)
- [Workflows and self-hosted runners](#workflows-and-self-hosted-runners)
- [Maintenance](#maintenance)

## Requirements and quick start

Use Docker Desktop or Docker Engine with its Linux engine, and Bash with standard
Unix tools. Git is optional for the production builder. On Windows, use Git Bash;
PowerShell can launch it explicitly:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' ./build.sh ../your-zmk-config
```

Run these commands from this tool's repository root, using Bash on Windows,
macOS or Linux:

```bash
./build.sh validate ../your-zmk-config
./build.sh ../your-zmk-config
```

### Source layout

The entry point is the repository root containing `build.yaml` and
`config/west.yml`; direct config directories and custom config paths are not
supported. The supported layout is:

```text
your-zmk-config/
+-- build.yaml
+-- config/
|   +-- west.yml
|   +-- <keyboard>.conf
|   +-- <keyboard>.keymap
|   +-- boards/...        # existing compatibility path
+-- zephyr/module.yml     # module metadata
+-- boards/...            # standard board and shield definitions
+-- dts/...               # optional module content
+-- snippets/<name>/...   # optional module content
```

Use root `boards/` or external modules for new repositories. Target metadata
missing from legacy layouts is normalized inside the container; host sources
are preserved. Explicit `-m` modules require the declarations under
[Module metadata](#module-metadata).

## Docker image

`ZMK_BUILD_IMAGE` overrides the whole image. Otherwise the repository and tag
variables select it. With tag `auto`, `config/west.yml`'s ZMK revision maps to:

| ZMK revision | Image tag |
| --- | --- |
| `main`, `master`, missing or unrecognized | `stable` |
| `v0.3` / `0.3` series, including patch and suffix revisions | `3.5-branch` |
| `v4.1` / `4.1` series, including patch and suffix revisions | `4.1-branch` |

Image selection determines the firmware toolchain. Host platform support depends
on the selected image and Docker; set
`ZMK_DOCKER_PLATFORM=linux/amd64` when needed. Local checks do not establish native
ARM64 host compatibility or old-image firmware compatibility.

## Commands and options

```text
./build.sh <zmk-config-root> [--pristine] [--settings-reset] [--jobs N] [-S snippet] [-m module-dir]
./build.sh validate <zmk-config-root> [--pristine] [--settings-reset] [--jobs N] [-S snippet] [-m module-dir]
./build.sh clean
```

`validate` checks layout, module metadata and `build.yaml` inside the selected
image and prints the target list without compiling firmware. Both modes save
`build.log` and `build-summary.txt` in a new run directory.

### CLI options

| Option | Meaning |
| --- | --- |
| `--pristine` | Delete the selected Docker cache volume before build or validation. Firmware builds also use `west build -p`. |
| `--settings-reset` | Add a `settings_reset` target for each board that has none. |
| `-j N`, `--jobs N` | Build targets N at a time (default 1). |
| `-S NAME`, `--snippet NAME` | Append a snippet to every target; repeatable. |
| `-m DIR`, `--module DIR` | Copy an explicit module; repeatable. |
| `-h`, `--help`, `help` | Show usage. |

Parallelism and retry counts must be positive decimal integers; all-zero forms
such as `00` are rejected. See [Parallel builds](#parallel-builds) for concurrency.

### Environment variables

| Environment variable | Meaning (default) |
| --- | --- |
| `ZMK_BUILD_IMAGE` | Full Docker image override. |
| `ZMK_BUILD_IMAGE_REPOSITORY` | Image repository (`zmkfirmware/zmk-build-arm`). |
| `ZMK_BUILD_IMAGE_TAG` | Image tag (`auto`; see [Docker image](#docker-image)). |
| `ZMK_DOCKER_PLATFORM` | Optional Docker `--platform` value. |
| `ZMK_DOCKER_CACHE_VOLUME` | Volume mounted at `/workspaces` (`zmk-cache`). Use a separate volume per repository/tool. |
| `ZMK_CCACHE_DIR` | ccache directory inside the container (`/workspaces/.ccache`). Keep it on the cache volume for persistence. |
| `ZMK_COPY_IGNORED` | `1` also copies files ignored by Git. |
| `ZMK_BUILD_JOBS` | Default for `--jobs` (1). |
| `ZMK_WEST_UPDATE_ATTEMPTS` | `west update` attempts (3). |
| `ZMK_FALLBACK_BINARY` | Firmware extension tried after `.uf2` (`bin`). |
| `ZMK_EXTRA_MODULES` | Container-visible module paths appended to the selected application's extra modules. |
| `ZMK_KEEP_CONTAINER` | `1` retains the build container after the run. |
| `ZMK_CONTAINER_NAME` | Optional build container name. |

## Parallel builds

Source processes, build targets and Ninja compilation have separate concurrency:

| Unit | Control | Default |
| --- | --- | --- |
| Sources in one local wrapper invocation | `--source-jobs N` / `ZMK_EXTERNAL_SOURCE_JOBS` | 1 source |
| Targets in each source | `--jobs N` / `ZMK_BUILD_JOBS` | 1 target |
| Compilation within a target | Ninja and the selected build environment | Build-environment default |

### Targets in one source

Build up to two entries from one `build.yaml` at once:

```bash
bash build.sh ../your-zmk-config --jobs 2
```

Each target has its own build directory and log. Logs are collected in target
order. A failed batch stops subsequent pending targets.

### Multiple sources

Use the [external-source wrapper](#external-sources) to build up to two sources
at once, with one target per source:

```bash
bash scripts/auto-build-external.sh --sources-file repos.txt --source-jobs 2 --jobs 1
```

The wrapper assigns unique slugs and separates each source's clone, cache,
container and artifacts. Its rolling queue starts the next source when a slot
opens; a source failure does not stop the other sources. Keep separate wrapper
invocations from sharing clone slugs/directories.

### Independent invocations and shared caches

Use separate cache volumes when starting independent builds in different terminals:

```bash
# Terminal 1
ZMK_DOCKER_CACHE_VOLUME=zmk-cache-a bash build.sh ../config-a

# Terminal 2
ZMK_DOCKER_CACHE_VOLUME=zmk-cache-b bash build.sh ../config-b
```

Both commands would otherwise use the default `zmk-cache` volume. An OS lock
protects dependency updates, overlays and intermediate-file cleanup on that
workspace. A competing build fails before workspace changes; it does not wait
in a queue. The lock releases when the build process exits, even if its container
is retained. Container names are unique by default; explicitly supplied
`ZMK_CONTAINER_NAME` values must differ between simultaneous runs.

### CPU and memory

`--source-jobs 2 --jobs 2` allows up to four target builds at once, each with its
own Ninja compilation parallelism. These options do not set a shared CPU or
memory limit across containers. The example above uses `--source-jobs 2 --jobs 1`.
For cold caches or limited memory, keep `--jobs 1` and reduce `--source-jobs` as
needed. CI matrix limits are described under
[Workflows and self-hosted runners](#workflows-and-self-hosted-runners).

## Build configuration

### Target matrix

`build.yaml` accepts an `include:` list or a top-level board/shield matrix:

```yaml
include:
  - board: nice_nano/nrf52840/zmk
    shield: corne_left nice_view_adapter
    snippet: studio-rpc-usb-uart
    artifact-name: example_corne_left
```

| Per-target key | Meaning |
| --- | --- |
| `board` | Required board passed to `west build -b`. |
| `shield` | Optional `-DSHIELD=...`. |
| `snippet` | Optional `west build -S` argument. |
| `cmake-args` | String parsed with `shlex.split`, or a list of literal arguments. Empty arguments and quoted/list whitespace are preserved. |
| `extra-cmake-args` | Arguments appended after `cmake-args`. |
| `artifact-name` | Output base name; supports `{board}`, `{shield}` and `{snippet}`. |
| `skip` | Skip an `include:` entry when true. |

Top-level and `include:` board/shield arrays expand as matrices. `defaults:`
supplies missing values; `exclude:` matches YAML values before CLI snippets are
appended. Alias spellings `cmake_args`, `extra_cmake_args` and `artifact_name` are
also accepted. Artifact names are normalized to safe filenames; Windows device
names, including names with extensions, and case-insensitive duplicates are
rejected.

### Standalone applications

For a standalone Zephyr application, add top-level `application: app`. The
relative directory must contain `CMakeLists.txt` and stay inside the repository,
including symlinks. The manifest must provide a project named `zephyr`. The
builder resolves that workspace's Zephyr package and passes extra modules with
`ZEPHYR_EXTRA_MODULES`. Without `application`, it builds `zmk/app` with ZMK's
configuration and `ZMK_EXTRA_MODULES` arguments. Select an image with the required
Zephyr dependencies and a dedicated cache volume for each application.
Target board, DTS and snippet roots are normalized in this mode too. The builder
preserves explicit module build declarations and does not infer them from the
standalone application's CMake or Kconfig entry points.

## Modules, snippets and source copy

```bash
./build.sh ../your-zmk-config -m ../local-module -S local-snippet
```

Each `-m` directory is copied into the container. Its resolved basename, including
spaces, must be unique. If the name matches a west project, the local copy
overlays that project after dependency resolution. Otherwise it becomes an extra
module. Pass every local module explicitly; `local_modules/` is not discovered.

### Module metadata

Declare root content in `zephyr/module.yml`. Include only the declarations needed
by that module:

```yaml
build:
  cmake: .                 # root CMakeLists.txt
  kconfig: Kconfig         # root Kconfig
  settings:
    board_root: .          # root boards/
    dts_root: .            # root dts/
    snippet_root: .        # root snippets/
```

Module metadata is checked as YAML, including inline maps and quoted keys, before
changing the persistent workspace. Declared `build.cmake` and `build.kconfig`
paths must be strings. Validation also covers modules whose build files are
entirely below `zephyr/`.
Hidden directory names supplied with `-m` are included in the same validated
input list; module paths are passed internally with NUL delimiters.

### Source copy

Git working trees copy tracked files plus non-ignored untracked files. Deleted
tracked files are omitted; ignored tracked files remain included. With
`ZMK_COPY_IGNORED=1`, unavailable Git, failed or empty file listing, or a
non-working-tree source, copying falls back to the full source with fixed exclusions.

Copying always excludes `.git`, `.west` and `__pycache__`, plus top-level `.zmk`,
`.build`, `.cache`, `.ccache`, `.vscode`, `build`, `dist`, `node_modules`, `out`,
`tmp` and `zmk_search`. Matching nested directory names are retained. Dependency
trees are excluded only when the source has `.west` and the tree has a `.git`
marker; names such as `modules` or `tools` alone do not exclude source content.

## External sources

### Source lists and commands

[repos.txt](repos.txt) contains one URL or local path per line. Optional prefixes
are `repo:` / `url:` and `path:`. List-relative paths resolve from the list file's
directory. `build.sh` handles one repository; the wrappers own source selection,
unique slugs and [source parallelism](#parallel-builds).

```bash
bash scripts/auto-build-external.sh --list repos.txt
bash scripts/auto-build-external.sh --list-json repos.txt
bash scripts/build-external-source.sh --repo https://github.com/example/zmk-config.git
bash scripts/build-external-source.sh --path ../your-zmk-config --source-slug example
```

### Wrapper options

| Wrapper option | Meaning |
| --- | --- |
| `--repo URL`, `--path DIR` | Select an explicit source type. |
| `--source-slug NAME`, `--repo-slug NAME` | Set a source's slug; in the multi-source wrapper, place it after `--repo` / `--path`. |
| `--mode build\|validate` | Select build or validation. |
| `--pristine`, `--settings-reset`, `-j` / `--jobs`, `-S` / `--snippet`, `-m` / `--module` | Forward builder options, including pristine validation. |
| `--source-jobs N` | Bound local source parallelism in `auto-build-external.sh`. Each worker still has its own target parallelism. |
| `--sources-file FILE`, `--repos-file FILE` | Select a source list in `auto-build-external.sh`. |
| `--list`, `--list-json` / `--matrix-json` | Print resolved sources or the JSON matrix without building. |
| `--list-indices-json` | Print only numeric source indices for a public CI matrix. |
| `--source-index N` | Select one source from the fully resolved list, preserving its unique slug and original JSON index; indices start at 1. |

### Wrapper environment variables

| Wrapper environment | Default / purpose |
| --- | --- |
| `ZMK_EXTERNAL_MODE` | `build` |
| `ZMK_EXTERNAL_PRISTINE` | `0` |
| `ZMK_EXTERNAL_SETTINGS_RESET` | `0` |
| `ZMK_EXTERNAL_SOURCE_JOBS` | `1` |
| `ZMK_EXTERNAL_CACHE_PREFIX` | `zmk-cache-external`; each source adds its unique slug. |
| `ZMK_EXTERNAL_CLONE_IMAGE` | `zmkfirmware/zmk-build-arm:stable` |
| `ZMK_EXTERNAL_CLONE_ATTEMPTS` | `3` |
| `ZMK_EXTERNAL_SOURCE_BUILDER` | `scripts/build-external-source.sh`; worker used by the multi-source wrapper. |

### Clone and cleanup behavior

URL cloning runs in Docker and returns files with `docker cp`, requiring no host
Git installation or bind mount. Windows-incompatible filenames are removed with
warnings only for Windows hosts. Clone cleanup is limited to a child of the
resolved clone root; removal failures stop the source job. Each source has its
own clone directory, cache, container and artifacts. Workers that fail or exit
before recording status count as failures; other sources continue and fill free
slots immediately.

## Cache, cleanup and output

### Workspace and dependency cache

Use a dedicated volume per source and application; see
[Independent invocations and shared caches](#independent-invocations-and-shared-caches).

The container keeps a west workspace and copies only `config/` into it. ZMK uses
`ZMK_CONFIG=/root/zmk-config/config` from the fresh container source. Dependency
reuse checks the resolved manifest, including imports. Failed or interrupted
updates are retried; unresolved manifests cannot mark a cache ready. Obsolete
workspace roots are pruned only after restoring overlays and obtaining a
complete project list. A failed restoration stops the build and keeps the
affected backup and recovery record.
Overlay recovery records each completed project before deleting its backup.
A later project's failure can therefore be retried without deleting earlier
restorations. Existing two-column recovery records remain supported.

ccache lives outside the west workspace on the cache volume. Its
`CCACHE_IGNOREOPTIONS=-specs=*` setting assumes SDK specs are fixed in the selected
image. Use a separate cache or `--pristine` after changing the image or SDK.

### Retention and cleanup

| Data | Lifetime and cleanup |
| --- | --- |
| Per-target build directories | Removed on success, compile failure, or firmware selection/copy failure, including with `ZMK_KEEP_CONTAINER=1`. |
| Build and clone containers | Removed after use; `ZMK_KEEP_CONTAINER=1` retains only the build container. Operations use the immutable ID returned by Docker. |
| Dependencies and ccache | Reused on the dedicated volume. `--pristine` deletes the entire selected volume, including ccache. |
| Host-side URL clone copies | Removed before source success is reported; local-path sources are retained. |
| Host firmware, logs and test evidence | Kept under this tool's `.build/`. `./build.sh clean` removes everything there except `.gitkeep`. |

Cleanup failures fail the affected target, run or source job. In `build.sh`, earlier
build errors retain their reason and exit status. External wrappers report source
failure with a nonzero status and record cleanup errors alongside clone/build failures.
`--pristine` stops before container creation if listing or removing the selected
volume fails. It can also reset a cache during validation.
File cleanup does not force WSL's memory cache back to Windows; WSL memory
reclamation belongs to the host operating system.

### Interruption handling

During execution, SIGINT and SIGTERM finalize a FAILED run with the interruption
reason. A retained container is stopped on interruption; its identity and logs
remain available.
During container creation (including an automatic image pull), cancellation is
deferred until the returned ID has been acquired, including process-group
interruptions. Repeated cancellation does not abandon an unidentified container.
Finalization defers signals from handler entry through cleanup. Earlier build
errors retain their reason and exit status; otherwise interruption produces a
FAILED summary.
The final summary is published atomically after cleanup. Its outcome is then
committed, so late signals during summary publication do not change the exit status.
Require both a zero command exit status and a successful output check.

### Firmware and output checks

Each target returns one firmware file, selected in order: `.uf2`,
`ZMK_FALLBACK_BINARY`, `.hex`, `.bin`. Fallback extensions omit the leading dot;
letters, digits, dots, underscores and hyphens are allowed, with no path, glob,
or leading dot/hyphen. CI uploads the publication reports described below;
firmware and raw logs remain in local `.build/` storage.

```text
.build/run-YYYY-MM-DD_HH-MM-SS-pid-PID/
+-- example_corne_left.uf2
+-- build.log
+-- build-summary.txt
```

Started runs retain a failure summary and error excerpt even when setup, source
copy, artifact recovery or container cleanup fails. Build output also goes to the
container log stream; inspect a retained container with `docker logs <container>`.
Check a specific run with:

```bash
bash .github/scripts/check-build-output.sh build .build/run-YYYY-MM-DD_HH-MM-SS-pid-PID
```

Use `validate` instead of `build` for validation output. Both modes require a
successful summary with the matching mode and a log file. Build checks also
require a positive target count and exactly one firmware per build target.
Relative run paths resolve from the caller's directory. Without a run path, the
checker searches that directory's `.build/`. Pass the run path when checking from
elsewhere.
Run names must follow the displayed convention. The summary records the selected
fallback; older summaries default to `bin`.

## Workflows and self-hosted runners

| Workflow | Purpose |
| --- | --- |
| [Compatibility](.github/workflows/compatibility.yml) | Hosted shell checks on Windows/macOS/Linux; Docker and firmware checks on Ubuntu. |
| [Self-hosted Build](.github/workflows/self-hosted-build.yml) | Manual `platform: macos\|windows\|linux\|all`, `mode: validate\|build`. Validate runs shell and Docker contracts; build also compiles fixtures. |
| [Auto Build External ZMK Repos](.github/workflows/auto-build.yml) | Resolve the list on Ubuntu, then route each source to an eligible self-hosted runner. |
| [Heartbeat](.github/workflows/heartbeat.yml) | Update the tracked heartbeat record; this workflow commits and pushes. |

### Runner setup

Register runners through repository Settings → Actions → Runners with GitHub's
current package and registration command. Keep default `self-hosted` and OS
labels (`macOS`, `Windows`, `Linux`), and add `zmk-docker` and `zmk-docker-active`
after confirming Docker access as the runner user.

Run `bash .github/scripts/check-runner-tools.sh` and the maintenance checks as
that user. Windows steps explicitly use Git Bash at its standard installation
path. Docker Desktop must be accessible in the same account/session. Linux needs
Docker daemon access without sudo; refresh the login/service after group changes.
Limit self-hosted execution to trusted workflows.

### Scheduling and parallelism

External matrix jobs use `runner.os` for Bash/Git Bash selection and artifact
names. `source_jobs` caps matrix parallelism (default 4); `build_jobs` controls
target parallelism (default 1). Scheduled runs use these defaults and pristine
builds. Cron schedules are UTC, with JST comments in each workflow; concurrency
and timeouts limit overlap. With no eligible online runner, jobs remain queued.
Check online/busy state, labels and registration scope. Remove
`zmk-docker-active` or stop a runner to exclude it from external jobs.

### Public reports and CI helpers

CI publishes only fixed-field text reports under `.build/public/`. These contain
the command outcome and recognized test statuses. Raw environment records,
paths, source labels, runner names, logs and firmware are excluded from automatic
uploads. External jobs use a numeric source index in their public names.
These reports are sanitized copies, separate from the raw evidence. On hosted
runners, raw evidence is temporary and is lost when the job is removed; detailed
diagnosis requires a local reproduction or separately reviewed private retrieval.

CI uses `bash .github/scripts/check-build-output.sh ci-tests <mode>` to run the
[canonical test entry point](#maintenance), retaining detailed output in `.build/`
logs, using a fresh `.build/ci-execution.XXXXXX/` for each command. `ci-tools`,
`ci-lf`, `ci-syntax`, `ci-source <wrapper arguments>` and `ci-check build|validate`
provide the same boundary for external builds. `publish clear` initializes the
known report files before a job, and `publish verify` checks the final payload
before upload. Both steps must succeed for the upload to run.

Every test invocation also writes its report;
`publish tests-shell|tests-docker|tests-build|tests-all EXIT RAW_DIRECTORY` can
regenerate a test report, and `publish build|validate EXIT` records an external
command outcome. Only exit statuses and recognized case names/statuses are copied.

External CI uses `ci-matrix` and `ci-source-index N` with a private
`.build/ci-source-file` selector prepared from the workflow event at runtime.
The selector always names a list file; missing lists fail during matrix resolution.
CI helpers operate from this repository's root regardless of the caller's directory.
Only numeric indices enter the matrix and step environment; source paths, URLs
and slugs stay out of runner-generated step details as well as command output.
The selector preparation uses the Node runtime bundled with `actions/github-script`;
it adds no host requirement to the local CLI.

## Maintenance

Read [AGENTS.md](AGENTS.md) before changing behavior. Local and CI checks share
one entry point:

```bash
bash .github/scripts/test.sh shell
bash .github/scripts/test.sh docker
bash .github/scripts/test.sh build
bash .github/scripts/test.sh all
```

### Test layers

| Layer | Scope |
| --- | --- |
| `shell` | Bash syntax, LF/checkout, whitespace, output checks, source queue/failures, host guards and help. Git is required for this test layer. |
| `docker` | Actual source copy, metadata, production parser, controlled workspace/update/overlay failures, cleanup, ccache hits, Windows clone copy-back and external workflow argument forwarding. Uses the image's Python/PyYAML. |
| `build` | [Standard firmware](.github/fixtures/ci-zmk-config/build.yaml), [project overlays](.github/fixtures/module-override-zmk-config/build.yaml), extra modules, restoration without pristine and a standalone application with root snippets; exact outputs and dependency identities. |
| `all` | Run the `shell`, `docker` and `build` layers in that order. |

The validate-only [target-shape fixture](.github/fixtures/target-shapes-zmk-config/build.yaml)
covers matrices, defaults, exclusions, aliases, placeholders and reset de-duplication.
The fixtures exercise representative boards and outputs, not every upstream board.

### Evidence and test caches

Each invocation records commands, raw logs, status/timing, image identity and
source checksums before/after in a fresh `.build/test-<UTC>-pid-<PID>/`.
`ZMK_TEST_RESULTS` can select another new directory outside the repository or
fully ignored by Git. Existing evidence is never overwritten. Use UTF-8/LF via
`.gitattributes` and `.editorconfig`; checks preserve the working tree.

Tests create and remove a dedicated cache by default. An explicitly supplied
`ZMK_DOCKER_CACHE_VOLUME` is reused and retained; never use a production cache.
`ZMK_TEST_PRISTINE=1` resets that test cache before the standard build, while
restoration always retains it. Each build/validate result is checked immediately
using its exact run directory. Report local, remote CI, host-platform and physical
hardware evidence separately. Publication requires an explicit user instruction.
