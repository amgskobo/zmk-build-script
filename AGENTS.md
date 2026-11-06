# zmk-build-script: agent guide

English is the authoritative guide. [日本語版](AGENTS.ja.md) contains the same rules; update both
together.

## Scope and contract

- Own `build.sh`: build/validate/clean one config or explicitly selected standalone application,
  copy inputs, manage its workspace and collect artifacts. External enumeration/cloning stays in
  `scripts/auto-build-external.sh`, `scripts/build-external-source.sh` and
  `scripts/source-common.sh`. Keep usage/CLI/environment tables in both READMEs; omit one-off
  project names, commits, dates, measurements and workstation details. Keep individual-build
  features in `build.sh`; add environment variables for needed opt-outs, and reuse existing
  responsibilities/scenarios before adding scripts, containers or fixtures.

- Support Bash 3.2 and standard Unix tools; production Git is optional. On Windows use Git Bash and
  explicit MSYS/native Git/Docker path conversion. Guard empty arrays under `set -u`. Before
  container creation, probe tar exclusions with an empty archive and NUL-list support with empty
  `--null -T` input; help text or help-pipeline SIGPIPE is not proof. Do not reconfigure the host,
  reclaim global memory or stop unrelated tools. Avoid WSL shims; with Docker path conversion
  disabled, change directories for native Git rather than passing MSYS paths to it.

- Copy tracked and nonignored untracked files with NUL delimiters, excluding deleted tracked files
  and retaining ignored tracked files. Fall back to fixed-exclusion copying for absent/failing/empty
  Git selection or `ZMK_COPY_IGNORED=1`. Exclude `.git`, `.west` and `__pycache__`; select top-level
  exclusions by root entry without platform-specific tar anchoring, retaining nested names. Keep
  host-to-container and container-to-workspace copy boundaries distinct.

- Fixed top-level exclusions are `.zmk`, `.build`, `.cache`, `.ccache`, `.vscode`, `build`, `dist`,
  `node_modules`, `out`, `tmp`, `zmk_search`. Exclude generated `zmk`, `modules`, `tools`,
  `bootloader`, `optional` roots only when source `.west` and each root's `.git` marker establish
  them. Names alone are insufficient; never auto-discover `local_modules/`.

- Require a repository root with `build.yaml` and `config/west.yml`; custom config-directory entry
  points are unsupported. Keep root/module boards and legacy config/boards compatibility, warn for
  legacy target zephyr content and normalize missing metadata only in the container. Every module
  needs explicit `-m`, including hidden/space-containing paths. Resolve paths including dir/. before
  rejecting duplicate full basenames; pass path lists NUL-delimited.

- On the host check only required metadata-file existence. Inside the container, strictly validate
  YAML structure/keys/types before workspace mutation or dependency updates, accepting inline
  maps/quoted keys. Root CMakeLists.txt/Kconfig require explicit build.cmake/build.kconfig strings;
  boards/dts/snippets require corresponding build.settings.*_root: . declarations. Preserve nested
  paths such as proto/zmk and explicit module declarations.

- Standalone `application` is repository-relative and contains CMakeLists.txt: reject
  absolute/parent traversal and escaping symlinks. Resolve its manifest Zephyr project/package and
  pass modules through `ZEPHYR_EXTRA_MODULES`; normal ZMK uses `ZMK_EXTRA_MODULES`. Supplement
  target-root settings for standalone too, without inferring module build declarations from
  application entry points. Keep source, target and Ninja concurrency separate.

- Use dedicated repository/tool/purpose volumes. Lock a workspace before sync/update/prune;
  contention stops before mutation. Keep the lock outside prune scope and release on process exit; a
  retained container alone does not block reuse. Sync only config into the workspace and point
  ZMK_CONFIG at the fresh container source. Restore previous overlays before current inputs: a
  west-project name is an overlay, other explicit modules are extra modules.

- Record restoration information before destination changes; explicitly propagate copy/deletion
  failure instead of relying on errexit in condition-invoked functions. Retain failed backups/stamps
  and stop. Reject absolute overlay paths and standalone parent components, allowing embedded dots.
  Atomically record restored/refetch-required state before backup cleanup; never re-delete restored
  projects after later failure/interruption. Accept legacy two-column records. Normalize
  in-workspace parents and reject escaping roots. Prune exact normalized roots, including
  spaces/hidden entries, only from a fully successful west list and recheck before pruning/stamping.
  Partial/failing lists retain caches and require update; deletion failures are errors.

- Decide reuse from the entire resolved manifest including imports and valid project/overlay state,
  not its entry-file hash. Missing projects, resolution/list/restoration failure require update.
  Invalidate readiness first; stamp only complete success and revalidate legacy records. Nonempty
  failed/interrupted checkouts are not ready. Retry explicitly, safely clearing stale index locks
  including spaces. Continue after fetch failure only with a complete project list and explicit
  local overrides for every failed project identified by the final attempt; never mix earlier
  failures or infer unknown failures. Record continuation separately from a successful upstream
  update.

- Keep ccache outside the west workspace. `CCACHE_IGNOREOPTIONS=-specs=*` assumes fixed SDK specs
  within the selected image; recheck on image/SDK changes and retain image-tag revision suffixes.
  `--pristine` removes the entire selected volume for build and validate, including
  dependencies/ccache. Check the complete exact volume list; absence is allowed, but
  listing/deletion failure stops before container creation. Do not use pristine for
  overlay-restoration tests.

- Preserve build-matrix defaults/include/exclude/skip/aliases, placeholders and snippets; evaluate
  exclude on raw YAML before CLI-snippet composition and deduplicate reset targets per board. Parse
  positive integers as decimal, rejecting all-zero forms including 00. Distinguish None from falsey
  types; validate scalar/list types and reject NUL before shell handoff. Preserve quoting, empty
  arguments and literal whitespace through shlex/NUL. Sanitize artifact names, Windows reserved
  stems before the first dot, case-insensitive duplicates and log/summary collisions; reject
  standalone parent components, not embedded dots.

- Isolate target build/log trees and collect logs in target order. Keep parallel failure counts as
  integers, not 8-bit exit packing; collect current-batch failures and stop pending batches.
  External full/pristine defaults to one target at a time. Each target's subshell EXIT cleanup
  removes intermediates on success and compile/selection/copy failure while retaining
  dependencies/ccache. Cleanup failure turns success into failure and preserves any original build
  error/status.

- Operate build/clone/test containers by the immutable ID returned from create. Create failure never
  authorizes deleting an existing same-named container. Respect `ZMK_KEEP_CONTAINER=1`, stopping
  retained containers on interruption. Propagate cleanup failures without hiding prior build errors;
  clone-container deletion failure stops retries/builder invocation. Defer signals through ID
  acquisition, handler entry and cleanup, commit the true exit status, then publish one atomic final
  summary. Do not leak stdbuf LD_PRELOAD to children.

- Collect one firmware per target: `.uf2`, configured fallback, `.hex`, then `.bin`. Reject fallback
  extensions containing paths/globs or leading dots/hyphens; host enumeration, summaries and
  checkers use the same extensions and exclude logs/summaries. Existence probes drain without
  SIGPIPE. Every started run uses `.build/run-YYYY-MM-DD_HH-MM-SS-pid-PID/` and retains `build.log`,
  `build-summary.txt`, failure reason/excerpt on
  setup/pristine/create/start/source-copy/build/artifact-copy/cleanup failures or interruption.
  Propagate artifact-copy failures.

- Summary/checker agree on status, failure reason, mode, target, image/cache, elapsed time, built
  count, pristine/jobs/fallback/snippets/modules and files. Reject duplicate major fields and
  invalid run paths. Count build markers after stripping CR/ANSI/prefixes; fall back to firmware
  counts only for successful builds. The checker requires success, mode, log, positive target count
  and exactly matching firmware count. Legacy summaries without fallback use bin.

- External wrappers handle URL/UNC/drive/relative paths, unique slugs and isolated per-source
  clone/cache/container/artifact trees. JSON escapes all shell-representable control bytes and
  retains original selection indices; CI selectors name existing list files. Fetch with retries in a
  clone container after daemon preflight and return via docker cp, not bind mounts. On Windows
  remove only incompatible clone paths with warnings. Failed host deletion stops replacement; delete
  old files before copying after repair. Success requires clone cleanup, confined directly beneath
  the resolved clone root; preserve local sources. Collect actual worker exits, including
  missing-status-file failures, while other sources continue and free slots receive pending work.
  Resolve relative entries in `repos.txt` against the list file directory; classify external
  layout/API incompatibility separately from builder defects.

- CI passes source/runner inputs through quoted env or structured files, never direct expression
  interpolation in shell. Runner-visible matrix/step values contain only numeric source indices;
  derive private selectors from event payload into runtime files. Keep raw logs/firmware private,
  upload only reviewed fixed-field reports from known report paths and never hide failures with
  continue-on-error. Preserve hosted three-OS shell/Ubuntu Docker versus manual self-hosted smoke
  roles, custom labels and runner.os shell selection. Check Docker access as the runner user;
  offline queues are not build failures. Preserve UTC cron and conversion comments, concurrency and
  timeouts; Heartbeat grants no publication authority.

- For a regression add a failing-original case or named control to the existing affected
  host/copy/workspace/update/overlay/build/artifact/summary/workflow suite and check other
  OS/workflow variants. Run scripts through bash, normalize temporary paths with pwd -P, check
  host-guard reachability and rejection, and verify actual symlinks rather than Git Bash copy
  fallbacks/skips. Preserve LF/CRLF/bare CR/Control-Z, spaces, large input, Git failure and actual
  parser argv/order assertions. Consolidate independent Docker conditions, use dedicated caches and
  acquired container IDs. Immediately check each successful build/validate with its exact run
  directory. Fixture success alone proves neither real network/west/image/native-host variants nor
  hosted/self-hosted execution.

- Reading map for relevant changes: [README.md](README.md), [README.ja.md](README.ja.md). Read the
  affected contract/coverage sections; documentation-only edits do not require unrelated dependency
  tours.

## Working rules

- Read the request and existing diff; preserve unrelated and staged work. Finish authorized
  inspection, edits and reversible checks without repeated approval. Ask only for a missing decision
  or an out-of-scope action. Before a destructive rewrite, preserve irreplaceable uncommitted
  content as private evidence, not rolling whole-tree copies.

- Git staging, commits, pushes, PR changes, merges, tags, publication, flashing and settings/bond
  erasure need authorization for that operation. Existing authorization remains valid for the same
  operation and scope. Dependency guides and passing checks grant none. Before an authorized commit,
  run applicable pre-commit hooks in Docker without bypasses; keep the configured Git identity.

- Use the selected checkout and manifest/lock sources; do not silently switch branches, reset
  history, replace remotes or create authoring copies. Before changing selection, verify source
  URLs/full commits, review dependency changes, update affected pins/locks and run owner/integration
  checks. Distinguish local working snapshots from remotely retrievable commits; report missing refs
  rather than inventing them.

- Read relevant root/nested owner and dependency instructions once per selected checkout/revision.
  Resolve actual west imports, local overrides, enabled features and backend; sibling
  directories/cache names do not identify inputs. Record READ, NO AGENTS or INACCESSIBLE when
  preflight requires it. Missing inputs block dependent checks; continue independent authorized
  work.

- Keep permanent agent rules in this synchronized EN/JA pair. Usage/API details stay in their
  existing documentation homes. Do not add agent-guide fragments or private shared-guide
  dependencies. Remove duplicated rules and obsolete task/branch assumptions without discarding
  active contracts.

## Execution environment

- Run local automated test/build runtimes and dependency setup in Docker; a documented DevContainer
  qualifies. Unless stated otherwise, work from the owner root in its resolved workspace. Launch
  Docker-wrapper scripts on the host; run their inner Python/Node/compiler entries inside the
  prepared container without wrapping Docker again. Host source/Git/reference checks and evidence
  export are allowed; do not install test packages/toolchains on the host. Keep dependencies,
  runtime/build trees and caches in images or named volumes.

- Separate preparation and deliberately selected online compatibility checks from ordinary
  network-free tests. Inspect the available immutable image ID/digest and verified
  dependency/toolchain revisions; pass the image through the owner's declared image option; honor
  declared local overrides and record working files. A launcher that installs or fetches
  dependencies belongs to preparation/online checking, not an offline run. Do not silently pull,
  advance pins or mutate shared caches, patch dependencies or disable required features to clear a
  gate. Missing inputs block dependent checks only; documented preparation within an authorized
  build/setup remains in scope.

- Reuse compatible environments/caches, retaining required clean-cache lanes. Provide required
  inputs, including relevant untracked files, through read-only mounts or isolated container copies;
  verify source identity before/after. Isolate mutable build/runtime/install trees per job under one
  CPU/memory budget, including nested workers. Build once per configuration and reuse that exact
  binary for identical repeats; cached PASS is not a new run. Performance comparisons separate
  preparation/staging/build/execution/validation and cold/warm conditions. Existing hosted platform
  jobs retain their own OS requirements.

## Checks and entry points

- Documentation/instructions only: check LF with the existing checker, run `git diff --check`, and
  verify changed paths/commands and EN/JA agreement. Without Git history use
  `git diff --no-index --check` on before/after copies. Firmware
  suites are not required solely for prose changes.

- For code/helpers/workflows select `bash .github/scripts/test.sh shell`,
  `bash .github/scripts/test.sh docker`, `bash .github/scripts/test.sh build` or
  `bash .github/scripts/test.sh all` for the affected boundary. Local shell test runtimes run inside
  the prepared container. Docker/build/all additionally need the documented Docker-daemon access and
  daemon-visible source paths; a missing transport is BLOCKED, not a mocked build PASS. Retain the
  complete affected copy/cache/overlay/parser/infrastructure matrix and each hosted OS job.

- Immediately after a successful run use
  `bash .github/scripts/check-build-output.sh validate RUN_DIRECTORY` or
  `bash .github/scripts/check-build-output.sh build RUN_DIRECTORY`. Use the exact new run path; keep
  raw failures and distinguish local checks from later remote CI.

## Test quality

- Use representative configuration builds as integration samples for maintaining builder quality.
  Keep the measure tied to supported contracts and normal/boundary/failure/recovery coverage, not
  a fixed list of example repositories or their success count. Define expected input, image and
  artifact names independently before execution; verify exact outputs rather than only counts.
  Retain controls that reject a wrong image, wrong input or renamed firmware with an unchanged
  artifact count. Put reusable checks in existing owner suites and keep external examples optional;
  record their source/dependency identities and untested conditions without claiming universal
  compatibility or absence of defects from a successful sample.

- Keep module fixtures, assertions, independent oracles, mutations, selectors and validators in the
  owner's tests/; retain documented Web and non-module test layouts. CI/package scripts dispatch
  owner entries, not sibling/private suites or source-rewriting substitutes. Probes expose state,
  not scenarios. Map implementation families to normal/boundary/invalid, independent-state,
  ordered-time/output, reset/cancel, failure/recovery and role/protocol cases and explicit gaps.

- A regression needs a failing original or named control. Expected-failure controls qualify only by
  their specified assertion/rejection; report them separately from product results. Do not weaken
  assertions, accept unclassified snapshots or count compilation errors as killed runtime faults.
  Before retiring tests, archive unique original assertions/failures externally with a replacement
  map. Quick runs every behavioral scenario with sanitizers where supported; full adds the
  documented ABI, optimization, coverage, kernel and supported-core matrix.

- Use focused checks for local implementation changes and the complete affected owner matrix for
  interface/test-infrastructure changes. Run unchanged stock ZMK and DYA only where both are
  supported. DYA-only features are NOT APPLICABLE to stock; disabling them is not compatibility
  evidence. For test suites, verify the required nonempty case/fixture completions; a zero exit
  alone, skipped required cases, timeouts or setup errors do not establish PASS.

## Evidence and handoff

- Use fresh evidence paths: resolve parents and reject existing files, directories or symlinks.
  Record commands/exits, source/dependency/config/backend/image identities and raw ordered
  output/times, retaining first failures and relevant config/DTS/binaries. Source or dependency
  drift invalidates affected results; never edit running scripts. Put retained outputs on a mounted
  named volume or export them before container removal, including failures; a path printed inside a
  disposable container is not retained evidence.

- Preserve exact fixed-input traces or specification-based timing bounds; totals do not replace
  per-report order/time. Before calling a mismatch nondeterministic, repeat identical
  binary/input/seed/backend/initial-flash conditions and PHY where applicable at least three times.
  Host load alone is not an explanation. Distinguish invalid/stale/incomplete/unavailable
  observations from valid zero.

- Report PASS, FAIL, BLOCKED, NOT RUN and NOT APPLICABLE distinctly. Local CI, host/native/compile
  and simulator results do not establish hosted CI, browser or physical
  HID/BLE/split/electrical/power/reset acceptance. Validate exercised production paths and correlate
  hardware before simulator-fidelity claims. End-to-end/stability claims need matching
  installed-image and host observations; quiet logs are not proof.

- Before sharing, review source/comments/guides/examples/logs/media/artifacts/metadata for
  credentials, personal/host/device IDs, private paths, bonds and individual histories/preferences.
  Authorized local work may use real values; keep private originals and label sanitized copies. Use
  clearly synthetic public fixtures/placeholders; preserve public project/API identifiers, licenses
  and attribution. Keep useful diffs/evidence. Handoff reports behavior, files, actual checks,
  gaps/risks and version-control/device actions.
