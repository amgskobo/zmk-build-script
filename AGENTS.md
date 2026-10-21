# Agent contract

この repository では日本語で応答します。利用方法・CLI・runner 運用は [README.ja.md](README.ja.md) と
[README.md](README.md)、保守規約はこの file に集約します。別の仕様書へ同じ契約を複製しません。
外部 repo の名前、commit hash、日付、個別の実測値、一度きりの検証結果はこれらの文書に追加せず、
必要な command / source / image identity と raw log は `.build/` の新しい実行記録に残します。

## 作業範囲

- user の最新指示と既存差分を最初に読み、user changes を保持する。
- user が各操作を明示しない限り commit / push / PR 作成・更新 / merge / tag / release をしない。
  test 成功や milestone は許可ではない。無関係な変更を stage しない。
- `build.sh` を主対象とし、helper / workflow / docs はその契約に直接関係する範囲だけ扱う。
  keyboard / module の source、実機 firmware、settings を変更しない。
- 単体 build で常に有効な機能は `build.sh` に入れ、opt-out が必要な場合だけ環境変数を追加する。
  新しい script / container / fixture を増やす前に既存の責務と scenario へ統合できるか確認する。
- host 必須依存は Docker と Bash。標準 Unix tool は使えるが追加 install 前提にしない。Git は optional。

## 責務の境界

| 場所 | 責務 |
| --- | --- |
| `build.sh` | 1 target directory の build / validate / clean、host copy、container 内 workspace、成果物回収 |
| `scripts/auto-build-external.sh` | source list / JSON matrix、slug の一意化、source process の rolling queue |
| `scripts/build-external-source.sh` | 1 source の clone / local path 解決と builder 起動 |
| `scripts/source-common.sh` | wrapper 共通の分類・名前処理と clone path の除去 |
| `repos.txt` | 1 行 1 source。relative path は list file の directory 基準 |
| `.github/fixtures/` | 標準 build、parser 専用 target shapes、module override |
| `.github/scripts/` | runner / LF / output check と既存 helper behavior test |
| `.github/workflows/` | hosted compatibility、手動 self-hosted smoke、外部 source matrix、heartbeat |

`build.sh` に source 列挙や clone を戻さない。source 並列と target 並列を分ける。
host -> container -> persistent workspace の 2 段階 copy と、host への成果物回収を別の境界として扱う。

## 実装契約

### Host と copy

- Windows / macOS / Linux の差分は script が吸収する。Windows は Git Bash を明示する。
  MSYS の Docker path 自動変換を止めた状態で native `git.exe` に MSYS path を渡さず、directory へ `cd` して実行する。
- host は Bash 3.2 に対応する。`set -u` 下で空配列をそのまま展開せず、`${array[@]+"${array[@]}"}` または要素数を使う。
- container 作成前に空の archive を実際に作り `tar --exclude` を確認する。NUL file list は `--null -T` の空入力を実際に処理して確認し、非対応なら Git file list を使わない。短縮 help の記載だけで非対応と判定しない。
- Git working tree は tracked と ignore されない untracked file を NUL 区切りで copy する。
  削除済み tracked file は除き、ignore に一致する tracked file は保持する。
  `ZMK_COPY_IGNORED=1`、Git 無し / 失敗、非 working tree、空の一覧では固定除外つき全 copy に戻す。
- 固定除外は `.git` / `.west` / `__pycache__` と top-level の `.zmk` `.build` `.cache` `.ccache` `.vscode`
  `build` `dist` `node_modules` `out` `tmp` `zmk_search`。top-level 除外は入力の root entry で選別し、tar pattern の OS ごとの anchor 解釈に依存しない。この tool の `local_modules/` は探索しない。
- `zmk` / `modules` / `tools` / `bootloader` / `optional` は名前だけで generated と判定しない。
  source に `.west` があり、対象 tree に `.git` marker がある場合だけ generated dependency として除外する。

### Layout と依存

- `build.yaml` と `config/west.yml` を持つ repo root を入口とする。direct config directory / custom config path は扱わない。
- 標準は root / module 内の `boards/`。既存 `config/boards` は compatibility path として許容する。
- target の legacy `zephyr/` content は warning で許容し、不足 metadata / root `module.yml` は container 内だけで正規化する。
  host source は変更しない。metadata があれば target root を extra module として追加する。
- module はすべて `-m` で明示して strict に検証する。host で path を解決し、空白を含む basename 全体で重複を判定する。
  root `CMakeLists.txt` / `Kconfig` に
  `build.cmake` / `build.kconfig`、`boards/` / `dts/` / `snippets/` に対応する `build.settings.*_root: .` が必要。
  host は必要な metadata file の存在だけを確認し、key と YAML 構造は container 内で workspace 変更 / 依存更新前に検証する。inline map / quoted key を text grep で拒否しない。`proto/zmk` のような入れ子 path も保持する。
- workspace へは `config/` だけ同期し、`ZMK_CONFIG` は container source の `config/` に向ける。
  manifest 外の top-level entry を prune するため、cache volume を repo / tool / 用途ごとに分離する。
  prune は overlay 復元後に行い、完全に取得できた west project 一覧だけを使う。
  一覧の失敗・部分出力は cache を保持して update を要求し、成功した update 後に再確認してから prune / stamp する。
- 前回 overlay を workspace 内 backup から復元してから今回の入力を適用する。directory 名が west project 名と
  一致すれば overlay、それ以外は extra module。復元 test で `--pristine` を使わない。
- import を含む `west manifest --resolve` の digest の変更 / 解決失敗、ZMK / project の欠落、
  `west list` の失敗、復元できない overlay で update する。解決できない manifest を ready と記録しない。
  update は設定回数 retry し、各試行直前に空白を壊さず stale index lock を除去する。
  update 失敗は、完全な project 一覧を確認でき、失敗 project を明示 local override が満たす場合だけ続行する。
- ccache は workspace の外側の cache volume に保存する。`CCACHE_IGNOREOPTIONS=-specs=*` は SDK specs が
  選択 image 内で固定されることが前提。SDK / image 変更時は cache の前提を再確認する。
  `--pristine` は west workspace と ccache を含む volume 全体を削除する。

### Parser と build

- CLI と環境変数の表は README で維持する。正の整数は十進表記として扱い、`00` を含む全ゼロを拒否する。
- top-level / include matrix、defaults、exclude、skip、alias key、artifact placeholder を保持する。
  exclude は CLI snippet 合成前の YAML 値で評価し、reset target は board ごとに重複させない。
- artifact 名を安全な file 名へ正規化し、拡張子が続く Windows 予約名も含めて拒否する。大小文字を無視した重複も拒否する。
- 並列 target はそれぞれ build directory と log を持つ。Ninja の compile 並列とは別物。
  外部 full / pristine workflow の既定 target 並列は 1。`--jobs` は manual tuning 用に保持する。

### Output と失敗

- firmware は target ごとに 1 個。`.uf2`、指定 fallback、`.hex`、`.bin` の順で選ぶ。
  host の列挙 / summary / checker は log と summary 自体を除き、同じ拡張子を認識する。予約出力名との衝突を拒否し、拡張子に path / glob / 先頭 dot / hyphen を許さない。
- run 名は `.build/run-YYYY-MM-DD_HH-MM-SS-pid-PID/`。`build.log` と `build-summary.txt` を必ず残す。
  開始済み run の作成 / 起動 / source copy / build / artifact copy 失敗も FAILED summary と error excerpt を残す。
  同名 container の作成に失敗しても既存 container を削除せず、この run が作成したものだけ cleanup する。
  create 後の操作は start / exec / copy / cleanup とも返された immutable ID を使い、名前の再利用で操作先を変えない。
- summary は Status、失敗時 Reason、Mode、Target、Docker image / cache volume、Elapsed、Built targets、Pristine、
  Build jobs、Fallback binary、Extra snippets、Module inputs、Files を持つ。
- Built targets は CR / ANSI を除いた log の行中から取得し、成功 build のみ firmware 数へ fallback する。
  checker は成功 status / mode、log、正の target 数と firmware 数の完全一致を要求する。
  古い summary に fallback の記録が無ければ `bin` と解釈する。規則外 run の summary と主要 field の重複を拒否する。
  保存先名の内部の `..` は許可し、親を表す path component だけを拒否する。
- artifact copy は失敗を呼び出し元へ返して summary を残す。main container log にも build stream を流す。
  子 process に `LD_PRELOAD` を伝える `stdbuf` は使わない。

### 外部 source と workflow

- URL / UNC / drive absolute / relative を区別し、slug 衝突を解消する。
  source ごとに clone directory / cache volume / container 名 / artifact を分ける。
- URL は clone 専用 container 内で retry つき clone し、bind mount でなく `docker cp` で host へ戻す。
  Windows でだけ作成不能な名前を警告つきで除き、Unix source は変えない。clone 作成失敗時に同名の既存 container を削除せず、自分が作成したものだけ cleanup する。
  host clone 先の削除失敗を無視して続行しない。失敗の修復後も、古い内容を消してから新しい clone を copy する。
- rolling queue は worker の実 exit を回収する。status file を書く前の異常終了も失敗として扱う。
  1 source の失敗で他 source を落とさず、空き枠に次の source を流す。
- 外部 source 自身の layout / API incompatibility と builder defect を区別する。
- source / workflow input / runner 名などは `env:` 経由で渡し、`${{ ... }}` を shell text に直接埋め込まない。
  `continue-on-error` で build failure を隠さない。
- hosted `Compatibility` は 3 OS の shell と Ubuntu Docker。`Self-hosted Build` は手動の標準 fixture smoke。
  外部 source matrix は custom label で routing し、選択された `runner.os` に応じて Git Bash / Bash を使う。
  必要 label と Docker access は runner user で確認し、全 runner offline なら queue に残ることを区別する。
- schedule は UTC cron、換算はコメントに残す。concurrency と timeout を保持する。
  Heartbeat は commit / push を含むため、この作業規約は実行を自動許可しない。

## 検証 gate

症状を host shell / copy / workspace / update / overlay / build / artifact / summary / workflow に分ける。
修正前に失敗する case か識別可能な negative control を既存 helper / fixture に追加し、原因を記録する。
同じ pattern が OS / workflow の片側に残らないか確認する。test は `bash <script>` で起動し、temp path は `pwd -P` で正規化する。

| 変更範囲 | 必要な確認 |
| --- | --- |
| 全変更 | syntax、LF、`git diff --check`、変更した文書の参照 |
| helper / summary | 該当する helper behavior test |
| copy / module / sync / cache | runner preflight、copy helper、関連 fixture の validate / build、output check |
| artifact / fallback | build fixture と output helper。`.uf2` 以外の選択も確認 |
| workflow | local syntax / helper と関係する run step。公開していなければ remote CI は未実行と報告 |

local / CI とも `bash .github/scripts/test.sh shell|docker|build|all` を入口とし、command と層の対応は README の Maintenance / 保守と検証に集約する。影響する build / validate の直後に output checker を実行する。
標準 validate の通常 / reset 追加、target shapes の CLI snippet 併用、標準 build、module override build と pristine 無しの
復元 build を、影響範囲に応じて残す。既存の証拠を上書きせず、新しい記録に command / source / image identity と raw failure を保存する。
実行中の shell script は書き換えない。修正後の source を固定して再実行する。
LF は `.gitattributes` / `.editorconfig` で統一し、検証のために working tree を reset / 書換えしない。
各検証は command / status / 時間 / raw log と前後の source checksum を新しい directory に残す。
Docker fixture は独立した条件を同一 container に集約し、parser は production を実行して順序と値を検査する。
実 firmware は標準、project overlay、pristine 無しの復元を一連で確認し、output checker には run を明示する。

west update の retry / stale lock / 部分失敗と復旧は、現行 image 内で command boundary を制御して検査する。
実際のネットワーク障害や別 west version の挙動まで検証したとは扱わない。
自動化の未充足範囲: 旧 image 系列での実 build、Docker 非 amd64 native host、および
GitHub hosted / self-hosted 上での公開後の実行。fixture build の成功だけでこれらを PASS にしない。

## 再発防止の原因と確認

新しい bug は、症状 / 原因 / 対応 / 確認を該当 boundary の行へ反映する。一度きりの結果や外部案件の履歴は追加しない。

| Boundary / 症状 | 原因と保持する対応 | 確認 |
| --- | --- | --- |
| Windows の Bash / path | WSL shim を避け Git Bash を明示。MSYS path を native Git 引数へ渡さない | syntax / copy / external helper |
| clone が host に現れない | 同期 drive 等の bind mount に依存せず docker cp で回収し、host destination だけ変換 | Docker contract の実 copy back / external helper |
| Windows で作れない clone 名 | trailing 空白 / dot、禁止文字、予約 device 名を clone container 内で除去 | Docker contract の禁止文字 / control / newline / 予約名 / 合法名保持と実 copy back |
| URL / UNC / drive relative の誤分類 | scheme と absolute path を区別し、relative path は list file 基準 | external helper |
| Bash 3.2 の unbound array | 空配列の展開を guard | hosted macOS shell |
| tar capability の不足 / 誤判定 | exclude は空 archive で実能力を確認し、help pipe の SIGPIPE に依存しない。NUL list は空入力で確認し、短縮 help の省略と機能不足を区別。非対応なら全 copy | host contract の大量 help / 非対応 tar、Docker contract の null 記載なし help / validate |
| 通常 content の欠落 | generated marker と .west を併せて確認。top-level 除外は root entry を選別し、同名の nested directory を保持 | copy helper の nested build / .cache / opt-out |
| 古い module の混入 | local_modules の自動読込を廃止し -m を正とする | copy helper |
| module 名の誤判定 / 別名への copy | 空白を含む basename を配列で完全一致比較し、`dir/.` は名前を付ける前に path を解決 | host の両順序 / 真の重複拒否 / container validate・sync / 実 copy |
| module metadata の見逃し / 誤拒否 | CMake / Kconfig / root settings を container 内の YAML 構造で strict に検証。host は file の存在を確認 | copy helper の inline map / module fixture |
| legacy target の事前拒否 | target だけ container 内で metadata 補完し、明示 module の strict 判定は保つ | legacy / snippet validate |
| ignored bulk の遅い copy | Git visible list と opt-out。deleted tracked を除き ignored tracked は保持 | copy helper |
| update の一時失敗 / lock | host の回数設定を container へ渡し、各試行前の lock cleanup で空白を保持 | 実 container の環境値 / retry / 空白つき lock / 2 回目の lock |
| 不完全な依存の再利用 | update 開始前に ready marker を無効化し、完全成功時だけ resolved manifest の stamp。旧記録も再検証し、local override での続行は upstream 成功と区別 | 失敗後の非空 checkout / local input を外した次回 / 成功 cache の再利用 |
| import 側の依存変更を見逃す | 入口 file だけでなく west が解決した manifest 全体を hash し、解決失敗を成功と記録しない | 実 west の local import 解決 / revision 変更 / 不正 import と修復後の再実行 |
| 不明な update failure の続行 | 最終試行の失敗名だけで判断し、missing list から失敗名を推測しない | unknown / unsupported / 複数 project / 前の試行との混在 |
| 不完全な project 一覧による cache 消失 / 誤った続行 | 一覧全体の成功 status を確認し、部分出力を集合として使わない。root は配列で完全一致比較し、復元後に一度ずつ整理 | 一覧失敗・部分出力 / 更新後の再確認 / root の空白・hidden entry / 復元順序 / 削除失敗 |
| pristine 後の restore assertion | pristine は volume を消すため、restore test は通常再 build | module fixture |
| overlay 適用中断の復元漏れ | destination を書き換える前に backup の復元記録を残す | apply の部分コピー失敗と input を外した次回の復元 |
| overlay 復元失敗後も build が進む | if 条件内の関数では errexit に依存せず、copy と削除の失敗を明示して返す。復元失敗時はその backup と stamp を消さず停止 | container workspace の rsync 失敗 / tar fallback の削除失敗、実 firmware の復元 |
| overlay path の過剰な拒否 | 絶対 path と親を表す独立した `..` component を拒否し、名前の途中の `..` は許可 | container workspace の合法名 / absolute / parent path |
| shared cache の content 消失 | prune の対象 workspace を tool / repo ごとの volume へ分離 | 運用契約 |
| suffix revision の誤 image | version 系列の suffix も tag 選択へ含める | revision validate |
| target が log / artifact を取り合う | target ごとに build directory と log を分離 | jobs 付き fixture |
| CMake 引数の欠落 / 空白の変化 | literal list の文字列を trim せず、shlex の結果を NUL 区切りで渡す。空引数を捨てない | container の実 argv 検査（空 / 引用 / 前後空白 / glob / semicolon / backslash / extra） |
| 並列失敗数の桁あふれ | 失敗数は整数の data として保持し、8-bit の終了 status に詰めない | container の partial batch / 後続未開始 / 256 件失敗と target log 順序 |
| Docker log が空 | main process が stream を tail し exec output も tee する | kept container の docker logs |
| 旧 image で GLIBC error | stdbuf の LD_PRELOAD を子に伝えない | 旧系列 image build |
| target count の抽出漏れ | CR / ANSI / prefix を除き、成功時は firmware 数へ fallback | output helper |
| partial / 過剰 / 矛盾した output の受理 | SUCCESS / mode / positive count / exact count と主要 field の一意性を要求 | output helper |
| 保存先名の過剰な拒否 | `..` は独立した path component の場合だけ拒否 | output helper の case..name / 親 traversal |
| host setup / copy の記録欠落 | EXIT で phase の FAILED summary を残し error を log に保存 | copy helper の failure injection |
| fallback の列挙漏れ | 列挙を共通化し summary に extension を記録 | output helper の custom / invalid extension |
| ccache が全て uncacheable | SDK specs の解決差を吸収し cache volume 上へ保存 | copy helper の実 compiler 2 回目 hit / override |
| 同名 source の衝突 | slug を一意化し source 単位に clone / cache / container を分離 | external helper |
| source queue の待ち / 終了漏れ | rolling 補充、worker 実 exit の回収、全ゼロ幅の拒否 | external helper の killed / failure / 後続成功 |
| 並列負荷が過大 | target 並列と Ninja 並列が重なるため full / pristine の既定は 1 | manual tuning / workflow input |
| clone 一時失敗 / host コピー先の削除失敗 | retry と daemon preflight。host コピー先を削除できなければ取得前に停止し、修復後は古い file を混ぜない | external helper の start retry / cleanup failure / 同じ host コピー先での復旧 |
| runner queued | 必要 label / online / busy / 登録先を確認。OS 非固定 matrix では選択 OS で分岐 | runner 状態 / 手動 workflow |
| schedule の誤認 | UTC cron、換算コメント、concurrency / timeout | workflow |
| workflow data の command substitution | input と runner 名を env 経由で quote | local workflow step / external helper |
| host guard が未到達でも PASS | Windows の fake-bin path を pwd -P で正規化し、sentinel と拒否条件を両方確認 | hosted shell / helper |
| helper の permission / temp path 差 | bash 起動と pwd -P 正規化を使い executable bit に依存しない | hosted 3 OS shell |
| 大きな file の CRLF 見逃し | pipe を使わず grep の raw byte mode で直接検査し、Windows text 変換 / Control-Z / SIGPIPE の見逃しを避ける | LF helper の大きな入力 / mixed / bare CR / Control-Z / 実 checkout / Git failure |
| 不正 YAML 型 / quote / NUL の見逃し | None と falsey の型を区別し、scalar list と cmake 引数の quote を検査。Bash の read が捨てる NUL は shell への受け渡し前に拒否 | container parser の wrong-empty type / nested map / null / unclosed quote / board / shield / snippet / cmake-args の NUL |
| 拡張子つき Windows 予約名 | artifact の最初の dot より前も検査して拒否 | container parser の CON.txt / lPt1.extra |
| container 名の再利用による操作先の変化 | build / clone とも create が返す immutable ID で以後の操作を行い、create 失敗時は cleanup しない | host の start / copy / validate / artifact failure、external helper の create / retry / start / copy failure と全操作の ID |
| test container の誤 cleanup | validate / firmware log の create が返した immutable ID と成功した cache reader の ID だけを回収し、要求した名前を所有の証拠にしない | host helper の create 衝突 / start 失敗と Docker / firmware fixture |
| 検証 log による source drift 誤判定 | 記録は repository 外か directory 全体が Git ignored の場所に限定し、visible な保存先は開始前に拒否 | host helper の visible evidence 拒否と canonical runner |

## 完了判定と報告

最新 scope と必要最小限の差分を再確認し、未追跡 file / 意図しない差分 / LF / syntax / 必須 check を確認する。
変更 file、PASS / FAIL / 未実行と理由、残る実行環境の境界、commit / push の有無と worktree の状態を報告する。
公開操作は明示指示がある場合だけ行い、公開した場合は関係する remote CI の結果も確認する。
