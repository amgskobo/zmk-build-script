# self-hosted runner セットアップ

Windows、macOS、Linux の実機で Docker build を確認したい場合は、この手順を使います。

## なぜ self-hosted runner を使うか

通常の互換性確認と Ubuntu Docker validate / CI fixture build は GitHub hosted CI で十分です。
self-hosted runner は、実際に重視する Windows / macOS / Linux マシン上の Docker Desktop
または Docker Engine で動くことを証明したい場合に使います。

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
if git grep -I -n $'\r' -- .; then exit 1; fi
./build.sh validate .github/fixtures/ci-zmk-config
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

Git for Windows と Docker Desktop をインストールします。workflow は `shell: bash` を使うため、
Actions runner から Git Bash を実行できる必要があります。

Git Bash からのローカル preflight:

```bash
bash --version
tar --help | grep -- --exclude
docker version
docker info
bash -n ./build.sh
if git grep -I -n $'\r' -- .; then exit 1; fi
./build.sh validate .github/fixtures/ci-zmk-config
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
if git grep -I -n $'\r' -- .; then exit 1; fi
./build.sh validate .github/fixtures/ci-zmk-config
```

runner user を `docker` group に追加した場合は、workflow を試す前に runner session または service を再起動してください。

## workflow 実行

`Actions` -> `Self-hosted Build` -> `Run workflow` を開きます。

おすすめ順:

```text
platform: macos
mode: validate
```

次に:

```text
platform: macos
mode: build
```

各 OS を個別に通したあと、最後にまとめて実行します。

```text
platform: all
mode: build
```

workflow は常に `.github/fixtures/ci-zmk-config` を使います。
config directory path や fixture 名の入力は不要です。

workflow は `.build/**/build-summary.txt`、`build.log`、生成された firmware file を upload します。

## トラブルシューティング

workflow が queued のままなら、runner が offline、busy、別 repository / organization に割り当てられている、または必要 label が足りない可能性があります。

`docker version` は通るが `docker info` が失敗する場合、Docker はインストールされていますが、runner user から daemon に到達できていません。

`tar --help | grep -- --exclude` が失敗する場合は、GNU tar または bsdtar をインストールし、runner の `PATH` で先に見つかるようにしてください。

macOS で Terminal から Docker が動くのに Actions で失敗する場合は、Docker Desktop にアクセスできる同じログイン user session から runner を起動してください。
