# ZMK Build Script

[English README](README.md)

ZMK configuration repository と、明示的に指定した独立 Zephyr application を build する
Docker + Bash helper です。1 repository の build、依存・compiler cache の再利用、host への
firmware / log 回収を担当します。保守契約は [AGENTS.ja.md](AGENTS.ja.md)（[英語の正本](AGENTS.md)） に集約しています。

- [必要なものと最初の実行](#必要なものと最初の実行)
- [Docker image](#docker-image)
- [コマンドと環境変数](#コマンドと環境変数)
- [並列ビルド](#並列ビルド)
- [ビルド設定](#ビルド設定)
- [モジュールとソースコピー](#モジュールとソースコピー)
- [外部source](#外部source)
- [キャッシュと成果物](#キャッシュと成果物)
- [ワークフローとrunner](#ワークフローとrunner)
- [保守と検証](#保守と検証)

## 必要なものと最初の実行

Docker Desktop または Docker Engine の Linux engine と、標準 Unix tool が使える Bash が必要です。
production builder の Git は任意です。Windows は Git Bash を使い、PowerShell からは明示して起動します。

```powershell
& 'C:\Program Files\Git\bin\bash.exe' ./build.sh ../your-zmk-config
```

このtoolのrepository rootから、Windows / macOS / Linux の Bash で次のように実行します。

```bash
./build.sh validate ../your-zmk-config
./build.sh ../your-zmk-config
```

### sourceの構成

入口は `build.yaml` と `config/west.yml` を持つ repository root です。
config directory の直接指定や custom config path は扱いません。

```text
your-zmk-config/
+-- build.yaml
+-- config/
|   +-- west.yml
|   +-- <keyboard>.conf
|   +-- <keyboard>.keymap
|   +-- boards/...        # 既存の compatibility path
+-- zephyr/module.yml     # module metadata
+-- boards/...            # 標準の board / shield 定義
+-- dts/...               # 任意の module content
+-- snippets/<name>/...   # 任意の module content
```

新規 repository は root `boards/` または外部 module を使います。legacy target の不足 metadata は
container 内だけで正規化し、host source は変更しません。明示 `-m` module は
[module metadata](#module-metadata)の宣言が必要です。

## Docker image

`ZMK_BUILD_IMAGE` は image 全体を上書きします。それ以外は repository / tag の環境変数を使います。
tag が `auto` の場合は `config/west.yml` 内の ZMK revision で選びます。

| ZMK revision | image tag |
| --- | --- |
| `main` / `master` / 未指定・未対応の revision | `stable` |
| patch / suffix を含む `v0.3` / `0.3` 系列 | `3.5-branch` |
| patch / suffix を含む `v4.1` / `4.1` 系列 | `4.1-branch` |

image 名は firmware toolchain を表します。host platform 対応は選択 image と Docker に依存し、必要なら
`ZMK_DOCKER_PLATFORM=linux/amd64` を指定します。local 検証を ARM64 native host や旧 image の
実 firmware build の確認として扱いません。

## コマンドと環境変数

```text
./build.sh <zmk-config-root> [--pristine] [--settings-reset] [--jobs N] [-S snippet] [-m module-dir]
./build.sh validate <zmk-config-root> [--pristine] [--settings-reset] [--jobs N] [-S snippet] [-m module-dir]
./build.sh clean
```

`validate` は選択した image 内で layout、module metadata、`build.yaml` を検証して target 一覧を表示します。
firmware は compile しません。build / validate とも、新しい run directory に `build.log` と
`build-summary.txt` を保存します。

### CLI option

| option | 意味 |
| --- | --- |
| `--pristine` | build / validate 前に選択した Docker cache volume 全体を削除します。firmware build では `west build -p` も使います。 |
| `--settings-reset` | `settings_reset` target を持たない board ごとに追加します。 |
| `-j N`, `--jobs N` | target を N 個ずつ build します（既定 1）。 |
| `-S NAME`, `--snippet NAME` | 全 target に snippet を追加します。複数指定できます。 |
| `-m DIR`, `--module DIR` | 明示 module を copy します。複数指定できます。 |
| `-h`, `--help`, `help` | usage を表示します。 |

並列数と retry 回数は正の十進整数で、`00` を含む全ゼロを拒否します。
同時実行の設定は[並列ビルド](#並列ビルド)を参照してください。

### 環境変数

| 環境変数 | 意味（既定値） |
| --- | --- |
| `ZMK_BUILD_IMAGE` | Docker image 全体の上書き。 |
| `ZMK_BUILD_IMAGE_REPOSITORY` | image repository（`zmkfirmware/zmk-build-arm`）。 |
| `ZMK_BUILD_IMAGE_TAG` | image tag（`auto`。[Docker image](#docker-image)参照）。 |
| `ZMK_DOCKER_PLATFORM` | 任意の Docker `--platform` 値。 |
| `ZMK_DOCKER_CACHE_VOLUME` | `/workspaces` に mount する volume（`zmk-cache`）。repository / tool ごとに分けます。 |
| `ZMK_CCACHE_DIR` | container 内の ccache directory（`/workspaces/.ccache`）。永続化する場合は cache volume 上に置きます。 |
| `ZMK_COPY_IGNORED` | `1` で Git が ignore する file も copy します。 |
| `ZMK_BUILD_JOBS` | `--jobs` の既定値（1）。 |
| `ZMK_WEST_UPDATE_ATTEMPTS` | `west update` の試行回数（3）。 |
| `ZMK_FALLBACK_BINARY` | `.uf2` の次に探す firmware 拡張子（`bin`）。 |
| `ZMK_EXTRA_MODULES` | 選択した application の extra module に足す、container から参照できる path。 |
| `ZMK_KEEP_CONTAINER` | `1` で run 後も build container を残します。 |
| `ZMK_CONTAINER_NAME` | 任意の build container 名。 |

## 並列ビルド

source process、各sourceのtarget、Ninjaによるcompileは、それぞれ別の並列数で動作します。

| 単位 | 設定 | 既定値 |
| --- | --- | --- |
| 一つのlocal wrapperから起動するsource | `--source-jobs N` / `ZMK_EXTERNAL_SOURCE_JOBS` | 1 source |
| 各source内のtarget | `--jobs N` / `ZMK_BUILD_JOBS` | 1 target |
| 一つのtarget内のcompile | Ninjaと選択したbuild環境 | build環境の既定値 |

### 一つのsource内のtarget

一つの `build.yaml` にあるentryを最大2件同時にbuildします。

```bash
bash build.sh ../your-zmk-config --jobs 2
```

targetごとにbuild directoryとlogを分離し、logはtarget順に回収します。
実行中のbatchが失敗した場合、後続の待機targetは開始しません。

### 複数source

[外部source wrapper](#外部source)から、最大2 sourceを同時にbuildします。
各source内のtargetは一つずつ処理します。

```bash
bash scripts/auto-build-external.sh --sources-file repos.txt --source-jobs 2 --jobs 1
```

wrapperがslugを一意化し、sourceごとのclone、cache、container、成果物を分離します。
空き枠には次のsourceを投入し、一つのsourceが失敗しても他のsourceは継続します。
別々のwrapper実行で、同じclone用slug・directoryを共有しないでください。

### 独立した実行とcacheの共有

別ターミナルから独立したbuildを起動するときは、cache volumeを分けます。

```bash
# Terminal 1
ZMK_DOCKER_CACHE_VOLUME=zmk-cache-a bash build.sh ../config-a

# Terminal 2
ZMK_DOCKER_CACHE_VOLUME=zmk-cache-b bash build.sh ../config-b
```

指定しない場合は両方とも既定の `zmk-cache` volumeを使います。
OS lockが、そのworkspaceの依存更新、overlay、中間file削除を保護します。
競合したbuildはworkspaceを変更する前に失敗し、自動で順番待ちはしません。
build processの終了時にlockが解放され、containerを保持していても再利用できます。
container名は既定で一意になります。`ZMK_CONTAINER_NAME` を指定する場合は、
同時に実行するrun間で異なる名前にしてください。

### CPUとmemory

`--source-jobs 2 --jobs 2` なら最大4 targetが同時にbuildされ、各target内では
Ninjaがさらにcompileを並列化します。これらのoptionは、container全体で共通の
CPU・memory上限を設定するものではありません。上の例では `--source-jobs 2 --jobs 1` を使っています。
cacheが冷えたbuildやmemoryの少ない環境では `--jobs 1` を保ち、必要に応じて `--source-jobs` も減らします。
CI matrixの並列数は[ワークフローとrunner](#ワークフローとrunner)を参照してください。

## ビルド設定

### target matrix

`build.yaml` は `include:` list または top-level の board / shield matrix を扱います。

```yaml
include:
  - board: nice_nano/nrf52840/zmk
    shield: corne_left nice_view_adapter
    snippet: studio-rpc-usb-uart
    artifact-name: example_corne_left
```

| target の key | 意味 |
| --- | --- |
| `board` | 必須。`west build -b` に渡す board。 |
| `shield` | 任意の `-DSHIELD=...`。 |
| `snippet` | 任意の `west build -S` 引数。 |
| `cmake-args` | 文字列は `shlex.split`、list は各値をそのまま 1 引数として扱います。空引数と引用符内 / list 値の空白を保持します。 |
| `extra-cmake-args` | `cmake-args` の後ろに追加する引数。 |
| `artifact-name` | 出力 base name。`{board}` / `{shield}` / `{snippet}` を使えます。 |
| `skip` | true ならその `include:` entry を除外します。 |

board / shield 配列は top-level と `include:` の両方で matrix に展開します。
`defaults:` は不足値を補い、`exclude:` は CLI snippet を合成する前の YAML 値で照合します。
`cmake_args` / `extra_cmake_args` / `artifact_name` の alias も扱います。
artifact 名は安全な file 名へ正規化し、拡張子つきも含む Windows 予約名と、大小文字を無視した重複を拒否します。

### 独立application

独立 Zephyr application は top-level に `application: app` を指定します。
相対 directory 内に `CMakeLists.txt` が必要で、symlink を含め repository 外へ出る path は拒否します。
manifest には `zephyr` という project が必要です。その workspace の Zephyr package を解決し、
extra module は `ZEPHYR_EXTRA_MODULES` へ渡します。省略時は `zmk/app` と ZMK 用の configuration /
`ZMK_EXTRA_MODULES` 引数を使います。必要な Zephyr 依存を含む image と、用途別の cache volume を選びます。
この mode でも target の board / DTS / snippet root を補完します。module の明示した build 宣言は保持し、
独立 application の CMake / Kconfig 入口から module の build 宣言を推定しません。

## モジュールとソースコピー

```bash
./build.sh ../your-zmk-config -m ../local-module -S local-snippet
```

各 `-m` directory を container 内へ copy します。解決済み path の basename は、空白も含めて一意にします。
west project 名と一致すれば依存解決後に local 版を overlay し、それ以外は extra module にします。
local module はすべて明示し、`local_modules/` は自動探索しません。

### module metadata

root content は `zephyr/module.yml` で宣言します。その module に必要な項目だけを含めます。

```yaml
build:
  cmake: .                 # root CMakeLists.txt
  kconfig: Kconfig         # root Kconfig
  settings:
    board_root: .          # root boards/
    dts_root: .            # root dts/
    snippet_root: .        # root snippets/
```

metadata は inline map / quoted key を含む YAML 構造として、persistent workspace 変更前に検証します。
`build.cmake` / `build.kconfig` に宣言する path は文字列にします。
build fileが `zephyr/` 配下だけにあるmoduleも、metadataを検証します。
`-m` で明示した隠し directory も同じ検証済み input 一覧に含め、内部の module path は NUL 区切りで渡します。

### source copy

Git working tree では tracked と ignore されない untracked file を copy します。
削除済み tracked file は除き、ignore に一致する tracked file は保持します。
`ZMK_COPY_IGNORED=1`、Git が使えない場合、一覧取得失敗・空一覧、非 working tree では、固定除外つきの全 copy に戻します。

常に `.git` / `.west` / `__pycache__` と、top-level の `.zmk` / `.build` / `.cache` / `.ccache` /
`.vscode` / `build` / `dist` / `node_modules` / `out` / `tmp` / `zmk_search` を除外します。
同名の nested directory は保持します。依存 tree は source に `.west` があり、その tree に `.git` marker が
ある場合だけ除外し、`modules` / `tools` などの名前だけでは通常 source を除外しません。

## 外部source

### source listとcommand

[repos.txt](repos.txt) は 1 行 1 URL または local path です。`repo:` / `url:` / `path:` prefix も使えます。
list 内の相対 path は list file の directory 基準です。`build.sh` は 1 repository、wrapper は
source 選択・slug の一意化・[source並列](#並列ビルド)を担当します。

```bash
bash scripts/auto-build-external.sh --list repos.txt
bash scripts/auto-build-external.sh --list-json repos.txt
bash scripts/build-external-source.sh --repo https://github.com/example/zmk-config.git
bash scripts/build-external-source.sh --path ../your-zmk-config --source-slug example
```

### wrapper option

| wrapper option | 意味 |
| --- | --- |
| `--repo URL`, `--path DIR` | source の種類を明示します。 |
| `--source-slug NAME`, `--repo-slug NAME` | source の slug を指定します。複数 source wrapper では `--repo` / `--path` の後ろに置きます。 |
| `--mode build\|validate` | build / validate を選びます。 |
| `--pristine`, `--settings-reset`, `-j` / `--jobs`, `-S` / `--snippet`, `-m` / `--module` | builder option を渡します。validate の pristine も含みます。 |
| `--source-jobs N` | `auto-build-external.sh` の source 並列数。target 並列とは別です。 |
| `--sources-file FILE`, `--repos-file FILE` | `auto-build-external.sh` の source list を指定します。 |
| `--list`, `--list-json` / `--matrix-json` | build せず解決済み source または JSON matrix を表示します。 |
| `--list-indices-json` | 公開 CI matrix 用に数値の source index だけを表示します。 |
| `--source-index N` | 一覧全体の解決後、1から始まる番号で1件を選択します。一意化した slug と元の JSON index を保持します。 |

### wrapperの環境変数

| wrapper 環境変数 | 既定値・用途 |
| --- | --- |
| `ZMK_EXTERNAL_MODE` | `build` |
| `ZMK_EXTERNAL_PRISTINE` | `0` |
| `ZMK_EXTERNAL_SETTINGS_RESET` | `0` |
| `ZMK_EXTERNAL_SOURCE_JOBS` | `1` |
| `ZMK_EXTERNAL_CACHE_PREFIX` | `zmk-cache-external`。source ごとの一意な slug を付けます。 |
| `ZMK_EXTERNAL_CLONE_IMAGE` | `zmkfirmware/zmk-build-arm:stable` |
| `ZMK_EXTERNAL_CLONE_ATTEMPTS` | `3` |
| `ZMK_EXTERNAL_SOURCE_BUILDER` | `scripts/build-external-source.sh`。複数 source wrapper が起動する worker。 |

### cloneと後片付け

URL clone は Docker 内で行い、bind mount を使わず `docker cp` で host へ戻すため、host Git は必須にしません。
Windows で作れない file 名は Windows host の場合だけ警告つきで除きます。
clone 削除は解決済み clone root の直下に限定し、削除失敗では source job を停止します。
clone directory / cache / container / artifact は source ごとに分離します。
worker が結果記録前に異常終了した場合も失敗として回収し、他 source は空き枠へ順次進めます。

## キャッシュと成果物

### workspaceと依存cache

sourceとapplicationごとに専用volumeを使います。
[独立した実行とcacheの共有](#独立した実行とcacheの共有)を参照してください。

container は west workspace を再利用し、そこへは `config/` だけを同期します。
ZMK は fresh な container source の `ZMK_CONFIG=/root/zmk-config/config` を使います。
依存の再利用判定は import を含む resolved manifest で行います。update の失敗・中断後は再試行し、
解決できない manifest を ready と記録しません。古い workspace root の整理は、overlay 復元後に
完全な project 一覧を取得できた場合だけ行います。復元失敗ではbuildを止め、backupと復旧記録を保持します。
overlay の復元完了は project ごとに記録してから backup を削除します。後続 project の失敗後も、
先に復元した project を削除せず再試行できます。既存の2列の復旧記録も扱います。

ccache は west workspace の外側、cache volume 上に保存します。`CCACHE_IGNOREOPTIONS=-specs=*` は
選択 image 内の SDK specs が固定される前提です。image / SDK 変更時は別 cache または `--pristine` を使います。

### 保持と削除

| データ | 保持と削除 |
| --- | --- |
| target ごとの中間 build directory | 成功時、compile 失敗時、firmware 選択 / copy 失敗時に削除します。`ZMK_KEEP_CONTAINER=1` でも同じです。 |
| build / clone container | 使用後に削除します。`ZMK_KEEP_CONTAINER=1` は build container だけを保持します。操作には Docker が返す固定 ID を使います。 |
| 依存と ccache | 専用 volume で再利用します。`--pristine` は ccache を含む対象 volume 全体を削除します。 |
| URL clone の host 側コピー | source の成功報告前に削除します。local path の source は保持します。 |
| host の firmware / log / 検証記録 | この tool の `.build/` に保持します。`./build.sh clean` は `.gitkeep` 以外をすべて削除します。 |

削除失敗は該当 target / run / source job を失敗にします。`build.sh` は先の build error の理由と終了 status を保持します。
外部 wrapper は source の失敗を非ゼロ status で通知し、clone / build failure と削除失敗を併記します。
`--pristine` の volume 一覧取得・削除失敗では container 作成前に停止します。
validate に指定した場合も cache を初期化します。
file 削除は WSL の memory cache を Windows へ強制返却する処理ではなく、memory 回収は host OS が担当します。

### 中断時の動作

実行中の SIGINT / SIGTERM では中断理由を含む FAILED run を確定します。保持指定の container は中断時に停止し、
ID と log を確認できる状態で残します。
container 作成中（image の自動 pull を含む）は中断を遅延し、process group 全体への signal でも ID を回収してから終了します。
中断を繰り返しても、識別前の container を放置しません。終了 handler の入口から cleanup 完了まで中断を遅延します。
先の build error があれば理由と終了 status を保持し、それ以外の中断は FAILED summary にします。
最終 summary は cleanup 後に atomic に公開します。この時点で結果を確定するため、summary 公開中の遅い signal は
終了 status を変更しません。成功判定には command の終了 status がゼロであることと、output check の成功の両方が必要です。

### firmwareと成果物確認

host に戻す firmware は target ごとに 1 個です。選択順は `.uf2`、`ZMK_FALLBACK_BINARY`、`.hex`、`.bin`。
fallback 拡張子は先頭 dot を付けず、英数字 / dot / underscore / hyphen を使います。
path / glob と先頭 dot / hyphen は拒否します。CI は後述の公開用 report を upload し、
firmware と raw log は local の `.build/` に保持します。

```text
.build/run-YYYY-MM-DD_HH-MM-SS-pid-PID/
+-- example_corne_left.uf2
+-- build.log
+-- build-summary.txt
```

開始済み run は setup、source copy、成果物回収、container 削除の失敗にも FAILED summary と error excerpt を残します。
build 出力は container の log stream にも流れ、保持した container は `docker logs <container>` で確認できます。
特定 run の成果物確認は次のように実行します。

```bash
bash .github/scripts/check-build-output.sh build .build/run-YYYY-MM-DD_HH-MM-SS-pid-PID
```

validate の結果は `build` を `validate` に置き換えます。両 mode とも、成功 status と一致する mode を持つ summary、
および log file が必要です。build の確認では、さらに正の target 数と build target 数・firmware 数の完全一致を要求します。
相対run pathは呼び出し元のdirectoryを基準に解決し、省略時はそのdirectoryの `.build/` を探します。
別の directory から確認するときは run path を指定します。
run 名は上記の規則に従います。
fallback は summary に記録し、記録のない旧 summary は `bin` と解釈します。

## ワークフローとrunner

| workflow | 用途 |
| --- | --- |
| [Compatibility](.github/workflows/compatibility.yml) | Windows / macOS / Linux の hosted shell、Ubuntu の Docker / firmware 検証。 |
| [Self-hosted Build](.github/workflows/self-hosted-build.yml) | 手動の `platform: macos\|windows\|linux\|all`、`mode: validate\|build`。validate は shell / Docker、build は firmware も確認します。 |
| [Auto Build External ZMK Repos](.github/workflows/auto-build.yml) | Ubuntu で list を解決し、source ごとに利用可能な self-hosted runner へ割り当てます。 |
| [Heartbeat](.github/workflows/heartbeat.yml) | 追跡中の heartbeat 記録を更新します。commit / push を含む workflow です。 |

### runnerの登録

repository の Settings → Actions → Runners から、GitHub が表示する package / 登録 command で登録します。
既定の `self-hosted` と OS label（`macOS` / `Windows` / `Linux`）を保持し、runner user で Docker access を
確認してから `zmk-docker` と `zmk-docker-active` を追加します。

runner user で `bash .github/scripts/check-runner-tools.sh` と「保守と検証」を実行します。
Windows step は標準 install path の Git Bash を明示します。Docker Desktop は同じ account / session で使えることを
確認します。Linux は sudo 無しの daemon access が必要で、group 変更後は login / service を更新します。
self-hosted runner は信頼できる workflow に限定します。

### scheduleと並列数

外部 matrix は `runner.os` で Bash / Git Bash と artifact 名を選びます。
`source_jobs` は matrix 並列数（既定 4）、`build_jobs` は target 並列数（既定 1）です。
schedule は同じ既定値で pristine build を行います。cron は UTC、JST 換算は workflow comment に記載し、
concurrency / timeout で重複実行を制限します。利用可能な online runner がなければ queue に残ります。
online / busy / label / 登録先を確認し、外部 job から除外する場合は `zmk-docker-active` を外すか runner を止めます。

### 公開レポートとCI helper

CI の自動 upload は `.build/public/` の固定項目の text report に限定し、command の結果と既知の test status を記録します。
raw な環境情報、path、source label、runner 名、log、firmware は自動 upload しません。
外部 job の公開名には source の数値 index を使います。report は raw evidence と別の公開用コピーです。
hosted runner の raw evidence は一時的で、job の削除後は残りません。詳細な診断には local での再現、
または別途内容を確認した private な取得が必要です。

CI は `bash .github/scripts/check-build-output.sh ci-tests <mode>` から[共通の検証入口](#保守と検証)を実行し、
詳細な console 出力を実行ごとの新しい `.build/ci-execution.XXXXXX/` に保存します。
外部 build には `ci-tools`、`ci-lf`、`ci-syntax`、`ci-source <wrapper arguments>`、
`ci-check build|validate` を使います。job の開始時に
`publish clear` で既知の report file を初期化し、`publish verify` で最終 payload を検査します。
両方の成功時だけ upload します。

各 test 実行も report を生成します。
再生成には `publish tests-shell|tests-docker|tests-build|tests-all EXIT RAW_DIRECTORY`、
外部 command の結果には `publish build|validate EXIT` を使い、終了 status と既知の case 名 / status だけをコピーします。

外部 CI は `ci-matrix` と `ci-source-index N` を使い、workflow event から実行時に準備する非公開の
`.build/ci-source-file` を読みます。selector は常に list file として扱い、不足する list は matrix 解決時に失敗させます。
CI helper は呼び出し元の directory にかかわらず、この repository の root を基準に実行します。
matrix と step の環境変数には数値 index だけを渡し、source の path / URL / slug は
runner 自身の事前表示にも command 出力にも含めません。selector の準備には `actions/github-script` に付属する Node runtime を使い、
local CLI の host 必須依存は増やしません。

## 保守と検証

変更前に [AGENTS.ja.md](AGENTS.ja.md)（[英語の正本](AGENTS.md)） を確認します。local / CI は共通の入口を使います。

```bash
bash .github/scripts/test.sh shell
bash .github/scripts/test.sh docker
bash .github/scripts/test.sh build
bash .github/scripts/test.sh all
```

### 検証の層

| 層 | 確認範囲 |
| --- | --- |
| `shell` | Bash 構文、LF / checkout、空白、成果物判定、source queue / 失敗、host guard / help。この検証層には Git が必要です。 |
| `docker` | 実 source copy、metadata、production parser、workspace / update / overlay の制御した失敗、cleanup、ccache hit、Windows clone の copy back、外部 workflow の引数転送。image 内の Python / PyYAML を使います。 |
| `build` | [標準 firmware](.github/fixtures/ci-zmk-config/build.yaml)、[project overlay](.github/fixtures/module-override-zmk-config/build.yaml)、extra module、pristine 無しの復元、root snippet を使う独立 application、成果物数と依存 identity。 |
| `all` | `shell`、`docker`、`build` の各層をこの順に実行します。 |

validate 専用の [target-shape fixture](.github/fixtures/target-shapes-zmk-config/build.yaml) は
matrix / defaults / exclude / alias / placeholder / reset 重複回避を確認します。
fixture は代表 board / output の検証であり、upstream の全 board を網羅しません。

### 検証記録とtest cache

実行ごとに新しい `.build/test-<UTC>-pid-<PID>/` へ command、raw log、結果と時間、image identity、
実行前後の source checksum を保存します。`ZMK_TEST_RESULTS` で repository 外、または directory 全体を
Git が ignore する新しい保存先を選べます。既存記録は上書きしません。
`.gitattributes` / `.editorconfig` の UTF-8 / LF を使い、検証のために working tree を書き換えません。

test cache は既定で専用 volume を作り、終了時に削除します。`ZMK_DOCKER_CACHE_VOLUME` を明示した場合は
再利用・保持します。production cache は指定しません。`ZMK_TEST_PRISTINE=1` は標準 build 前だけ初期化し、
復元検証では保持します。各 build / validate の直後に、その run を明示して output check を実行します。
local / remote CI / host platform / 実機の結果は分けて報告し、公開操作は user の明示指示がある場合だけ行います。
