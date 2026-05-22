# ZMK Build Script

現在の ZMK keyboard repository layout だけを扱う、小さい Docker + Bash build helper です。

対応する layout はこれだけです。

```text
your-zmk-config/
+-- build.yaml
+-- config/
|   +-- west.yml
|   +-- <keyboard>.conf
|   +-- <keyboard>.keymap
|   +-- boards/...        # ZMK config compatibility path として許可
+-- zephyr/
|   +-- module.yml        # 任意。module metadata
+-- boards/...            # 任意。module/user board と shield 定義
+-- dts/...               # 任意。build.settings.dts_root: . が必須
+-- snippets/<name>/...   # 任意。build.settings.snippet_root: . が必須
```

`config/boards` は ZMK が今も検索する compatibility path なので拒否しません。root の
`dts/` や `snippets/` は `zephyr/module.yml` の settings で宣言されている必要があります。

## 大きな特徴

- cross-platform host flow: Windows、macOS、Linux で同じ Docker + Bash entrypoint を使います。
- host CPU independent: AMD64/x86_64 host でも ARM64 host でも Docker 経由で動きます。`zmk-build-arm` の `arm` は firmware toolchain の意味で、host CPU の条件ではありません。
- local module override: `-m <dir>` と `local_modules/` で、同名 west project の overlay と extra ZMK module 追加の両方に対応します。
- persistent west workspace: dependency は run 間で再利用し、target config は毎回 fresh に copy します。
- safe overlay restore: local west project override は backup して、次回 build で復元します。
- target ごとに artifact 1 個: `.uf2` を優先し、`.bin` / `.hex` fallback も扱います。
- CI coverage: ZMK 4.1 HWMv2 の代表 board、target shape parser、複数 local module override path を確認します。

## 必要なもの

- Docker Desktop または Docker Engine
- Bash

Windows では Git Bash を使ってください。標準的な Unix tool が使える Bash 環境を前提にします。

## Windows / macOS / Linux での使い方

Docker が起動していて、コマンドを Bash で実行できれば、同じ script を 3 OS で使えます。

host CPU architecture は通常 script の利用条件には含めません。AMD64/x86_64 host でも
ARM64 host でも、Docker 経由で同じ command を実行します。`zmk-build-arm` の `arm` は
ZMK board 向け ARM firmware toolchain の意味で、host machine が ARM である必要はありません。

Docker が image platform を自動選択できない場合や、ARM64 host で amd64 image を使いたい場合は
次のように指定できます。

```bash
ZMK_DOCKER_PLATFORM=linux/amd64 ./build.sh ../your-zmk-config --pristine
```

### Windows

1. Docker Desktop と Git for Windows を入れます。
2. Docker Desktop を起動し、Linux engine が使える状態まで待ちます。
3. Git Bash から実行します。

```bash
./build.sh ../your-zmk-config --pristine
```

PowerShell から起動する場合は、`bash` が WSL に解決されることを避けるため Git Bash を明示します。

```powershell
& 'C:\Program Files\Git\bin\bash.exe' ./build.sh ../your-zmk-config --pristine
```

### macOS

1. Docker Desktop または Docker Engine を入れます。
2. Docker を起動します。
3. Terminal から実行します。

```bash
./build.sh ../your-zmk-config --pristine
```

### Linux

1. Docker Engine または Docker Desktop を入れます。
2. user shell から `docker ps` が通る状態にします。
3. Bash から実行します。

```bash
./build.sh ../your-zmk-config --pristine
```

## build

```bash
./build.sh ../your-zmk-config --pristine
```

target repository には `include:` list を持つ `build.yaml` が必要です。

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
.build/run-YYYY-MM-DD_HH-MM-SS-pid-PID/
+-- example_corne_left.uf2
+-- build.log
+-- build-summary.txt
```

例: `.build/run-2026-05-21_20-50-31-pid-1234/`

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

local west project override は `.github/fixtures/module-override-zmk-config` で確認します。
CI では cache 済みの `zmk-studio-messages` と `zcbor` west project を host 側に copy し、
両方を `-m` で渡します。同時に別の extra module も `-m` で渡し、
`Overlaying local west project` と `Adding local extra module` の両方を assert したうえで
firmware target を 1 つ build します。
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

## local module

```bash
./build.sh ../your-zmk-config -m ../zmk-input-matrix
```

`-m` で渡した module は Docker 内へ copy します。directory name が west project name と一致する場合は `west update` 後にその project を local 版で上書きします。一致しない場合は `ZMK_EXTRA_MODULES` として ZMK に渡します。この tool の `local_modules/` に置いた module も同じ扱いです。

## clean

```bash
./build.sh clean
```

`.build/.gitkeep` を残して generated build output を削除します。

## self-hosted runner

通常の release gate は hosted `Compatibility` workflow です。自分の Windows、macOS、
Linux 実機で Docker validation を確認したい場合だけ `SELF_HOSTED_RUNNERS.ja.md` を使います。

## Docker image

既定の tag mode は `auto` です。`auto` では `config/west.yml` を読み、
`zmk` project の `revision` から Docker image tag を選びます。

- `main`、`master`、または不明な revision -> `stable`
- `v0.3` / `0.3` -> `3.5-branch`
- `v4.1` / `4.1` / `4.1-branch` -> `4.1-branch`

現在の ZMK `main` では次に解決されます。

```text
zmkfirmware/zmk-build-arm:stable
```

明示 override は常に優先されます。

```bash
ZMK_BUILD_IMAGE=zmkfirmware/zmk-build-arm:stable ./build.sh ../your-zmk-config
ZMK_BUILD_IMAGE_TAG=4.1-branch ./build.sh ../your-zmk-config
ZMK_DOCKER_PLATFORM=linux/amd64 ./build.sh ../your-zmk-config
```

## script の流れ

1. target repo を Docker 内の `/root/zmk-config` へ copy
2. top-level の `.cache`、`.ccache`、`.vscode`、`build`、`dist`、`node_modules`、`out`、`tmp`、`zmk_search` などの local/generated directory は copy しない
3. root module content があり `module.yml` だけがある legacy repo では、container 内だけで一時的な `zephyr/module.yml` に正規化する
4. persistent west workspace へは `config/` だけ copy
5. `ZMK_CONFIG=/root/zmk-config/config` で build し、ZMK が `config/boards` と root `boards` の両方を見られるようにする
6. `zephyr/module.yml` がある場合は `/root/zmk-config` を `ZMK_EXTRA_MODULES` に渡す
7. 必要なときだけ `west update`
8. 前回の local west project overlay を backup から復元してから、`local_modules/` と `-m` の module override を適用
9. `build.yaml` から生成した各 target を build
10. target ごとに firmware artifact 1 個だけを `.build/` へ copy
11. `build.log` と `build-summary.txt` を保存し、失敗時は summary に error excerpt を残す
