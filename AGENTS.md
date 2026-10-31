# Agent contract

This is the default, authoritative English contract. [AGENTS.ja.md](AGENTS.ja.md)
is its Japanese translation. Keep both versions synchronized; if they differ,
follow this file and correct the translation.
Usage, CLI options, environment variables and runner operations belong in
[README.md](README.md) and [README.ja.md](README.ja.md); maintenance rules belong here.
Do not add external project repository names, commit hashes, dates, individual
measurements or one-off results to documentation. Record commands, source and
image identities, and raw logs in a new execution record under `.build/`.

## Publication privacy and local execution

This rule applies to information prepared for publication or external sharing.
During an authorized task, agents may inspect and use actual local paths,
configuration, host/terminal/device identities and private test evidence as
needed for implementation, diagnosis, identity matching and validation. Such
local access does not itself authorize collection outside the task or disclosure.

Before preparing a public commit, push, PR, release, documentation/site output
or CI artifact, review the actual publication payload, including source,
comments, AGENTS files, examples, test fixtures, logs, screenshots, generated
files and metadata. Exclude user-related names and preferences, private absolute
paths and local-environment details, workstation/terminal identities, individual
device labels, ports, serials, addresses, pairing/bond identities, credentials,
and user- or device-specific test/measurement histories. Also check generated
and uploaded artifacts; checking source prose alone is insufficient.

Use repository-relative paths, documented variables/placeholders, neutral names
and clearly synthetic fixtures in public material. Declared public project
identifiers, existing attribution, standard API/product/platform names and
reproducible support requirements remain technical project information; do not
present one user's actual environment as a project requirement. In particular,
documenting supported platforms is distinct from identifying a user's device.

Keep exact originals and identifiers in appropriate private/local task records
when required for accurate evidence or device matching. Produce a separate
sanitized publication copy without weakening assertions or inventing results;
do not describe it as the unchanged raw record. If useful evidence cannot be
shared without exposing these details, keep it private and state the public
validation limit. Recheck the final publication snapshot and its artifacts.
Existing authorization requirements for version-control, publication, device
writes, resets and data erasure still apply.

## Scope and responsibilities

### Task boundaries

- Read the latest user instructions and existing diff first; preserve user changes.
- Stage, commit, push, create/update a PR, merge, tag or release only with explicit
  instructions for that operation. Passing tests or reaching a milestone is not
  authorization. Do not include unrelated changes.
- The primary scope is `build.sh`. Change helpers, workflows and documentation only
  where directly related to its contract. Do not modify keyboard/module sources,
  firmware on physical devices or settings.
- Put features that always apply to an individual build in `build.sh`. Add environment
  variables only when an opt-out is needed. Before adding scripts, containers or
  fixtures, check whether existing responsibilities and scenarios can accommodate them.
- Production hosts require Docker and Bash. Use standard Unix tools without assuming
  additional installations. Git is optional.
- Do not make the builder reclaim memory, stop or reconfigure WSL as a whole, or monitor
  other tools. Distinguish intermediate-file deletion, dependency/ccache reuse, and
  artifacts/evidence retained on the host.

### File responsibilities

| Location | Responsibility |
| --- | --- |
| `build.sh` | Build/validate/clean one target directory, host copy, container workspace, artifact collection |
| `scripts/auto-build-external.sh` | Source list/JSON matrix, unique slugs, rolling queue of source processes |
| `scripts/build-external-source.sh` | Clone/resolve a local path for one source, invoke the builder, clean up the clone |
| `scripts/source-common.sh` | Shared wrapper classification/naming, removal of Windows-incompatible clone paths |
| `repos.txt` | One source per line; resolve relative paths against the list file's directory |
| `.github/fixtures/` | Standard firmware, validation-only target shapes, module overrides |
| `.github/scripts/` | Shared validation entry point, runner/LF/output checks, existing helper behavior tests |
| `.github/workflows/` | Hosted compatibility, manual self-hosted smoke, external source matrix, heartbeat |

Do not move source enumeration or cloning back into `build.sh`. Keep source,
target and Ninja compilation parallelism separate. Treat host → container →
persistent workspace as two copy boundaries, separate from artifact collection
back to the host.

## Host and source copy

### Host compatibility and capabilities

- Absorb Windows/macOS/Linux differences in the scripts. Explicitly use Git Bash on
  Windows, avoiding WSL shims. With MSYS automatic path conversion disabled for Docker,
  do not pass MSYS paths to native `git.exe`; change into the directory instead.
- Support Bash 3.2. Under `set -u`, guard empty arrays with
  `${array[@]+"${array[@]}"}` or an element-count check.
- Before creating a container, execute `tar --exclude` with an empty archive. Test NUL
  list support by executing `--null -T` with empty input; if unsupported, do not use
  Git file lists. Omitted short-help content or SIGPIPE from a help pipeline does not
  establish lack of capability.

### File selection

- For Git working trees, copy tracked and non-ignored untracked files using NUL
  delimiters. Exclude deleted tracked files and retain ignored tracked files. Use a
  full copy with fixed exclusions for `ZMK_COPY_IGNORED=1`, absent/failing Git,
  non-working trees or empty file lists.
- Fixed exclusions are `.git`, `.west`, `__pycache__`, and top-level `.zmk`, `.build`,
  `.cache`, `.ccache`, `.vscode`, `build`, `dist`, `node_modules`, `out`, `tmp` and
  `zmk_search`. Select top-level exclusions by root entry, without relying on
  OS-specific tar anchor semantics. Retain nested content with the same names.
- Exclude `zmk`, `modules`, `tools`, `bootloader` and `optional` as generated
  dependencies only when the source has `.west` and the corresponding tree has a
  `.git` marker. Names alone are insufficient. Do not auto-discover `local_modules/`.

## Layout, modules and applications

### Repository layout

- The entry point is a repository root containing `build.yaml` and `config/west.yml`.
  Direct config directories/custom config paths are unsupported. Standard board
  definitions belong in root/module `boards/`; allow existing `config/boards` as a
  compatibility path.
- Allow legacy target `zephyr/` content with a warning. Normalize missing metadata/root
  `module.yml` only inside the container. Do not modify host sources; add the target
  root as an extra module when metadata exists.

### Explicit modules

- Require explicit `-m` for every module. Resolve host paths, including `dir/.`, before
  detecting duplicates using the entire basename, including spaces. Validate/apply
  explicitly supplied hidden directories through the same list. Pass internal path
  lists using NUL delimiters.
- Explicit modules with root `CMakeLists.txt`/`Kconfig` require
  `build.cmake`/`build.kconfig`; `boards/`, `dts/` and `snippets/` require the
  corresponding `build.settings.*_root: .`. On the host, check only that required
  metadata files exist. Strictly validate YAML structure/keys inside the container
  before workspace changes/dependency updates; allow inline maps and quoted keys.
  Declared `build.cmake` / `build.kconfig` paths must be strings, including before
  target normalization.
  Preserve nested paths such as `proto/zmk`.

### Applications

- Normally use `zmk/app`. Top-level `application` specifies a repository-relative
  directory containing `CMakeLists.txt`. Reject absolute paths, parent traversal and
  symlinks escaping the repository. For standalone applications, resolve the package
  from the manifest's `zephyr` project and pass extra modules through
  `ZEPHYR_EXTRA_MODULES`; use `ZMK_EXTRA_MODULES` for normal ZMK. Supplement target
  root settings for standalone applications too. Preserve explicit module build
  declarations; do not infer `build.cmake`/`build.kconfig` from the application's
  CMake/Kconfig entry points.

## Persistent workspace and cache

### Workspace ownership

- Sync only `config/` into the workspace; point ZMK's `ZMK_CONFIG` at `config/` in the
  fresh container source. Separate volumes by repository/tool/purpose so roots outside
  the manifest can be pruned. Serialize builds modifying the same workspace with an
  OS lock; on contention, stop before sync, dependency updates or deletion. Keep the
  lock file outside the prune scope and release it when the build process exits.
  A retained container's existence alone must not prevent reuse.

### Overlay restoration and pruning

- Restore the previous overlay from workspace backups before applying current inputs.
  A directory whose name matches a west project is an overlay; otherwise it is an
  extra module. Record backup restoration information before changing the destination.
- Explicitly propagate restoration copy/deletion failures. Do not rely on errexit in
  functions invoked as if conditions; retain the affected backup/stamp and stop on
  failure. Reject absolute overlay paths and standalone parent `..` components;
  allow `..` within names. Atomically record restored/refetch-required state per project
  before cleaning backups. Do not delete restored projects again after a later failure
  or interruption. Accept legacy two-column records.
- Prune after restoration, using only fully successful `west list` results. Compare
  roots exactly using arrays, including spaces and hidden entries, and clean each once.
  Normalize in-workspace parent components before selecting roots; reject paths
  escaping the workspace.
  On list failure/partial output, retain caches and require an update; after success,
  recheck before pruning/stamping. Do not ignore deletion failures.

### Dependency reuse and updates

- Update when the digest of the entire `west manifest --resolve`, including imports,
  changes, resolution fails, required ZMK/projects are missing, `west list` fails or
  an overlay cannot be restored. Do not decide reuse from the entry file hash alone.
- Invalidate the ready marker before updates; stamp the resolved manifest only on
  complete success. Revalidate legacy records too. Nonempty checkouts after failure/
  interruption and unresolved manifests are not ready.
- Retry updates the configured number of times. Before each attempt, remove stale index
  locks without breaking spaces. Continuing after failure requires a complete project
  list and local overrides covering every failed project explicitly identified by the
  final attempt. Do not infer unknown/unsupported failures from a missing-project list
  or mix in failed names from earlier attempts. Do not record continuation with local
  overrides as a successful upstream update.

### Cache lifecycle

- Keep ccache on the cache volume, outside the west workspace.
  `CCACHE_IGNOREOPTIONS=-specs=*` assumes fixed SDK specs within the selected image.
  Recheck this assumption when changing SDK/image; include revision suffixes when
  selecting image tags.
- For both build and validate, the builder deletes the entire volume for `--pristine`.
  Match against a complete volume list; continue if absent, but stop before container
  creation on list/deletion failure. This deletes dependencies/ccache too, so do not
  use it for overlay restoration tests.

## Parser, build and output

### CLI and YAML

- Maintain public CLI/environment-variable tables in the READMEs. Interpret positive
  integers as decimal; reject all-zero values, including `00`.
- Preserve top-level/include matrices, defaults, exclude, skip, aliases and artifact
  placeholders. Evaluate exclude against YAML values before composing CLI snippets;
  deduplicate reset targets per board.
- Distinguish None from falsey types; validate scalar lists/quoting. Reject NUL in
  board/shield/snippet/CMake arguments before shell handoff. Do not trim literal lists.
  Pass shlex results with NUL delimiters, preserving empty arguments, quoting and
  leading/trailing spaces.
- Normalize artifact names to safe filenames. Check the portion before the first dot
  for Windows reserved names too. Reject case-insensitive duplicates and collisions
  with reserved output names such as logs/summaries.

### Target execution

- Separate build directories/logs per target. Keep parallel failure counts as integer
  data, not packed into an 8-bit exit status. Collect batch failures, do not start
  subsequent pending targets, and preserve log order. Default target parallelism for
  external full/pristine builds is 1.
- Each target uses a subshell EXIT handler to delete intermediate directories on
  success and compile/artifact-selection/copy failures, retaining dependencies/ccache.
  Log deletion failures and turn success into failure, preserving the original build
  error's exit status when one exists.

### Artifacts and summaries

- Collect one firmware file per target, preferring `.uf2`, then the configured fallback,
  then `.hex`, then `.bin`. Host enumeration, summaries and checkers recognize the same
  extensions, excluding logs/summaries themselves. Extensions must not contain paths,
  globs, leading dots or hyphens.
- Runs use `.build/run-YYYY-MM-DD_HH-MM-SS-pid-PID/`. Once started, retain `build.log`,
  a FAILED summary, Reason and an error excerpt even on setup/pristine/create/start/
  source-copy/build/artifact-copy/cleanup failures. Propagate artifact-copy failures
  to the caller. Stream builds into the main container log too; do not propagate
  `stdbuf`'s `LD_PRELOAD` to children. For SIGINT/SIGTERM, finalize the reason/exit status
  and use the same finalization path. Stop and retain containers requested for retention
  when interrupted.
  Defer signals through ID acquisition, exit-handler entry and cleanup. Publish
  one atomic final summary after cleanup; preserve earlier build failures, and
  commit the exit status before summary publication.
  Firmware existence probes must drain the enumerator without inducing SIGPIPE.
- Summary fields are Status, Reason on failure, Mode, Target, Docker image/cache volume,
  Elapsed, Built targets, Pristine, Build jobs, Fallback binary, Extra snippets, Module
  inputs and Files. Reject duplicate major fields and summaries in invalid run paths.
- Derive Built targets from log lines stripped of CR/ANSI/prefixes; fall back to firmware
  counts only for successful builds. The checker requires successful status, mode, log,
  a positive target count and an exactly matching firmware count. Legacy records without
  a fallback field use `bin`. For destination names too, reject only standalone `..`
  components; allow `case..name`.

## Containers, external sources and workflows

### Container ownership

- Start/exec/copy/clean up build, clone and test containers using the immutable ID
  returned by create. On create failure, do not delete an existing same-named container;
  the requested name is not proof of ownership.
- Reflect container deletion failures in logs/FAILED summaries while preserving prior
  build failure reasons/exit statuses. Respect `ZMK_KEEP_CONTAINER=1`. Do not proceed
  to retry/invoke the builder after clone-container deletion fails.

### External sources

- Distinguish URLs, UNC paths, absolute drive paths and relative paths; resolve slug
  collisions. Separate clones/caches/containers/artifacts per source.
  JSON output escapes all shell-representable control bytes and retains original
  indices after selection. CI source selectors always identify list files; reject
  missing lists during matrix resolution.
- After daemon preflight, fetch URLs with retries inside a clone container. Return them
  to the host using `docker cp`, not bind mounts. On Windows only, remove paths with
  trailing spaces/dots, forbidden characters, control characters/newlines or reserved
  device names, with warnings. Retain legal names and Unix sources.
- If deleting the host clone destination fails, stop fetching/copying. After repair,
  remove old files before copying. At exit, report success only after deleting the clone
  copy. If clone/build already failed, report deletion failure too. Delete only directly
  beneath the resolved clone root. Preserve local sources.
- The rolling queue collects actual worker exit statuses. Abnormal exit before writing
  a status file is a failure; keep other sources running and dispatch the next source
  into the free slot. Distinguish external source layout/API incompatibility from
  builder defects.

### Workflows

- Pass source/input/runner names through quoted `env:` values; do not embed
  `${{ ... }}` directly in shell text. Values the runner displays before execution must
  not contain private source information; limit matrix/step environment values to
  numeric indices. Prepare source selectors from the event payload into a private file
  at runtime; wrappers resolve/select sources. Do not hide build failures with
  `continue-on-error`. Limit CI console output and artifacts to public reports with
  fixed fields. Retain raw logs/firmware locally; do not call public copies unchanged
  raw records. Allow automatic uploads only from known report paths.
- Hosted Compatibility covers shells on three OSes and Ubuntu Docker. Self-hosted Build
  is a manual smoke test. Route external matrices with custom labels; use Git Bash/Bash
  according to `runner.os`. Verify labels/Docker access as the runner user. Do not confuse
  queuing due to an offline runner with failure.
- Preserve UTC cron schedules, conversion comments, concurrency and timeouts. This
  contract does not automatically authorize Heartbeat commits/pushes.

## Container test execution

Run automated tests, builds and dependency setup inside Docker. Host entry points
may launch containers and export results; do not run test runtimes or install test
packages/toolchains on the host. Owner source may be mounted read-only. Keep
test-only ZMK/Zephyr/tool checkouts, runtime environments, temporary files, build
outputs and caches in container images or named volumes. Tests must not require
host sibling dependency checkouts or private absolute paths.

Resolve and verify the selected revisions inside the container. Prepare missing
dependencies explicitly in an isolated container workspace; do not silently update
shared caches or pins. Preserve all owner scenarios, assertions and required
matrices. Hardware acceptance needs documented device access; report unavailable
container transports as BLOCKED rather than substituting host execution or mocked
acceptance. Export only reviewed evidence and retain the publication privacy rule.

### Fast container test execution

Use prepared container environments, persistent caches and bounded parallelism
to reduce execution time. Preserve every required scenario, assertion, negative
control, sanitizer, supported-core variant and repeat.

- Separate environment preparation from test execution. Pin container images by
  digest and resolve dependency revisions explicitly. Reuse prepared environments
  only when their image, toolchain, dependency revisions and lockfiles match.
  Do not fetch or update dependency inputs during an ordinary test run. Missing
  inputs block only dependent checks.

- Keep dependency checkouts, installed test environments, temporary files, build
  directories and caches in container images or named volumes. Prefer Linux
  filesystem storage for intensive file access. Any staged owner sources must
  preserve all required test/compiler inputs, including relevant untracked files,
  with source identity and pre/post-run drift verification.

- Reuse explicitly selected compiler and package caches with their supported
  identity and concurrency checks. Keep incompatible environments separate.
  Never share writable build directories or mutable installed dependency trees
  between independent jobs. Preserve required clean-cache checks; use isolated
  fresh caches for those checks.

- Dispatch each owner's canonical test entries from inside the container.
  Common orchestration may select, schedule and collect those entries; assertions
  and fixtures remain in the owning repository. Avoid nested Docker launches and
  repeated environment preparation for compatible jobs. Isolate each job's
  environment, working files and outputs.

- Enforce one configurable CPU and memory budget across concurrent suites,
  targets, compiler jobs and test workers. Account for nested parallelism.
  Parallelize only independent jobs; preserve required execution and output order.

- Within a run, build each required binary once per distinct input/configuration
  variant and reuse that exact binary for required identical-condition repeats,
  with each repeat's required initial state. Execute every required test; cached
  artifacts or previous PASS records do not establish a new test execution.

- Keep fresh build and evidence directories. Record actual commands, exits,
  completion markers, ordered output, source/dependency/image identities and
  cache configuration. Measure preparation, staging, build, execution and
  validation separately.

Quick and full retain their existing contracts. Interface/infrastructure changes
still require the complete owner matrix. Evaluate speed changes using equivalent
inputs and checks, report cold and warm runs separately, and retain failures.

## Validation gates and regression prevention

Classify defects by host/copy/workspace/update/overlay/build/artifact/summary/workflow
boundary. Before fixing, add a case that fails before the fix or an identifiable
negative control to an existing helper/fixture. Reflect the cause, fix and verification
in the relevant contract and tests. Do not add duplicate bug histories or remove/weaken
valid regression assertions. Check whether the same issue remains on another OS/workflow.

### Required checks

| Change scope | Required checks |
| --- | --- |
| Documentation only | LF, `git diff --check`, changed paths/links/CLI references; do not run firmware suites solely for documentation changes |
| Code/helpers/workflows | Applicable syntax, LF, `git diff --check`, related behavior/build gates |
| Helpers/summaries | Relevant behavior tests and failure status/reason/output |
| Copy/modules/sync/cache | Runner preflight, copy helper, relevant validate/firmware, immediate output check |
| Artifacts/fallback | Firmware fixture and output helper; verify non-UF2 selection too |
| Workflows | YAML/run-step syntax, relevant helpers/steps; remote CI remains unexecuted before publication |

Use `bash .github/scripts/test.sh shell|docker|build|all` as the local/CI entry point;
keep the layer mapping in the READMEs. As relevant to the change, check standard
validation (normal/reset), target shapes and CLI snippets, standard firmware,
project overlays/extra modules and restoration without pristine. Immediately after
each successful build/validate, run the output checker with the explicit run path.

### Evidence and regression fixtures

- Use a fresh evidence destination per execution, outside the repository or entirely
  Git-ignored. Reject visible internal destinations before starting. Record commands,
  statuses, timing, pre/post source checksums, image identity and raw failures; do not
  overwrite existing evidence.
- Do not edit running scripts. Freeze revised sources and rerun; a result with differing
  pre/post checksums is not a PASS for the latest source.
- Run tests as `bash <script>` and resolve temporary paths with `pwd -P`. For host guards,
  check both the reachability sentinel and rejection condition. Do not depend on
  executable bits or unnormalized Windows fake-bin paths.
- For Bash symlink fixtures, avoid Git Bash's copy fallback and verify `-L` after creation.
  Set any required MSYS link mode only on the creation command. Do not substitute
  permission-related skips or omit rejection assertions.
- Follow `.gitattributes`/`.editorconfig` for LF. Inspect raw bytes so CRLF, bare CR,
  Control-Z, large inputs and Git failures are not missed. Do not reset/rewrite the
  working tree for validation.
- Consolidate independent Docker conditions into one container. Exercise the production
  parser and inspect values, order and actual argv. Test update retries, stale locks
  containing spaces, partial failures and recovery by controlling command boundaries
  inside the current image.
- Clean up test containers only by acquired IDs. Use dedicated test caches; distinguish
  ownership of explicitly selected reusable caches from automatically created caches.
- Separate local checks, remote CI and physical operation. Fixture success does not
  establish PASS for real network failures, different west versions, real builds with
  older images, non-amd64 native hosts or post-publication hosted/self-hosted execution
  without corresponding evidence.

## Completion and reporting

Recheck the latest scope, preservation of existing changes, unnecessary new files/
unintended diffs, LF, syntax and required checks. Report changed files, PASS/FAIL/
unexecuted checks with reasons, remaining environment boundaries, whether commits/
pushes occurred and the worktree state. Publish only with explicit instructions for
each operation; after publication, check relevant remote CI results too.
