# AGENT_SPEC.ja.md

この repository の agent は、`build.sh` を小さく保ちます。

## 方針

- host 側の必要 dependency は Docker と Bash だけにする。Bash 環境に含まれる標準 Unix tool は使えるが、追加 install 前提にはしない
- Windows / macOS / Linux 差分は script 内で吸収する
- user が明示しない限り commit / push しない
- 既存の user changes を revert しない
- 最新 ZMK layout 以外の互換層を増やさない
- build output は target ごとに firmware 1 個だけにする
- `build.log` と `build-summary.txt` は必要。run directory 名は `run-YYYY-MM-DD_HH-MM-SS-pid-PID` にする。失敗時は summary に error excerpt を残す
- local module override は必要。`-m` と `local_modules/` は維持する

## 対応 layout

```text
zmk-config/
+-- build.yaml
+-- config/
|   +-- west.yml
|   +-- <keyboard>.conf
|   +-- <keyboard>.keymap
|   +-- boards/              # ZMK compatibility path
+-- zephyr/
|   +-- module.yml
+-- boards/shields/<shield>/
+-- dts/
+-- snippets/<name>/
```

`zephyr/` の中は `module.yml` だけにします。ZMK docs は `config/boards` も
compatibility path として検索するため拒否しません。module source は repo root の
`boards/`、`dts/`、`snippets/`、`Kconfig`、`CMakeLists.txt` などに置けます。
root `dts/` や `snippets/` は、`zephyr/module.yml` の
`build.settings.dts_root: .` / `build.settings.snippet_root: .` が必要です。

## build flow

1. host target repo を container の `/root/zmk-config` へ copy
2. persistent west workspace `/workspaces/zmk-config` へは `config/` だけ copy
3. build 時の `ZMK_CONFIG` は `/root/zmk-config/config` を使う
4. `zephyr/module.yml` がある場合は `/root/zmk-config` を `ZMK_EXTRA_MODULES` に追加
5. `west update` が必要な場合だけ実行
6. `local_modules/` と `-m` の module override を適用
7. `build.yaml` から生成した target を順に build
8. `.uf2` を最優先し、なければ fallback として `.bin` / `.hex` を 1 個だけ copy
9. `build.log` と `build-summary.txt` を保存

## Docker image tag

既定は `ZMK_BUILD_IMAGE_TAG=auto` とし、target repo の `config/west.yml` にある
`zmk` project の `revision` から Docker image tag を選びます。

- `main` / `master` / 不明な revision は `stable`
- `v0.3` / `0.3` は `3.5-branch`
- `v4.1` / `4.1` / `4.1-branch` は `4.1-branch`

`ZMK_BUILD_IMAGE` は full image override として最優先です。
`ZMK_BUILD_IMAGE_TAG` に `auto` 以外を指定した場合は、その tag をそのまま使います。

## build.yaml

対応する key:

- `board`
- `shield`
- `snippet`
- `cmake-args`
- `extra-cmake-args`
- `artifact-name`
- `skip`

top-level `board` / `shield` matrix、`include` 内 matrix、`exclude`、`defaults` に対応します。
`--settings-reset` は、まだ `settings_reset` target がない board ごとに reset target を追加します。
direct config directory と custom config path は扱いません。必要になった場合も、
まず ZMK 公式 layout に寄せられないか確認します。

CI fixture は ZMK 4.1 HWMv2 の代表 board として `nice_nano/nrf52840/zmk` と
`xiao_ble/nrf52840/zmk` を重点的に確認します。全 upstream board の網羅 build ではなく、
この 2 board で `settings_reset`、Corne left/right、XIAO 向け `tester_xiao` shield を確認し、
build script の代表的な互換性を確認します。

target 形状の parser 確認は `.github/fixtures/target-shapes-zmk-config` に分離します。
この fixture は validate 専用で、top-level matrix、include matrix、`defaults`、`exclude`、
`skip`、alias key、placeholder、`--settings-reset` の重複回避を確認します。

local west project override の確認は `.github/fixtures/module-override-zmk-config` で行います。
CI は cache 済みの `zmk-studio-messages` と `zcbor` west project を host 側へ copy し、
両方を `-m` で戻します。同時に別の extra module も `-m` で渡し、
`Overlaying local west project` と `Adding local extra module` の両方を踏んだあと、
studio 有効 target を 1 つ full build します。
これにより `proto/zmk` のような入れ子 path が module copy で落ちないことも確認します。

## local module

- `-m <dir>` は host から Docker 内へ copy する
- `local_modules/<name>` も自動で Docker 内へ copy する
- copy 元が `.west` を持つ場合だけ、その copy 元の generated west project directory を除外する
- `.west` を持たない module では `zmk`、`modules`、`tools`、`bootloader`、`optional` などの名前も保持する
- directory name が west project name と一致する場合は、その project path を local 版で overlay する
- 一致しない場合は local extra module として `ZMK_EXTRA_MODULES` に追加する

## 変更時の確認

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -n ./build.sh
& 'C:\Program Files\Git\bin\bash.exe' -lc 'for script in .github/scripts/*.sh; do bash -n "$script"; done'
& 'C:\Program Files\Git\bin\bash.exe' .github/scripts/test-check-lf.sh
& 'C:\Program Files\Git\bin\bash.exe' .github/scripts/test-check-build-output.sh
& 'C:\Program Files\Git\bin\bash.exe' .github/scripts/test-copy-excludes.sh
& 'C:\Program Files\Git\bin\bash.exe' .github/scripts/check-lf.sh
git -c core.autocrlf=false diff --check
```

build / validate path を触った場合は、少なくとも次を実行し、各 run の直後に
`check-build-output.sh` で `build.log` / `build-summary.txt` / mode / artifact count を確認します。

```powershell
& 'C:\Program Files\Git\bin\bash.exe' ./build.sh validate .github/fixtures/ci-zmk-config
& 'C:\Program Files\Git\bin\bash.exe' .github/scripts/check-build-output.sh validate
& 'C:\Program Files\Git\bin\bash.exe' ./build.sh validate .github/fixtures/ci-zmk-config --settings-reset
& 'C:\Program Files\Git\bin\bash.exe' .github/scripts/check-build-output.sh validate
& 'C:\Program Files\Git\bin\bash.exe' ./build.sh validate .github/fixtures/target-shapes-zmk-config --settings-reset
& 'C:\Program Files\Git\bin\bash.exe' .github/scripts/check-build-output.sh validate
& 'C:\Program Files\Git\bin\bash.exe' ./build.sh .github/fixtures/module-override-zmk-config --pristine
& 'C:\Program Files\Git\bin\bash.exe' .github/scripts/check-build-output.sh build
& 'C:\Program Files\Git\bin\bash.exe' ./build.sh .github/fixtures/ci-zmk-config --pristine
& 'C:\Program Files\Git\bin\bash.exe' .github/scripts/check-build-output.sh build
```

## legacy root module

root `module.yml` だけを持つ legacy repo は、build / validate の container 内だけで
一時的な `zephyr/module.yml` に正規化します。source repo には書き込みません。

copy payload には top-level の local/generated directory (`.cache`, `.ccache`, `.vscode`, `build`,
`dist`, `node_modules`, `out`, `tmp`, `zmk_search`) を含めません。

local module overlay と west project name が一致する場合は、元 project を workspace 内に
backup してから overlay します。次回 build では backup から通常 checkout へ戻します。
