# ZMK Build Script

[English README](README.md)

現在の ZMK keyboard repository layout だけを扱う、小さい Docker + Bash build helper です。

利用手順と runner 運用はこの README、保守契約は [AGENTS.md](AGENTS.md) に集約しています。
入口の layout は次のとおりです。

```text
your-zmk-config/
+-- build.yaml
+-- config/
|   +-- west.yml
|   +-- <keyboard>.conf
|   +-- <keyboard>.keymap
|   +-- boards/...        # 旧 compatibility path。新規 repo では使わない
+-- zephyr/
|   +-- module.yml        # 任意。module metadata
+-- boards/...            # 標準の user/module board と shield 定義
+-- dts/...               # 任意。build.settings.dts_root: . が必須
+-- snippets/<name>/...   # 任意。build.settings.snippet_root: . が必須
```

`config/boards` は ZMK が今も検索する compatibility path なので拒否しませんが、新規 repo は
root の `boards/` または外部 module を使ってください。新規 repo は module root を
`zephyr/module.yml` で宣言してください。明示 `-m` は strict に検証します。target repo の不足 metadata と
legacy root `module.yml` は container 内だけで正規化し、host source は変更しません。

## 大きな特徴

- cross-platform host flow: Windows、macOS、Linux で同じ Docker + Bash entrypoint を使います。
- host CPU independent: AMD64/x86_64 host でも ARM64 host でも Docker 経由で動きます。`zmk-build-arm` の `arm` は firmware toolchain の意味で、host CPU の条件ではありません。
- explicit module override: 各 `-m <dir>` で、同名 west project の overlay と extra ZMK module 追加の両方に対応します。`local_modules/` は無視します。
- persistent west workspace: dependency は run 間で再利用し、target config は毎回 fresh に copy します。
- safe overlay restore: 明示 module input の west project override は backup して、次回 build で復元します。
- 再 build の高速化: compiler cache（ccache）を cache volume に永続化し、Git の working tree では Git が表示する file だけを container に copy するため、大きな ignore 済み directory が copy を遅くしません。
- target parallel build: `--jobs N` / `ZMK_BUILD_JOBS=N` で `build.yaml` target を並列 build できます。外部 repo の full/pristine workflow では、target 並列と Ninja 内部の compile 並列が重なりすぎないように既定を 1 にします。
- target ごとに artifact 1 個: `.uf2` を優先し、`.bin` / `.hex` fallback も扱います。
- CI coverage: ZMK 4.1 HWMv2 の代表 board、target shape parser、明示的な module override path を確認します。

## 必要なもの

- Docker Desktop または Docker Engine
- Bash

Windows では Git Bash を使ってください。標準的な Unix tool が使える Bash 環境を前提にします。

## 最初の実行

Docker の Linux engine を起動し、Windows / macOS / Linux の Bash から実行します。

```bash
./build.sh validate ../your-zmk-config
./build.sh ../your-zmk-config
```

Windows は Git for Windows を入れ、PowerShell からは Git Bash を明示します。

```powershell
& 'C:\Program Files\Git\bin\bash.exe' ./build.sh ../your-zmk-config
```

AMD64/x86_64 と ARM64 で入口は同じです。image 名は firmware toolchain の意味です。
Docker が platform を選べない場合は `ZMK_DOCKER_PLATFORM=linux/amd64` を指定します。
複数 repo を同時 build する場合は cache volume を分けてください。

### cache と log

compiler cache（ccache）は同じ volume の `/workspaces/.ccache` に保存します（`ZMK_CCACHE_DIR` で変更可能）。使い捨ての build container が消えても、再利用可能な compile 結果は残ります。`CCACHE_IGNOREOPTIONS=-specs=*` は SDK の specs file 探索による cache miss を避けるための設定です。SDK は選択した Docker image に含まれるため、image / SDK を変更する場合は別の cache または `--pristine` を使ってください。`--pristine` は west workspace と compiler cache の両方を削除します。

build 中の出力は host terminal の `build.log` だけでなく、build container の log stream にも
流します。`ZMK_KEEP_CONTAINER=1` を指定すると、失敗後に `docker logs -f <container>` や
Docker Desktop から同じ stream を確認できます。

## build

```bash
./build.sh ../your-zmk-config --pristine
```

`build.yaml` に複数 target がある場合は、target ごとに build directory を分けて並列 build できます。

```bash
./build.sh ../your-zmk-config --pristine --jobs 2
ZMK_BUILD_JOBS=2 ./build.sh ../your-zmk-config --pristine
```

`--jobs` は target-level の並列数だけを制御します。各 target 内ではそれぞれ
`west build` が走り、Ninja がさらに compile を並列化する場合があります。cache が冷えた
`--pristine` build や小さい runner では `--jobs 1` を使ってください。

target repository には `include:` list または top-level matrix を持つ `build.yaml` が必要です。

```yaml
include:
  - board: nice_nano/nrf52840/zmk
    shield: corne_left nice_view_adapter
    snippet: studio-rpc-usb-uart
    artifact-name: example_corne_left
```

対応する key:

| Key | 意味 |
| --- | --- |
| `board` | 必須。`west build -b` に渡します。 |
| `shield` | 任意。`-DSHIELD=...` に渡します。 |
| `snippet` | 任意。`west build -S` に渡します。 |
| `cmake-args` | 任意。`shlex.split` で分割します。 |
| `extra-cmake-args` | 任意。`cmake-args` の後ろに追加します。 |
| `artifact-name` | 任意。出力 base name です。 |
| `skip` | 任意。`include:` entry で true の場合、その target を無視します。 |

top-level の `board:` / `shield:` 配列は matrix として展開します。`include:` entry 内でも
board / shield 配列を使えます。`exclude:` は生成後の target を除外し、`defaults:` は不足値を補います。
`artifact-name` では `{board}`、`{shield}`、`{snippet}` placeholder を使えます。

host 側へコピーする firmware は target ごとに 1 個だけです。優先順は `.uf2`、`ZMK_FALLBACK_BINARY`、`.hex`、`.bin` です。

成果物はここに保存します。

```text
.build/
+-- run-YYYY-MM-DD_HH-MM-SS-pid-PID/
    +-- example_corne_left.uf2
    +-- build.log
    +-- build-summary.txt
```

run directory 名は output contract の一部で、`run-YYYY-MM-DD_HH-MM-SS-pid-PID` に従います。
output check はこの命名規則に合う run directory を sort し、
規則外の場所に `build-summary.txt` がある場合は失敗します。

## option と環境変数

```text
./build.sh <zmk-config-root> [--pristine] [--settings-reset] [--jobs N] [-S snippet] [-m module-dir]
./build.sh validate <zmk-config-root> [--settings-reset] [--jobs N] [-S snippet] [-m module-dir]
./build.sh clean
```

| option | 意味 |
| --- | --- |
| `--pristine` | `west build -p` で build し、先に Docker の cache volume 全体を削除します。compiler cache もその volume にあるため一緒に消えます。 |
| `--settings-reset` | `settings_reset` target を持たない board ごとに追加します。 |
| `--jobs N` | `build.yaml` の target を N 個ずつ build します（既定 1）。 |
| `-S snippet` | 全 target に snippet を追加します。 |
| `-m module-dir` | module を追加します（「explicit module」参照）。複数指定できます。 |

| 環境変数 | 意味（既定値） |
| --- | --- |
| `ZMK_BUILD_IMAGE` | image 全体の上書き。 |
| `ZMK_BUILD_IMAGE_REPOSITORY` | image repository（`zmkfirmware/zmk-build-arm`）。 |
| `ZMK_BUILD_IMAGE_TAG` | image tag（`auto`。「Docker image」参照）。 |
| `ZMK_DOCKER_PLATFORM` | Docker の `--platform` 値。 |
| `ZMK_DOCKER_CACHE_VOLUME` | `/workspaces` に mount する volume（`zmk-cache`）。 |
| `ZMK_CCACHE_DIR` | container 内の ccache directory（`/workspaces/.ccache`）。 |
| `ZMK_COPY_IGNORED` | `1` で Git が ignore する file も copy します。 |
| `ZMK_BUILD_JOBS` | `--jobs` と同じ（1）。 |
| `ZMK_WEST_UPDATE_ATTEMPTS` | `west update` の試行回数（3）。 |
| `ZMK_FALLBACK_BINARY` | `.uf2` の次に探す firmware 拡張子（`bin`）。 |
| `ZMK_EXTRA_MODULES` | container の `ZMK_EXTRA_MODULES` に足す module path。 |
| `ZMK_KEEP_CONTAINER` | `1` で run 後も build container を残します。 |
| `ZMK_CONTAINER_NAME` | container 名。 |

persistent west workspace は毎回 prune され、manifest に載っていない top-level の entry は削除されます。
同じ Docker image を使う tool や repository ごとに、別の `ZMK_DOCKER_CACHE_VOLUME` を使ってください。

## validate

```bash
./build.sh validate ../your-zmk-config
```

ZMK Docker image 内で `build.yaml` を parse して target list を表示します。`.build/` には `build.log` と `build-summary.txt` を保存します。

`--settings-reset` を付けると、まだ `settings_reset` target がない board ごとに
reset target を追加します。

```bash
./build.sh validate ../your-zmk-config --settings-reset
```

## CI の確認範囲

CI fixture は ZMK 4.1 HWMv2 の代表 board として次の 2 つを重点的に確認します。

- `nice_nano/nrf52840/zmk`
- `xiao_ble/nrf52840/zmk`

両方の board で `settings_reset` を build します。`nice_nano` 側では Corne left/right と、
snippet、複数 shield、CMake argument を含む重めの target を確認します。`xiao_ble` 側では
XIAO 向けの `tester_xiao` shield を確認します。これにより build script の board、shield、
snippet、CMake argument、settings reset、artifact 回収 path を確認します。upstream の全 ZMK board を
網羅的に build するものではありません。

target 形状の parse は validate 専用の `.github/fixtures/target-shapes-zmk-config` で確認します。
top-level matrix、include matrix、`defaults`、`exclude`、`skip`、alias key、placeholder、
`--settings-reset` の重複回避を、firmware build target を増やさずに確認します。

明示 module input の west project override は `.github/fixtures/module-override-zmk-config` で確認します。
CI では cache 済みの `zmk-studio-messages` と `zcbor` west project を host 側に copy し、
両方を `-m` で渡します。同時に別の extra module も `-m` で渡し、
`Overlaying module input west project` と `Adding module input as extra module` の両方を assert したうえで
Studio 有効の `.bin` target と settings-reset の `.hex` target を build します。
この target は studio を有効にし、`proto/zmk` のような入れ子 path も copy されることを確認します。
次の build では記録された overlay project 群を workspace 内 backup から復元し、Docker volume 全体は
reset しません。

## snippet 追加

```bash
./build.sh ../your-zmk-config -S zmk-usb-logging
```

追加 snippet は全 target に付与されます。

root snippet は Zephyr module の規則に合わせます。repo root の `snippets/` に置き、
`zephyr/module.yml` で root を宣言してください。

```yaml
build:
  settings:
    snippet_root: .
```

## explicit module

```bash
./build.sh ../your-zmk-config -m ../local-module
```

`-m` で渡した module は Docker 内へ copy します。directory name が west project name と一致する場合は `west update` 後にその project を local 版で上書きします。一致しない場合は `ZMK_EXTRA_MODULES` として ZMK に渡します。すべての module は `-m` で明示し、この tool の `local_modules/` は使用しません。

generated west project directory は copy 元ごとに除外するため、cache 済み dependency を避けつつ、通常 module の意図した content は保持します。

target や `-m` の directory が Git working tree で `git` が使える場合は、Git が表示する file だけを copy します。tracked file と、`.gitignore` に一致しない untracked file です。`artifacts/` や `web/node_modules/` のような ignore 済みの大きな directory は host に残ります。それ以外は丸ごと copy します。ignore 済み file も copy するには `ZMK_COPY_IGNORED=1` を指定します。

## clean

```bash
./build.sh clean
```

`.build/.gitkeep` を残して generated build output を削除します。

## self-hosted runner

通常の互換性 gate は hosted `Compatibility` です。手動の `Self-hosted Build` は自分の machine で標準 fixture を
確認する Docker smoke test です。`platform` は `macos` / `windows` / `linux` / `all`、`mode` は `validate` / `build`。
online runner 1 台で validate、次に build を確認し、全 OS が使える場合に `all` を使います。

repository の Settings → Actions → Runners → New self-hosted runner で、GitHub が表示する最新の package / token /
登録 command を使います。既定 OS label を保持し、runner user で Docker が動くことを確認してから custom label を付けます。

| host | labels |
| --- | --- |
| macOS | `self-hosted`, `macOS`, `zmk-docker`, `zmk-docker-active` |
| Windows | `self-hosted`, `Windows`, `zmk-docker`, `zmk-docker-active` |
| Linux | `self-hosted`, `Linux`, `zmk-docker`, `zmk-docker-active` |

runner user で `bash .github/scripts/check-runner-tools.sh` と「保守と検証」の共通確認を実行します。
Windows は標準 install path の Git Bash を使います。Docker Desktop は同じ account / session からの利用を確認してから
runner を service 化します。Linux は sudo 無しの daemon access が必要で、docker group 変更後は再 login または runner 再起動が必要です。

信頼できる workflow だけを self-hosted runner で動かしてください。外部 build から host を外す場合は `zmk-docker-active` を外すか
runner を止めます。queued のままなら online / busy / 登録先 / label を確認します。Terminal で動き Actions で失敗する場合は
account と session を比較します。tar exclude が無い場合は通常の Bash tool と PATH を確認します。
output check は成功 status / mode / log / summary と target ごとに 1 個の firmware を確認して upload します。

## Docker image

既定の tag mode は `auto` です。`auto` では `config/west.yml` を読み、
`zmk` project の `revision` から Docker image tag を選びます。

- `main`、`master`、または不明な revision -> `stable`
- `v0.3` / `0.3` / `v0.3-*` / `0.3-*` -> `3.5-branch`
- `v4.1` / `4.1` / `v4.1-*` / `4.1-*` -> `4.1-branch`

現在の ZMK `main` では次に解決されます。

```text
zmkfirmware/zmk-build-arm:stable
```

明示 override は常に優先されます。

```bash
ZMK_BUILD_IMAGE=zmkfirmware/zmk-build-arm:stable ./build.sh ../your-zmk-config
ZMK_BUILD_IMAGE_TAG=4.1-branch ./build.sh ../your-zmk-config
ZMK_DOCKER_PLATFORM=linux/amd64 ./build.sh ../your-zmk-config
ZMK_DOCKER_CACHE_VOLUME=zmk-cache-my-keyboard ./build.sh ../your-zmk-config
ZMK_BUILD_JOBS=2 ./build.sh ../your-zmk-config
ZMK_WEST_UPDATE_ATTEMPTS=5 ./build.sh ../your-zmk-config
ZMK_EXTERNAL_CLONE_ATTEMPTS=5 bash ./scripts/build-external-source.sh --repo https://github.com/example/zmk-config.git
```

## 外部 repo の自動 build

`repos.txt` に 1 行 1 source で ZMK config repository の URL または local path を並べると、
`Auto Build External ZMK Repos` workflow が source ごとの matrix job を実行します。
`build.sh` は常に 1 target directory だけを扱い、複数 source の並列化は
`scripts/auto-build-external.sh` または GitHub Actions の job matrix で行います。
各 source job は `scripts/build-external-source.sh` から 1 つの `build.sh` process を起動し、
slug ごとに clone directory、Docker cache volume、container name、artifact upload を分けます。
URL source の clone も Docker container 内で行い、host へは `docker cp` で戻すため、
host 側の追加必須依存は増やしません。URL clone は既定で 3 回 retry します。
回数は `ZMK_EXTERNAL_CLONE_ATTEMPTS=N` で調整できます。
source list では
`repo:<url>` / `path:<dir>` prefix も使えます。relative path は list file の場所からの
相対 path として扱います。local で複数 source を回す場合、`--source-jobs N` /
`ZMK_EXTERNAL_SOURCE_JOBS=N` で同時に動かせる source process 数を制御します。
wrapper は source が終わり次第、空いた枠へ次の source を流します。`--jobs N` は
各 source 内の target 並列数のままです。外部 repo の full/pristine build では、
GitHub workflow の `build_jobs` 既定値と scheduled run の fallback は 1 です。
runner の CPU / memory に十分な余裕がある場合だけ手動で上げてください。

```bash
bash ./scripts/auto-build-external.sh repos.txt --source-jobs 2 --jobs 2 --pristine
bash ./scripts/build-external-source.sh --repo https://github.com/example/zmk-config.git --jobs 2
bash ./scripts/build-external-source.sh --path ../your-zmk-config --source-slug your-zmk-config
```

GitHub Actions 側では build job と artifact 名で失敗箇所を追えます。local で
複数 source を回す場合も、wrapper は source ごとに別 script process を起動するだけ
なので、`build.sh` 自体は単体 build の log stream を保ちます。定期実行は GitHub Actions
の仕様に合わせて UTC cron で書き、workflow コメントに JST 換算時刻を残します。
auto build workflow は 2 つの job で構成します。

1. **sources** (`ubuntu-latest`): `auto-build-external.sh --list-json` で
   `repos.txt` を JSON matrix に変換し `job outputs` で次 job へ渡します。
2. **build** (source ごとの matrix job): 各 source を独立した job として
   `runs-on: [self-hosted, zmk-docker, zmk-docker-active]` で
   `build-external-source.sh` を実行します。

GitHub Actions の label routing が build matrix job を両 custom label を持つ
online runner に割り当てます。複数の idle runner が別々の source を並列に
pick up できます。OS は workflow 側で pin せず、選ばれた runner の OS は
`runner.os` で取得し、shell 分岐 (Windows は Git Bash、macOS / Linux は Bash) と
artifact 名の付与に利用します。手動 workflow run の `source_jobs` は
`strategy.max-parallel` に渡され、同時に走る source matrix job 数の上限になります
(scheduled run の既定は 4)。手動 workflow run の `build_jobs` は各 source job 内の
target-level 並列数で、full/pristine 安定性のため既定は 1 です。該当 runner がすべて
offline の場合は job が queue に残ります。`concurrency` の
`cancel-in-progress: true` で、stale な queued job の上に新しい scheduled run が
積もらないようにします。特定 host を offload したい場合は、その runner から
`zmk-docker-active` label を外すか、runner を停止してください。

## script の流れ

1. target repo を Docker 内の `/root/zmk-config` へ copy（Git の working tree では Git が表示する file だけ。「explicit module」参照）
2. top-level の `.cache`、`.ccache`、`.vscode`、`build`、`dist`、`node_modules`、`out`、`tmp`、`zmk_search` などの local/generated directory は copy しない
3. root module content があり `module.yml` だけがある legacy repo では、container 内だけで一時的な `zephyr/module.yml` に正規化する
4. persistent west workspace へは `config/` だけ copy
5. `ZMK_CONFIG=/root/zmk-config/config` で build し、ZMK が `config/boards` と root `boards` の両方を見られるようにする
6. `zephyr/module.yml` がある場合は `/root/zmk-config` を `ZMK_EXTRA_MODULES` に渡す
7. 前回の overlay を復元し、workspace の状態から `west update` の必要性を判定
8. dependency 解決後に今回の明示 module override を適用
9. `build.yaml` から生成した各 target を、必要なら target ごとの build directory で並列 build（cache volume 上の compiler cache を使用）
10. target ごとに firmware artifact 1 個だけを `.build/` へ copy
11. `build.log` と `build-summary.txt` を保存し、失敗時は summary に error excerpt を残す

## 保守と検証

`build.sh` は 1 config の copy / workspace / output、`scripts/auto-build-external.sh` は source list / JSON matrix /
slug / 上限つき queue、`scripts/build-external-source.sh` は 1 source の clone / path 選択と builder 起動を担当します。
fixture と behavior check は `.github/` に置き、変更前に [AGENTS.md](AGENTS.md) を確認します。

external wrapper も `--mode build|validate`、`--pristine`、`--settings-reset`、複数の `-S` / `-m` を扱います。既定値は次のとおりです。

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

local と CI で同じ入口を使います。

```bash
bash .github/scripts/test.sh shell
bash .github/scripts/test.sh docker
bash .github/scripts/test.sh build
# すべて順番に実行する場合:
bash .github/scripts/test.sh all
```

| 層 | 確認する契約 |
| --- | --- |
| `shell` | Bash 構文、LF と実際の Git checkout、空白、成果物判定、source list / queue / 失敗、host guard / help |
| `docker` | 実際の host copy、Git ignore / opt-out、generated dependency、metadata 正規化、parser の順序と不正 schema、ccache hit、Windows clone 名の除去と copy back |
| `build` | 標準 firmware、明示 project overlay と extra module、pristine 無しの復元、成果物の厳密な数と依存 identity |

実行ごとに新しい `.build/test-<UTC>-pid-<PID>/` を作り、command、順序を保持した raw log、case ごとの結果と時間、
実行前後の source checksum を残します。既存記録は上書きしません。`ZMK_TEST_RESULTS` で新しい保存先、
`ZMK_DOCKER_CACHE_VOLUME` で専用の再利用 cache を指定できます。既定は新しい cache 名で、実行後に削除します。明示指定した cache は保持します。
`ZMK_TEST_PRISTINE=1` は標準 build 前にその cache を初期化します。復元検証は必ず cache を保持します。
共有 production cache は指定しません。Python / PyYAML は image 内のものを使い、host への追加 install は不要です。
output checker には各 run の保存先を明示するため、並行実行で検証対象が入れ替わりません。

shell 検証には Git が必要です。production builder の Git は引き続き optional です。
`.gitattributes` と `.editorconfig` で UTF-8 / LF を統一します。LF checker は Windows の text 変換を避けて読み、
tracked と visible untracked text の CR を拒否します。ignored output と binary は保持し、CI でも working tree を reset しません。

並列数 / retry 回数は正の十進整数で、`00` も拒否します。worker の異常終了は失敗として回収し、後続 source を進めます。
開始済み run は host setup failure にも log / summary を残し、cleanup は自分が作成した container だけを対象にします。

output check は正の target 数と target ごとに 1 個の firmware を要求します。fallback は summary に記録し、旧 summary は `bin` と解釈します。
拡張子は先頭 dot を付けず英数字 / dot / underscore / hyphen のみです。path / glob と先頭 dot / hyphen を拒否します。
workflow upload は `.uf2` / `.hex` / `.bin` が対象なので、別形式では pattern を追加してください。
明示 module の root content に応じて `build.cmake` / `build.kconfig` / `build.settings.*_root` の宣言が必要です。

local check と remote workflow の結果は分け、変更は明示指示まで local に保持します。

module metadata は Docker 内で YAML 構造として検証し、inline map も受け入れます。Windows の予約 artifact 名は、拡張子が続く場合も拒否します。
