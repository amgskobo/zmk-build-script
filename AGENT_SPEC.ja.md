# AGENT_SPEC.ja.md

この repository の agent は、`build.sh` を小さく保ちます。

## 方針

- host 側の必要 dependency は Docker と Bash だけにする。Bash 環境に含まれる標準 Unix tool は使えるが、追加 install 前提にはしない
- Windows / macOS / Linux 差分は script 内で吸収する
- user が明示しない限り commit / push しない
- 既存の user changes を revert しない
- target repo は外部 repo 追跡のため必要最小限の legacy layout 互換を持たせる。`-m` / `local_modules/` の明示 module input は厳格に検証する
- build output は target ごとに firmware 1 個だけにする
- `build.log` と `build-summary.txt` は必要。run directory 名は `run-YYYY-MM-DD_HH-MM-SS-pid-PID` にする。失敗時は summary に error excerpt を残す
- local module override は必要。`-m` と `local_modules/` は維持する
- 外部 repo の full/pristine auto build は target-level 並列を既定 `build_jobs=1` にする。`--jobs` / `ZMK_BUILD_JOBS` は manual tuning 用に維持する

## 対応 layout

ZMK 公式 (`zmk.dev/docs/config`) の Shield / Board search path 順に従います。

- `zmk-config/boards/shields/<shield>/` (root) - 公式最新の **標準** パス
- `<module>/boards/shields/<shield>/` (module root) - module 提供時の標準
- `zmk-config/boards/<vendor>/<board>/` (root) - 公式最新の標準パス
- `<module>/boards/<vendor>/<board>/` (module root) - module 提供時の標準
- `zmk-config/config/boards/...` - 旧 compat path。公式は "For backwards
  compatibility only, do not use" と明記

```text
zmk-config/
+-- build.yaml
+-- config/
|   +-- west.yml
|   +-- <keyboard>.conf
|   +-- <keyboard>.keymap
|   +-- boards/              # 旧 compat path (公式は do not use を推奨)
+-- zephyr/
|   +-- module.yml
+-- boards/shields/<shield>/     # 公式最新の標準 (user config / module)
+-- boards/<vendor>/<board>/     # 公式最新の標準 (board)
+-- dts/
+-- snippets/<name>/
```

新規 repo では `zephyr/` の中を `module.yml` だけにします。ただし external auto
build は古い repo の状態追跡も目的にするため、target repo の legacy layout は
container 内の copy に限って許容します。ZMK は `config/boards` も compatibility
path として検索するため build script は拒否しませんが、公式は "do not use" 推奨の
ため新規 repo では root の `boards/` または外部 module を使ってください。
module source は repo root の `boards/`、`dts/`、`snippets/`、`Kconfig`、
`CMakeLists.txt` などに置けます。root `boards/`、`dts/`、`snippets/`、
`Kconfig`、`CMakeLists.txt` があり `zephyr/module.yml` の metadata が不足する
target repo は、build script の `normalize_target_module_metadata` が container
内で `build.settings.*_root: .` などを補います。host 側の元 repo は書き換えません。

## build flow

1. host target repo を container の `/root/zmk-config` へ copy
2. persistent west workspace `/workspaces/zmk-config` へは `config/` だけ copy
3. build 時の `ZMK_CONFIG` は `/root/zmk-config/config` を使う
4. 必要に応じて target repo の module metadata を container 内で正規化し、`zephyr/module.yml` がある場合は `/root/zmk-config` を `ZMK_EXTRA_MODULES` に追加
5. `west update` が必要な場合だけ実行
6. `local_modules/` と `-m` の module override を適用
7. `build.yaml` から生成した target を build。`--jobs` / `ZMK_BUILD_JOBS` が 2 以上なら target ごとに build directory を分けて並列 build。これは target-level 並列だけを制御し、各 target 内の `west build` / Ninja compile 並列は別に発生し得る
8. `.uf2` を最優先し、なければ fallback として `.bin` / `.hex` を 1 個だけ copy
9. container の main log stream にも同じ build output を流し、`build.log` と `build-summary.txt` を保存

## Docker image tag

既定は `ZMK_BUILD_IMAGE_TAG=auto` とし、target repo の `config/west.yml` にある
`zmk` project の `revision` から Docker image tag を選びます。

- `main` / `master` / 不明な revision は `stable`
- `v0.3` / `0.3` / `v0.3-*` / `0.3-*` は `3.5-branch`
- `v4.1` / `4.1` / `v4.1-*` / `4.1-*` は `4.1-branch`

`ZMK_BUILD_IMAGE` は full image override として最優先です。
`ZMK_BUILD_IMAGE_TAG` に `auto` 以外を指定した場合は、その tag をそのまま使います。
`west update` は transient network failure に備えて既定 3 回試行します。
`ZMK_WEST_UPDATE_ATTEMPTS` で回数を上書きできます。

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
  対応: self-hosted workflow は OS label の大文字小文字を合わせ、Windows は `Windows`、macOS は `macOS`、Linux は `Linux` を使う。Docker 実行 job は `zmk-docker` と `zmk-docker-active` も要求する
  確認: queued が続く場合は `gh api repos/<owner>/<repo>/actions/runners` で label / status / busy を確認し、必要なら `gh workflow run self-hosted-build.yml --ref main -f platform=all -f mode=build -f pristine=true` を watch する
- 症状: 外部 repo の自動 build を任意の self-hosted runner に割り当てるだけだと、OS ごとの host shell / artifact upload / Docker daemon 差分を active host coverage として検出できない
  原因: repo source ごとの失敗分離に加えて、Windows / macOS / Linux のうち active な OS host を成功条件にする必要がある。GitHub scheduler は custom tool / daemon の健康状態を知らないため、Docker が使える runner だけに active label を付ける必要もある
  対応: `Auto Build External ZMK Repos` は checks を active OS matrix、build を source x active OS matrix にし、各 job を `runs-on: [self-hosted, <OS>, zmk-docker, zmk-docker-active]` にした。artifact 名には OS slug を含める
  確認: `gh api repos/<owner>/<repo>/actions/runners` で online かつ `zmk-docker-active` の OS だけが matrix に入り、`auto-build.yml` の manual build run で active OS の checks と source x active OS build が完了することを確認する
- 症状: static な 3 OS matrix だと、macOS runner が offline のような non-active host が 1 つあるだけで full build run 全体が queued のまま止まる
  原因: GitHub Actions の `runs-on` label matching は offline runner を自動 skip せず、該当 label の runner が戻るまで job を queue する
  対応: `sources` job で active OS list を解決して `os_matrix` として出力する。`ZMK_RUNNER_READ_TOKEN` secret がある場合だけ repository self-hosted runners を GitHub API から読み、online かつ `self-hosted` / OS label / `zmk-docker` / `zmk-docker-active` を持つ OS を採用する。secret がない場合は `active_os` input、`ZMK_ACTIVE_OSES` repository variable、または既定 `windows,linux` を使う。`checks` と `build` はその active OS matrix を使い、non-active OS は run summary に offloaded OS として記録する
  確認: macOS runner が offline でも `active_os=auto` の configured fallback または `active_os=windows,linux` なら、manual auto build run が Windows / Linux の checks と source build に進むことを確認する。active OS が 0 件の場合は early failure にする
- 症状: workflow の grep / assertion が実装の正しい error text とずれて CI だけ失敗する
  原因: script の message 変更後に workflow expectation が更新されていない
  対応: workflow は現在の script 出力に合わせ、古い文言を前提にしない
  確認: host-side contract checks と helper behavior tests を両方実行する
- 症状: bug 対応後に、何を直し何を確認したかが次回 agent に残らない
  原因: agent file に bug 対応の記録 format と完了判定がなかった
  対応: `AGENTS.md` に bug 発見時の入口手順を追加し、この file に「bug を見つけた場合」と「対応済み bug / 注意点」を追加する
  確認: agent file diff、LF check、helper tests、必要な Docker validate を確認する
- 症状: 外部 repo 一括 build で `caksoylar/zmk-config` と `urob/zmk-config` のような同名 repo が clone directory を共有し、さらに並列実行時に複数 container が同じ Docker volume `zmk-cache` の `/workspaces/zmk-config` を同時に触る可能性がある
  原因: repo URL ではなく basename だけを実行単位にしていたため、clone path / cache volume / build job 名が一意ではなかった
  対応: `scripts/auto-build-external.sh` で URL / local path から slug を作り、重複 slug は suffix で一意化する。source ごとの実 build は `scripts/build-external-source.sh` から 1 つの `build.sh <target-dir>` process として起動し、`ZMK_DOCKER_CACHE_VOLUME=zmk-cache-external-<slug>` と source slug 入り container name を渡す
  確認: `.github/scripts/test-auto-build-external.sh` で source list 出力、matrix JSON、slug 重複回避を検証する。Docker 実 build では source ごとの cache volume log を確認する
- 症状: 外部 source を build script 内で全並列にすると Actions の raw log が混ざり、どの repo / path が失敗したかを run 画面から追いにくい
  原因: source orchestration を `build.sh` 内または 1 job 内の log fan-in に押し込めると、GitHub Actions の job 境界と source 境界が一致しない
  対応: `build.sh` は単体 target directory 専用に戻し、`--sources` / URL positional は扱わない。Actions は `repos.txt` を `--list-json` で matrix 化し、`Build <slug>` job ごとに `scripts/build-external-source.sh` を実行する。local の複数 source build も wrapper が source batch ごとに複数 script process を起動するだけにする
  確認: `.github/workflows/auto-build.yml` の source matrix job、`.github/scripts/test-auto-build-external.sh`、`bash -n ./build.sh` で確認する
- 症状: Actions auto-build が 1 job 内で全 source を逐次 iterate するため、複数 runner が idle でも並列 build できず、1 つの source 失敗で run 全体が失敗扱いになる
  原因: `auto-build-external.sh` が 1 job 内で source ごとに `build-external-source.sh` を起動する design だった
  対応: workflow を 2 job 構成に分割 — `sources` (ubuntu-latest) が `--list-json` で JSON matrix を出力し、`build` が per-source matrix job として独立実行する。artifact 名に `${{ matrix.source.slug }}` を含め、source 単位の識別を可能にする
  確認: YAML syntax validation、`auto-build-external.sh --list-json` の matrix 出力、per-source `build-external-source.sh` が slug / cache volume を正しく受け取ること、Ubuntu Docker validate で workflow が通ること
- 症状: local auto build wrapper で `repos.txt` の source 数が増えると、全 source の clone / Docker validate が一度に起動して host と Docker daemon に負荷が集中する
  原因: `--jobs` は target-level 並列数だけを制御しており、source-level の起動数を抑える設定がなかった
  対応: `scripts/auto-build-external.sh` に `--source-jobs` / `ZMK_EXTERNAL_SOURCE_JOBS` を追加し、同時に動かす source process 数を制限する。`--jobs` は従来どおり各 source 内の target 並列数として維持
  確認: `.github/scripts/test-auto-build-external.sh` で `--source-jobs` の無効値を検証し、`.github/fixtures/source-list.txt` の 2 source validate と root `boards/` 外部 repo smoke validate で wrapper / source builder の動作を確認する
- 症状: local auto build wrapper の `--source-jobs` が batch 待ち実行だと、短い source が終わっても同じ batch の長い source が終わるまで次の repo を開始せず、repo 数を増やすほど runner / Docker の空き時間が増える
  原因: source pool が「N 件起動して全件 wait」だけで、source 単位の完了を検出して空き枠へ次を流す queue になっていなかった
  対応: `scripts/auto-build-external.sh` を portable Bash 3.2 対応の rolling queue に変更し、各 child が status file を書いて終了したら parent が wait して次の source を起動する。test 用に `ZMK_EXTERNAL_SOURCE_BUILDER` override も追加する
  確認: `.github/scripts/test-auto-build-external.sh` で fake source builder を使い、`--source-jobs 2` のとき 3 件目が slow source の終了前に開始されることを検証する
- 症状: 外部 repo matrix を増やすと、manual workflow run で source-level の同時 job 数を調整できず、runner 台数や Docker daemon capacity に対して過剰な source job を投げやすい
  原因: GitHub Actions 側は source ごとの matrix job になっていたが、`strategy.max-parallel` の上限を user input から設定していなかった
  対応: `auto-build.yml` に `source_jobs` workflow_dispatch input を追加し、`build-runner.strategy.max-parallel` へ渡す。scheduled run は既定 4 とする
  確認: workflow syntax と helper tests を確認し、manual run では `source_jobs` が selected runner summary に出ることを確認する
- 症状: `t-ogura/zmk-config-prospector` の Linux external full build で、`lv_conf_internal.h:1` と `nrf52840_peripherals.h:1` の GCC 12.2.0 ICE / Segmentation fault が発生する
  原因: source matrix 全体が同一 runner に集中したのではなく、`--pristine` で Docker cache volume / ccache が冷えた状態のまま、`build_jobs=2` で 2 target を同時に起動し、各 target 内の Ninja 並列も制限されないため Linux runner の compile load が過大になった
  対応: `auto-build.yml` の `build_jobs` workflow_dispatch default と scheduled fallback を `1` にし、full/pristine の既定 target-level 並列を抑える。`build.sh --jobs` 自体は manual tuning 用に維持する
  確認: `bash -n ./build.sh`、全 `.sh` syntax、`.github/scripts/test-auto-build-external.sh`、`.github/scripts/check-lf.sh`、`git -c core.autocrlf=false diff --check`、manual auto build rerun で `EXTERNAL_BUILD_JOBS=1` を確認する
- 症状: `Compatibility` workflow の `Docker validate and build` job が、module override restore build 自体は成功しているのに `Process completed with exit code 1` で失敗する
  原因: `--pristine` が Docker cache volume を削除する仕様になった後も、restore assertion step が 2 回目の build に `--pristine` を渡していた。persistent workspace backup が消えるため `Restoring previous local overlay from backup` log が出ず、最後の `grep` だけが失敗した
  対応: 1 回目の local west project override build は clean start のため `--pristine` のままにし、restore を検証する 2 回目の build からは `--pristine` を外す
  確認: `bash -n ./build.sh`、全 `.sh` syntax、`.github/scripts/check-lf.sh`、`git -c core.autocrlf=false diff --check`、`Compatibility` workflow rerun で `Docker validate and build` が restore assertion を通ることを確認する
- 症状: Auto Build External ZMK Repos の Windows matrix job が repo build 前の `Show selected runner` で失敗し、後続 build step が skip される
  原因: `Show selected runner` step だけが全 OS 共通の `shell: bash` で、Windows self-hosted runner 用の Git Bash shell 指定に分岐していなかった
  対応: selected runner summary step も Unix / Windows に分割し、Windows は `C:\Progra~1\Git\bin\bash.exe --noprofile --norc -e -o pipefail {0}` を使う
  確認: `bash -n`、helper tests、manual auto-build rerun で Windows job が `Show selected runner (Windows)` を通過して build step に進むことを確認する
- 症状: `config/west.yml` の ZMK revision が `v0.3-branch+dya` のような suffix 付き branch の場合に、Docker image tag が `stable` に解決される
  原因: `docker_tag_for_zmk_revision` が `v0.3-branch` / `4.1-branch` の完全一致だけを扱い、suffix 付き branch を旧系統 / 4.1 系統として判定していなかった
  対応: `v0.3-*` / `0.3-*` を `3.5-branch`、`v4.1-*` / `4.1-*` を `4.1-branch` に解決するようにした
  確認: `te9no/zmk-config-GeaconSolstice` の validate smoke で `v0.3-branch+dya` が `3.5-branch` に解決されることを確認する
- 症状: Actions full build の `west update` 中に `Could not resolve host: github.com` が一時的に出ると、既に大半の west project を取得済みでも source build が失敗する
  原因: `west update` を 1 回だけ実行しており、transient DNS / network failure を retry しなかった
  対応: `west update` を既定 3 回 retry する。`ZMK_WEST_UPDATE_ATTEMPTS` で回数を上書き可能にし、最終失敗時だけ既存の local override 判定へ進む
  確認: `bash -n ./build.sh`、標準 fixture validate、Actions full build rerun で確認する
- 症状: persistent workspace の path に空白があると stale `.git/index.lock` が削除されず、また最初の `west update` 失敗で lock が残ると retry も失敗する
  原因: lock path を改行区切りで `xargs rm` に渡していたため空白で分割され、lock cleanup も retry loop の前に 1 回しか実行していなかった
  対応: path を引数単位で保持する `find -exec rm` に変更し、各 `west update` 試行の直前に stale lock を削除する
  確認: 空白を含む一時 workspace で `.git/index.lock` が削除されること、`bash -n ./build.sh`、標準 fixture validate、LF / whitespace check で確認する
- 症状: `repos.txt` に最新 ZMK や active OS と互換しない外部 repo が混在すると、script は正常でも Actions full build が恒常的に失敗する
  原因: board name / module.yml / root snippet / widget alias / keymap API など、外部 repo 側の layout や module API が現在の ZMK build image と一致していない
  対応: remote full build の結果をもとに `repos.txt` を active OS firmware build 通過候補として分類する。外部 repo 側の互換性問題は script bug と分けて扱う。2026-06-05 の再検証準備として、`d5f1e61` 時点の 14 repo set を `repos.txt` に戻す
  確認: `repos.txt` は `urob/zmk-config`、`minusfive/knucklehead`、`folke/zmk-config`、`sayu-hub` 系、`kumamuk-git/zmk-config-roBa`、`t-ogura` 系、`kureyakey/zmk-config-zonkey`、`nyasu0123/zmk-config-LisM`、`4mplelab/zmk-config-LisM`、`te9no/zmk-config-GeaconSolstice`、`waressyoi/Cocon-zmk-config` の 14 source にする。過去 run では一部 repo に active Linux build failure があったため、full external build で再分類する
- 症状: 14 repo 復帰後の external auto build で、`kumamuk-git/zmk-config-roBa`、`nyasu0123/zmk-config-LisM`、`4mplelab/zmk-config-LisM`、`te9no/zmk-config-GeaconSolstice`、`t-ogura/zmk-config-cornix-tb` が実 build 前の layout guard で失敗し、実際の ZMK 互換性を追跡できない
  原因: target repo に対しても「`zephyr/` は `module.yml` だけ」「root `snippets/` / `dts/` は事前に `zephyr/module.yml` の `build.settings` が必要」という制約を host / container の早期 validation で強制していた。external auto build の目的は古い repo も含めた状態追跡なので、この制約は強すぎた
  対応: target repo の host-side guard を緩め、container 内 copy で `normalize_target_module_metadata` が不足する `zephyr/module.yml` metadata を補う。legacy `zephyr/` content は warning として許容する。明示 input の `-m` / `local_modules/` は引き続き strict validation の対象にする
  確認: `bash -n ./build.sh`、全 `.sh` syntax、`.github/scripts/test-auto-build-external.sh`、`.github/scripts/check-lf.sh`、`git -c core.autocrlf=false diff --check`、root snippet compat validate、manual external auto build rerun で確認する
- 症状: Linux の外部 repo build が firmware artifact を生成して `Status: SUCCESS` なのに、`build-summary.txt does not include Built targets for build mode` で Actions が失敗する
  原因: `build-summary.txt` の `Built targets` は `build.log` の `Build complete: N target(s).` 行だけから抽出していた。runner / Docker log stream によって行頭以外の prefix、CR、ANSI escape、または該当行欠落があると、build 成功後の summary 契約だけが偽陰性になる
  対応: `built_target_count` は CR / ANSI escape を除去し、行中の `Build complete: N target(s).` も拾う。build mode かつ `Status: SUCCESS` で log から count が取れない場合は、copy 済み firmware artifact (`.uf2` / `.hex` / `.bin`) 数を `Built targets` の fallback にする
  確認: `bash -n ./build.sh`、`.github/scripts/test-check-build-output.sh`、3 OS external auto build の Linux `urob` / `folke` job で確認する
- 症状: `repos.txt` の URL source clone で `Could not resolve host: github.com` などの transient network failure が 1 回出るだけで、source matrix job が `clone failed` になる
  原因: clone 専用 Docker container の `git clone --depth=1` を 1 回だけ実行していた
  対応: `scripts/build-external-source.sh` は `ZMK_EXTERNAL_CLONE_ATTEMPTS` を追加し、既定 3 回まで clone container 作成 / clone 実行を retry する
  確認: `bash -n scripts/build-external-source.sh`、`.github/scripts/test-auto-build-external.sh`、3 OS external auto build rerun で確認する
- 症状: `repos.txt` の URL source を `build.sh` 経由で扱うと、host shell の path conversion 設定や host git の有無に source clone が影響される
  原因: `build.sh` が Docker path 変換を防ぐために export している `MSYS_NO_PATHCONV=1` / `MSYS2_ARG_CONV_EXCL=*` を source helper へ継承し、host 側 clone と Docker build の責務が混ざっていた
  対応: URL source の clone は `scripts/build-external-source.sh` の単体責務に移し、既定では Docker clone image で clone 専用 container の `/tmp/source` に clone してから `docker cp` で `.build/external/<slug>` へ戻す。`build.sh` は clone 済み local path のみを受け取る
  確認: helper syntax、matrix JSON、存在しない path source が Docker build 前に失敗することを `.github/scripts/test-auto-build-external.sh` で確認する
- 症状: Docker clone container 内では `/external/<slug>` への clone が成功したように見えるのに、host 側の `.build/external/<slug>` が存在せず `build.sh` が `target directory not found` で失敗する
  原因: workspace が Google Drive の `G:\...` 上にあり、Docker Desktop の bind mount が host filesystem へ反映されなかった。さらに Git Bash から `-v G:/...:/external` を渡すと Windows drive colon と Docker volume syntax も衝突しやすい
  対応: URL clone は bind mount を使わず、clone 専用 container を `docker create` / `docker start -a` で実行し、成功後に `docker cp <container>:/tmp/source/. <host clone dir>` で host へ戻す。clone 用 Docker command では `MSYS_NO_PATHCONV=1` を局所的に使い、`docker cp` の host destination だけ Windows path に変換する
  確認: `scripts/build-external-source.sh --repo https://github.com/caksoylar/zmk-config.git --source-slug smoke-caksoylar --mode validate --settings-reset` が成功し、`.github/scripts/test-auto-build-external.sh` で source helper の契約を確認する
- 症状: Windows runner の URL source clone で Docker container 内の clone は成功するが、`docker cp` が `zephyr \module.yml: The system cannot find the path specified.` のように失敗し、`kureyakey/zmk-config-zonkey` が clone failed になる
  原因: 外部 repo に Windows filesystem へ作成できない末尾空白 / 末尾 dot の path があると、Linux container から Windows host への `docker cp` で host 側に展開できない。Unix runner では同じ repo が build まで進むため、repo 互換性ではなく host filesystem copy 問題だった
  対応: Windows host の repo clone copy 前に、clone container 内で末尾空白 / 末尾 dot の path を warning 付きで除去する。正規の ZMK source path は末尾空白を使わない前提で、Unix runner では除去しない
  確認: `bash -n scripts/build-external-source.sh`、`.github/scripts/test-auto-build-external.sh`、Windows runner の `kureyakey/zmk-config-zonkey` rerun で clone が build step へ進むことを確認する
- 症状: local build の target 並列化で複数 `west build` が同じ `${WORK_DIR}/.build` を共有すると、build output と artifact 選択が衝突する
  原因: 旧実装は target を順に build する前提で、全 target が同じ build directory を使っていた
  対応: `--jobs` / `ZMK_BUILD_JOBS` を追加し、各 target は `${WORK_DIR}/.build/<artifact>` を使う。並列時は target log を一時 file に分け、batch ごとに `build.log` へ出力する
  確認: `bash -n ./build.sh`、`./build.sh validate .github/fixtures/ci-zmk-config --settings-reset --jobs 2`、可能なら fixture full build を `--jobs 2` で確認する
- 症状: `docker logs <build-container>` や Docker Desktop の container log に build 進行が出ず、host terminal の `docker exec` stream を見逃すと追いにくい
  原因: container の main process が `tail -f /dev/null` で、実 build は `docker exec` の stdout としてだけ流れていたため、container 本体の log stream に残らなかった
  対応: container main process は `/tmp/zmk-build-stream.log` を tail し、`docker exec` 側の build/validate output を container 内 `tee /tmp/zmk-build-stream.log` にも流す。host 側 `build.log` への tee は維持する
  確認: `ZMK_KEEP_CONTAINER=1 ./build.sh validate .github/fixtures/ci-zmk-config --settings-reset` 後に `docker logs <container>` で validate log が見えることを確認する
- 症状: `zmkfirmware/zmk-build-arm:3.5-branch` を使う local build で `dtc: ... libc.so.6: version 'GLIBC_2.38' not found (required by /usr/libexec/coreutils/libstdbuf.so)` が出る
  原因: container-side build output の streaming を強めるために host 側 `docker exec` command で `stdbuf -oL ./build.sh build` を使ったところ、`stdbuf` の `LD_PRELOAD` が子プロセスの `dtc` まで伝播し、古い Zephyr SDK / image の libc と衝突した
  対応: `docker exec` 側の `stdbuf` を外し、`./build.sh build|validate 2>&1 | tee -a /tmp/zmk-build-stream.log` のみで host log と container log stream へ流す
  確認: mona2 など `3.5-branch` image の local build で GLIBC mismatch が再発しないこと、`docker logs` stream が維持されることを確認する
- 症状: scheduled workflow に `timezone` を書く、または JST コメントと cron の UTC 実行時刻がずれると、自動実行時刻を誤認する
  原因: GitHub Actions の `on.schedule` は UTC cron だけを受け付け、timezone key は schedule 構文として扱えない
  対応: workflow から `timezone` を除き、JST の実行時刻を UTC に換算した cron と明示コメントに統一する。手動再実行用に `workflow_dispatch` を残し、定期実行 job には concurrency / timeout を付ける
  確認: `.github/workflows/*.yml` に `timezone` が残っていないこと、`auto-build.yml` と `heartbeat.yml` の cron コメントが UTC/JST 換算を示すことを確認する
- 症状: hosted `Shell compatibility` で external repo helper test が Unix は `Permission denied`、Windows は local temp path の表記差で失敗する
  原因: test が `scripts/auto-build-external.sh` の executable bit に依存し、さらに Git Bash の `/tmp` が `pwd -P` で `/c/Users/.../Temp` に正規化される差を期待値へ反映していなかった
  対応: helper test は `bash "${builder}"` で起動し、`mktemp` 後の temp directory を `pwd -P` で正規化してから期待値に使う
  確認: hosted `Compatibility` の `Shell compatibility` 3 OS で `Check external repo helper behavior` を確認する
- 症状: macOS hosted の Bash 3.2 だけで `used_slugs[@]: unbound variable` が出る
  原因: `set -u` の下で空の indexed array を `"${array[@]}"` 展開すると、古い Bash では unbound と扱われる場合がある
  対応: 空になり得る array loop は `${#array[@]}` を確認してから回し、空 source list の JSON/list 出力も早期 return する
  確認: hosted `Compatibility` の macOS `Check external repo helper behavior` を確認する
- 症状: `AGENT_SPEC.ja.md` の「対応 layout」が root `boards/` の位置づけを弱く記載しており、ZMK 公式 latest との対応が不明確だった
  原因: spec は `config/boards/` を "ZMK compatibility path" として記載していたが、ZMK 公式 (`zmk.dev/docs/config`) は "For backwards compatibility only, do not use" と明記している。root `boards/` の最新標準パスとしての説明も "module source ... に置けます" と補助的で、user config 標準パスであることが読み取りにくかった
  対応: 「対応 layout」セクションを ZMK 公式の Shield / Board search path 順 (`zmk-config/boards/shields/<shield>/` などの root path が標準、`config/boards/...` が旧 compat) に合わせて書き換え。root `boards/` は `zephyr/module.yml` なしでも ZMK search path で発見できる旨を明記
  確認: `bash -n ./build.sh`、`git -c core.autocrlf=false diff --check`、`git status --short --branch`、AGENT_SPEC.ja.md diff の意図確認。root `boards/` パターン repo は remote Actions full build の結果で互換性を分類し、通過候補だけを `repos.txt` に残す
- 症状: `auto-build.yml` の `Resolve active runner OS matrix` step で `ZMK_RUNNER_READ_TOKEN: command not found` が出て、macOS runner が online でも fallback の `windows,linux` matrix しか出ない
  原因: 2 点が複合している。1) summary の fallback 行 `echo "| <unavailable> | n/a | n/a | set \`ZMK_RUNNER_READ_TOKEN\` for API auto-detect |"` が double quote 内に backtick を持ち、bash が command substitution として `ZMK_RUNNER_READ_TOKEN` を実行しようとする。2) `[ "${ACTIVE_OS_REQUEST}" = "auto" ] && [ -n "${RUNNER_READ_TOKEN}" ]` が偽 (secret 未設定) のときに silent に fallback しており、`::warning::` が出ないので user が「auto-detect は走っているが macOS が見えていない」と誤認する。GitHub Actions の `GITHUB_TOKEN` permission list に `administration` は無く、`repos/.../actions/runners` API は admin access が必須なので、auto-detect には別 PAT (`ZMK_RUNNER_READ_TOKEN`) が必須
  対応: summary 行を single-quoted echo に変えて backtick を literal にする。`ACTIVE_OS_REQUEST=auto` かつ `RUNNER_READ_TOKEN` が空のときは `::warning title=Active OS auto-detect skipped::...` を出し、なぜ fallback したのか・どの secret / scope を入れれば auto-detect が有効になるかを log に書く
  確認: `bash -n` で auto-build.yml の run block syntax、`git diff --check` で whitespace、API 自動判定を有効にしたい場合は user 側で `ZMK_RUNNER_READ_TOKEN` secret に fine-grained PAT の `administration: read` (repo permissions) または classic PAT の `repo` scope を設定する
- 症状: 過去の `select_runner` job (commit 077614e) は `actions: read` permission + `GH_TOKEN: ${{ github.token }}` で `repos/.../actions/runners` API を叩いていたが、現行の `auto-build.yml` は `ZMK_RUNNER_READ_TOKEN` PAT を必須にしており、user にとって「この repo では GITHUB_TOKEN が runners API を叩けるのか」が判別できない
  原因: 077614e (Thu Jun 4 21:09 JST) から 8840a86 (同日 21:24 JST) への変更は、permission 差だけの修正ではなく「1 runner 直列」アーキから「OS × source matrix」アーキへの作り直しだった。新アーキでは 3 OS 全部の online 判定を silent に失敗させたくないので PAT を必須化した、と読むのが自然
  対応: `sources` job に `Probe GITHUB_TOKEN runners API access` step を追加する。`continue-on-error: true` で `gh api repos/<repo>/actions/runners` を `GH_TOKEN=${GITHUB_TOKEN}` で呼び、`gh api` exit code / runner count / online OS list / レスポンス先頭 240 byte を step summary と `::notice title=GITHUB_TOKEN runners API::...` に出す。`if: env.ACTIVE_OS_REQUEST == 'auto'` を付け、manual で `active_os=windows,linux` などを指定した run では probe しない。user は workflow run の log を見て、この repo で GITHUB_TOKEN が runners API を叩けるか・online OS が何と認識されるかを実測できる
  確認: `bash -n` で auto-build.yml の run block syntax、`git diff --check` で whitespace、manual `workflow_dispatch` (`active_os=auto`) で `## GITHUB_TOKEN runners API probe` セクションが step summary に出ることと `::notice title=GITHUB_TOKEN runners API::allowed|denied` が run log に出ることを確認する。`allowed` なら `ZMK_RUNNER_READ_TOKEN` 未設定でも auto-detect 経路を GITHUB_TOKEN 化する方針 (次の作業) に進める
- 症状: API ベースの active OS 検出 + pre-job matrix の経路は `ZMK_RUNNER_READ_TOKEN` PAT と `active_os` / `ZMK_ACTIVE_OSES` の設定を必要とし、PAT を持たない user や最小構成 repo では常に `windows,linux` fallback に落ちる。3 OS matrix の shared checks と source x OS matrix の build は、runner が 1 台 online のとき 1 つの OS job しか動かず逆に full sweep には遠い
  原因: 旧設計は active OS list を pre-job で API 解決してから matrix 化していたが、GitHub Actions の `runs-on` label routing 自体が「online かつ idle な該当 runner」を自動選択する。OS を pin せず label routing に任せれば、API 判定・pre-job matrix・probe step・`active_os` input / `ZMK_ACTIVE_OSES` variable / `ZMK_RUNNER_READ_TOKEN` secret を一括撤去できる
  対応: `auto-build.yml` を 1 job 構成に簡素化し、`runs-on: [self-hosted, zmk-docker, zmk-docker-active]` で OS を pin しない。`zmk-docker` + `zmk-docker-active` を持つ online な runner を GitHub Actions の label routing に直接選ばせ、選ばれた runner の OS は `runner.os` で参照して shell step を分岐する (Windows は Git Bash、Unix は Bash)。source の iteration は 1 job 内の `scripts/auto-build-external.sh --repos-file ...` に集約。`concurrency.cancel-in-progress: true` で stale な queued run の上に新規 scheduled run が積もらないようにする。`ZMK_RUNNER_READ_TOKEN` / `active_os` input / `ZMK_ACTIVE_OSES` / `gh api` 呼び出し / `Probe GITHUB_TOKEN` step は全て削除。`SELF_HOSTED_RUNNERS` doc は `zmk-docker` / `zmk-docker-active` の役割と offload 運用 (label を外す or runner 停止) を維持
  確認: `bash -n` で workflow run block syntax、`git diff --check` で whitespace、README.md / README.ja.md / `SELF_HOSTED_RUNNERS.md` / `SELF_HOSTED_RUNNERS.ja.md` の新方針記述、3 runner offline 時に queue に残ることと online 時にいずれかの runner で build が進むこと、`runner.os` によって Unix shell と Git Bash shell が切り替わること、artifact 名に `${{ runner.os }}` が入ること、scheduled run と manual run のどちらも 1 job に収まることを確認する。失われる機能 (OS 優先順 fallback、host 単位 skip、3 OS 横断 full sweep) はこの変更の前提合意として扱う

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
