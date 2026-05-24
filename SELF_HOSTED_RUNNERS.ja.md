# self-hosted runner セットアップ

macOS / Windows の実機で Docker smoke test を確認したい場合は、この手順を使います。
Linux self-hosted runner は任意です。Ubuntu Docker validation は hosted の
Compatibility workflow で既に確認します。

## なぜ self-hosted runner を使うか

通常の互換性確認、Ubuntu Docker validate、CI fixture build、target-shape parser、
module override coverage は GitHub hosted CI を release gate として使います。
self-hosted runner は、実際に重視する Windows / macOS / Linux マシン上の Docker Desktop
または Docker Engine で動くことを証明したい場合に使います。
主目的は macOS / Windows 実機の確認です。Linux self-hosted run は、特定の Linux host
で動くことを証明したい場合だけ使います。

self-hosted workflow は意図的に標準 CI fixture だけを実行します。hosted の
Compatibility workflow の代替ではなく、実機 Docker smoke coverage として扱います。

runner が隔離されていて、その repository で動く workflow をすべて信頼できる場合を除き、
self-hosted workflow は手動実行のままにしてください。

## 必要な label

workflow は GitHub の既定 OS label と、独自 label 1 つを使います。

| ホスト | 必要な labels |
|---|---|
| Linux | `self-hosted`, `linux`, `zmk-docker` |
| macOS | `self-hosted`, `macOS`, `zmk-docker` |
| Windows | `self-hosted`, `windows`, `zmk-docker` |

runner を `--no-default-labels` 付きで設定しないでください。既定 label で OS を振り分け、
独自 label の `zmk-docker` で Docker build 用 runner を明示します。

GitHub の label は大文字小文字を区別しませんが、この workflow では GitHub docs の既定表記に合わせています。

## runner 登録

1. GitHub で repository を開きます。
2. `Settings` -> `Actions` -> `Runners` を開きます。
3. `New self-hosted runner` を押します。
4. 対象 OS と architecture を選びます。
5. GitHub が表示する download / configure command を、その machine 上で実行します。
6. 設定時または runner settings から `zmk-docker` label を追加します。
7. runner を起動し、GitHub 上で `Idle` 表示になることを確認します。

設定 command の形は次のようになります。

```bash
./config.sh --url https://github.com/amgskobo/zmk-build-script --token <token> --labels zmk-docker
```

実際の token と package は GitHub UI が表示するものを使ってください。runner registration token は期限切れになるため、毎回 UI から新しいものをコピーします。

## macOS runner

runner を起動する前に Docker Desktop をインストールし、起動しておきます。

ローカル preflight:

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

最初の GitHub 実行はこれがおすすめです。

```text
Workflow: Self-hosted Build
platform: macos
mode: validate
```

validate が通ったら full build を実行します。

```text
Workflow: Self-hosted Build
platform: macos
mode: build
pristine: true
```

Docker Desktop がログイン中 user session でしか使えない場合は、service 化する前に、
Docker Desktop を使える同じ user で runner を起動して確認してください。

## Windows runner

Git for Windows と Docker Desktop をインストールします。workflow は Git Bash を
既定 path の `C:\Program Files\Git\bin\bash.exe` から実行します。workflow では
WSL の `bash.exe` shim を避けるため、同じ場所を short path で呼び出します。

Git Bash からのローカル preflight:

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

Actions runner を Windows service として動かす場合は、その service user が対話承認なしで
Docker Desktop にアクセスできることを確認してください。

## Linux runner

Docker Engine または Docker Desktop をインストールし、runner user が Docker にアクセスできるようにします。

ローカル preflight:

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

runner user を `docker` group に追加した場合は、workflow を試す前に runner session または service を再起動してください。

## workflow 実行

`Actions` -> `Self-hosted Build` -> `Run workflow` を開きます。

おすすめ順:

```text
platform: <online runner の OS label>
mode: validate
```

次に:

```text
platform: <同じ OS label>
mode: build
```

workflow の default は `platform: macos` です。self-hosted coverage は主に
macOS / Windows のためです。Windows runner を試す場合は `windows` を明示し、
Linux は特定の Linux host を smoke-test したい場合だけ選びます。
各 OS を個別に通し、対象 runner がすべて online の場合だけ最後にまとめて実行します。

```text
platform: all
mode: build
```

workflow は常に `.github/fixtures/ci-zmk-config` を使います。
config directory path や fixture 名の入力は不要です。

workflow は直近の有効な `.build/run-YYYY-MM-DD_HH-MM-SS-pid-PID` directory を確認します。
`.build/**/build-summary.txt` が `Status: SUCCESS` で requested mode と一致することを確認し、
`.build/**/build-summary.txt`、`build.log`、生成された firmware file を upload します。
build mode では firmware file が 0 件、または built target count より少ない場合も失敗します。
run directory 命名規則外の `build-summary.txt` は stale な invalid output として失敗します。

## トラブルシューティング

workflow が queued のままなら、runner が offline、busy、別 repository / organization に割り当てられている、または必要 label が足りない可能性があります。

`docker version` は通るが `docker info` が失敗する場合、Docker はインストールされていますが、runner user から daemon に到達できていません。

`tar --help | grep -- --exclude` が失敗する場合は、GNU tar または bsdtar をインストールし、runner の `PATH` で先に見つかるようにしてください。

macOS で Terminal から Docker が動くのに Actions で失敗する場合は、Docker Desktop にアクセスできる同じログイン user session から runner を起動してください。
