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

## bug を見つけた場合

bug は症状を消すだけで終わらせません。次の順で扱います。

1. 失敗箇所を host shell、host -> container copy、container -> workspace sync、`west update`、local module overlay、build、artifact copy、summary、workflow scheduling に分ける
2. 同じ pattern が macOS / Windows / hosted / self-hosted の片側だけに残っていないか検索する
3. 実装を最小差分で直す。user が明示していない commit / push はしない
4. 可能なら `.github/scripts/test-*.sh`、fixture、workflow check のどれかで再発防止する
5. test で固定しすぎる場合は、固定すべき契約だけを agent file に記録する
6. 直した内容をこの file の「対応済み bug / 注意点」に追記する
7. 最後に LF、whitespace、helper tests、必要な Docker validate/build、必要なら remote CI を確認する

追記 format:

```text
- 症状: ...
  原因: ...
  対応: ...
  確認: ...
```

## 対応済み bug / 注意点

- 症状: PowerShell からの `bash` が WSL に解決され、日本語を含む `G:\...` path で失敗することがある
  原因: Windows host で `bash` の解決先が Git Bash ではなく WSL になる
  対応: Windows の検証 command は `C:\Program Files\Git\bin\bash.exe` を明示する
  確認: `bash -n`、helper tests、Docker validate は Git Bash executable 経由で実行する
- 症状: local module copy で `zmk`、`modules`、`tools`、`bootloader`、`optional` が必要な content まで消える可能性がある
  原因: generated west project directory かどうかを copy 元ごとに判定しないと、通常 module content と west workspace cache を取り違える
  対応: copy 元が `.west` を持つ場合だけ generated west project directory を除外し、`.west` を持たない module では保持する
  確認: `.github/scripts/test-copy-excludes.sh` で target repo、`-m` external module、`local_modules/<name>` の `.west` あり / なしを検証する
- 症状: Windows self-hosted job が runner online / idle でも queued のまま進まない
  原因: self-hosted runner label は大文字小文字を含めて一致が必要。`windows` と `Windows` は別 label
  対応: Windows self-hosted workflow は `runs-on: [self-hosted, Windows, zmk-docker]`、macOS は `runs-on: [self-hosted, macOS, zmk-docker]` にする
  確認: queued が続く場合は `gh api repos/<owner>/<repo>/actions/runners` で label / status / busy を確認し、必要なら `gh workflow run self-hosted-build.yml --ref main -f platform=all -f mode=build -f pristine=true` を watch する
- 症状: workflow の grep / assertion が実装の正しい error text とずれて CI だけ失敗する
  原因: script の message 変更後に workflow expectation が更新されていない
  対応: workflow は現在の script 出力に合わせ、古い文言を前提にしない
  確認: host-side contract checks と helper behavior tests を両方実行する
- 症状: bug 対応後に、何を直し何を確認したかが次回 agent に残らない
  原因: agent file に bug 対応の記録 format と完了判定がなかった
  対応: `AGENTS.md` に bug 発見時の入口手順を追加し、この file に「bug を見つけた場合」と「対応済み bug / 注意点」を追加する
  確認: agent file diff、LF check、helper tests、必要な Docker validate を確認する

## 完成度チェック / 完了判定

完了扱いにする前に、次を確認します。

- scope が user の最新指示に合っているか。古い指示や広すぎる調査に引きずられない
- 変更 file が user の依頼 scope に対して必要最小限か。scope と無関係な workflow / docs を触っていないか
- bug を直した場合、同系統の再発確認または agent file への契約記録があるか
- `git status --short --branch` で未追跡 file や意図しない差分が残っていないか
- LF / whitespace / syntax / helper tests を実行したか
- Docker が関係する変更では `check-runner-tools.sh`、該当 fixture、`check-build-output.sh` まで確認したか
- artifact / fallback / sync を触った場合、`.uf2` 以外の `.bin` / `.hex` と artifact count の前提を壊していないか
- workflow / self-hosted を触った場合、hosted `Compatibility` と手動 `Self-hosted Build` のどちらを確認したかを明記したか
- commit / push は user が明示した場合だけ行い、行った場合は remote CI の結果も確認したか
- 実行できなかった check は、理由と残リスクを報告したか

確認範囲は変更範囲に合わせます。

- agent docs / README だけ: `bash -n ./build.sh`、全 `.github/scripts/*.sh` syntax、`check-lf.sh`、`git diff --check` を最低限にする。記述が build / CI の実挙動に触れる場合は該当 helper test も実行する
- helper scripts / LF / summary: helper behavior test、`check-lf.sh`、`git diff --check` を必ず実行する
- copy / local module / sync: `check-runner-tools.sh`、`test-copy-excludes.sh`、関連 fixture validate/build、`check-build-output.sh` を実行する
- artifact / fallback / build output: build mode の fixture と `check-build-output.sh build` で artifact count と `.uf2` / `.bin` / `.hex` fallback を確認する
- workflow / self-hosted: local syntax と helper tests に加え、push 後に hosted `Compatibility`、必要なら手動 `Self-hosted Build` を確認する。push していない場合は remote CI 未実行と明記する

完了報告 format:

```text
変更:
- ...

確認:
- PASS ...
- 未実行 ... 理由: ...

状態:
- commit: なし / <hash>
- push: なし / <remote>
- worktree: clean / dirty
```

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
