# Self-hosted Runner Setup

Use this guide when you want a real-machine Docker smoke test on your own macOS
or Windows machines. Linux self-hosted runners are optional because the hosted
Compatibility workflow already covers Ubuntu Docker validation.

## Why Self-hosted Runners

GitHub hosted CI is the release gate for regular compatibility checks, Ubuntu
Docker validation, CI fixture builds, target-shape parsing, and module override
coverage. A self-hosted runner is useful when you need proof that Docker Desktop
or Docker Engine works on the actual macOS or Windows machine you care about.
Linux self-hosted runs are useful only when you need proof for a specific Linux
host.

The self-hosted workflow intentionally runs only the standard CI fixture. Treat
it as real-machine Docker smoke coverage, not as a replacement for the hosted
Compatibility workflow.

Keep the self-hosted workflow manual-only unless the runner is isolated and you
trust every workflow that can run on the repository.

## Required Labels

The workflow expects each runner to keep GitHub's default OS labels and to add
one custom label:

| Host | Required labels |
|---|---|
| Linux | `self-hosted`, `linux`, `zmk-docker` |
| macOS | `self-hosted`, `macOS`, `zmk-docker` |
| Windows | `self-hosted`, `windows`, `zmk-docker` |

Do not configure the runner with `--no-default-labels`. The default labels route
jobs to the correct operating system. The custom `zmk-docker` label keeps these
Docker-heavy builds away from unrelated self-hosted runners.

GitHub treats labels as case-insensitive, but the workflow uses GitHub's documented
default label spelling.

## Register a Runner

1. Open the repository on GitHub.
2. Go to `Settings` -> `Actions` -> `Runners`.
3. Click `New self-hosted runner`.
4. Choose the target operating system and architecture.
5. Follow GitHub's generated download and configure commands on that machine.
6. Add the `zmk-docker` label during configuration, or add it later from the runner settings.
7. Start the runner and confirm it appears as `Idle` in GitHub.

Example configuration shape:

```bash
./config.sh --url https://github.com/amgskobo/zmk-build-script --token <token> --labels zmk-docker
```

Use GitHub's generated command for the real token and platform package. Runner
registration tokens expire, so copy them fresh from the GitHub UI.

## macOS Runner

Install and start Docker Desktop before starting the runner.

Local preflight:

```bash
bash --version
tar --help | grep -- --exclude
docker version
docker info
bash -n ./build.sh
for script in .github/scripts/*.sh; do bash -n "${script}"; done
bash .github/scripts/check-lf.sh
bash .github/scripts/test-check-lf.sh
bash .github/scripts/test-check-build-output.sh
./build.sh validate .github/fixtures/ci-zmk-config
bash .github/scripts/check-build-output.sh validate
```

For the first GitHub run, use:

```text
Workflow: Self-hosted Build
platform: macos
mode: validate
```

After validate succeeds, run:

```text
Workflow: Self-hosted Build
platform: macos
mode: build
pristine: true
```

If Docker Desktop is available only in an interactive user session, run the
runner under that same logged-in user before installing it as a background
service.

## Windows Runner

Install Git for Windows and Docker Desktop. The workflow uses `shell: bash`, so
Git Bash must be installed at the default `C:\Program Files\Git\bin\bash.exe`
path. The workflow calls it through the equivalent short path to avoid the WSL
`bash.exe` shim.

Local preflight from Git Bash:

```bash
bash --version
tar --help | grep -- --exclude
docker version
docker info
bash -n ./build.sh
for script in .github/scripts/*.sh; do bash -n "${script}"; done
bash .github/scripts/check-lf.sh
bash .github/scripts/test-check-lf.sh
bash .github/scripts/test-check-build-output.sh
./build.sh validate .github/fixtures/ci-zmk-config
bash .github/scripts/check-build-output.sh validate
```

If you run the Actions runner as a Windows service, make sure that service user
can access Docker Desktop without an interactive approval prompt.

## Linux Runner

Install Docker Engine or Docker Desktop and make sure the runner user can access
Docker.

Local preflight:

```bash
bash --version
tar --help | grep -- --exclude
docker version
docker info
bash -n ./build.sh
for script in .github/scripts/*.sh; do bash -n "${script}"; done
bash .github/scripts/check-lf.sh
bash .github/scripts/test-check-lf.sh
bash .github/scripts/test-check-build-output.sh
./build.sh validate .github/fixtures/ci-zmk-config
bash .github/scripts/check-build-output.sh validate
```

If you add the runner user to the `docker` group, restart the runner session or
service before trying the workflow.

## Run the Workflow

Open `Actions` -> `Self-hosted Build` -> `Run workflow`.

Recommended order:

```text
platform: <the OS label for your online runner>
mode: validate
```

Then:

```text
platform: <the same OS label>
mode: build
```

The workflow default is `platform: macos` because self-hosted coverage is mainly
for macOS and Windows. Choose `windows` explicitly for a Windows runner and
`linux` only when you need to smoke-test a specific Linux host. After each OS
succeeds individually, and only when all selected runner types are online, run:

```text
platform: all
mode: build
```

The workflow always uses `.github/fixtures/ci-zmk-config`, so no config path or
fixture name is required.

The workflow checks the most recent valid `.build/run-YYYY-MM-DD_HH-MM-SS-pid-PID`
directory, verifies that `build-summary.txt` reports `Status: SUCCESS` and
matches the requested mode, then uploads `.build/**/build-summary.txt`,
`build.log`, and generated firmware files. Build mode also fails if no firmware
file is produced or if the firmware count is lower than the built target count.
A `build-summary.txt` outside the run directory naming contract is treated as an
invalid stale output and fails the check.

## Troubleshooting

If the workflow stays queued, the runner is offline, busy, assigned to a different
repository or organization, or missing one of the required labels.

If `docker version` works but `docker info` fails, Docker is installed but the
daemon is not reachable from the runner user.

If `tar --help | grep -- --exclude` fails, install GNU tar or bsdtar and make
sure it is earlier in `PATH` for the runner.

If macOS Docker works in Terminal but fails in Actions, start the runner from the
same logged-in user session that can access Docker Desktop.
