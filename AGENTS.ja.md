# エージェント契約

この file は [AGENTS.md](AGENTS.md) の日本語訳です。標準・正本は英語版です。
両版を同期し、差異があれば英語版に従って日本語訳を修正します。

利用方法・CLI・環境変数・runner 運用は
[README.ja.md](README.ja.md) と [README.md](README.md)、保守契約はこの file に集約します。
外部案件の repo 名・commit hash・日付・個別の実測値・一度きりの結果を文書へ追加せず、
command / source / image identity と raw log は `.build/` の新しい実行記録に残します。

## 公開時のプライバシーとローカル実行

この規則は、公開または外部共有に向けて用意する情報に適用します。
許可された作業中は、実装・診断・識別情報の照合・検証に必要な実際の local path、設定、
host / terminal / device の識別情報、非公開の test 証拠を調査・利用できます。
その local access 自体は、作業範囲外の収集や開示を許可しません。

公開する commit / push / PR / release / 文書・site 出力 / CI artifact を準備する前に、
source、comment、AGENTS file、example、test fixture、log、screenshot、生成 file、metadata を含む
実際の公開対象を確認します。user に関係する名前・好み、非公開の absolute path・local 環境詳細、
workstation / terminal の識別情報、個別 device の label・port・serial・address・pairing / bond 識別情報、
認証情報、user / device 固有の test・測定履歴を除外します。生成・upload される artifact も確認し、
source の文章だけの確認で済ませません。

公開物には repository-relative path、文書化した変数・placeholder、中立な名前、明確に合成した fixture を使います。
公開を明示した project 識別子、既存の attribution、標準 API / product / platform 名、再現可能な support 要件は
技術的な project 情報です。一人の user の実環境を project 要件として扱いません。
特に、対応 platform の文書化と user の device の特定は区別します。

正確な証拠や device 照合に必要な場合、正確な原本と識別情報は適切な非公開・local 作業記録に保持します。
assertion を弱めたり結果を捏造したりせず、公開用に情報を除いた別コピーを作成し、
変更していない raw record とは説明しません。これらの詳細を開示せずに有用な証拠を共有できなければ、
非公開のまま保持し、公開できる検証の限界を明記します。最終の公開 snapshot と artifact を再確認します。
version control、公開、device 書き込み、reset、data 消去に関する既存の許可要件も引き続き適用します。

## 作業範囲と責務

### 作業の境界

- 最新の user 指示と既存差分を最初に読み、user changes を保持する。
- commit / stage / push / PR 作成・更新 / merge / tag / release は、各操作の明示指示がある場合だけ行う。
  test 成功や milestone を許可と解釈せず、無関係な変更を含めない。
- 主対象は `build.sh`。helper / workflow / docs はその契約に直接関係する範囲だけ扱い、
  keyboard / module source、実機 firmware、settings を変更しない。
- 単体 build で常に有効な機能は `build.sh` に置き、環境変数は opt-out が必要な場合だけ追加する。
  新しい script / container / fixture を増やす前に既存の責務・scenario へ統合できるか確認する。
- production host の必須依存は Docker と Bash。標準 Unix tool を使い、追加 install を前提にしない。Git は optional。
- WSL 全体の memory 回収・停止・設定変更や、他 tool の監視を builder に取り込まない。
  中間 file の削除、依存 / ccache の再利用、host に残す成果物・証拠を区別する。

### fileごとの責務

| 場所 | 責務 |
| --- | --- |
| `build.sh` | 1 target directory の build / validate / clean、host copy、container workspace、成果物回収 |
| `scripts/auto-build-external.sh` | source list / JSON matrix、slug 一意化、source process の rolling queue |
| `scripts/build-external-source.sh` | 1 source の clone / local path 解決、builder 起動、clone cleanup |
| `scripts/source-common.sh` | wrapper 共通の分類・名前処理、Windows 非互換 clone path の除去 |
| `repos.txt` | 1 行 1 source。relative path は list file の directory 基準 |
| `.github/fixtures/` | 標準 firmware、validate 専用 target shapes、module override |
| `.github/scripts/` | 共通検証入口、runner / LF / output check、既存 helper behavior test |
| `.github/workflows/` | hosted compatibility、手動 self-hosted smoke、外部 source matrix、heartbeat |

source 列挙・clone を `build.sh` に戻さない。source 並列、target 並列、Ninja compile 並列を分ける。
host → container → persistent workspace の 2 段階 copy と host への成果物回収を別の境界として扱う。

## Host と source copy

### host互換性とcapability

- Windows / macOS / Linux の差分は script が吸収し、Windows は WSL shim を避け Git Bash を明示する。
  Docker 用の MSYS path 自動変換停止下では native `git.exe` に MSYS path を渡さず、directory へ `cd` する。
- Bash 3.2 に対応する。`set -u` 下の空配列は `${array[@]+"${array[@]}"}` または要素数で guard する。
- container 作成前に空 archive で `tar --exclude` を実行する。NUL list は `--null -T` の空入力を実行して確認し、
  非対応なら Git file list を使わない。短縮 help の省略や help pipe の SIGPIPE を能力不足と解釈しない。

### copyするfileの選択

- Git working tree は tracked と非 ignored untracked を NUL 区切りで copy し、削除済み tracked を除き、
  ignored tracked は保持する。`ZMK_COPY_IGNORED=1`、Git 無し / 失敗、非 working tree、空一覧では固定除外つき全 copy。
- 固定除外は `.git` / `.west` / `__pycache__` と top-level の `.zmk` / `.build` / `.cache` / `.ccache` /
  `.vscode` / `build` / `dist` / `node_modules` / `out` / `tmp` / `zmk_search`。
  top-level は root entry で選別し、OS ごとの tar anchor 解釈に依存しない。同名の nested content を保持する。
- `zmk` / `modules` / `tools` / `bootloader` / `optional` は、source に `.west`、対象 tree に `.git` marker が
  ある場合だけ generated dependency として除外する。名前だけでは除外せず、`local_modules/` は自動探索しない。

## Layout・module・application

### repository layout

- 入口は `build.yaml` と `config/west.yml` を持つ repo root。direct config directory / custom config path は扱わない。
  board 定義は root / module の `boards/` を標準とし、既存の `config/boards` は compatibility path として許容する。
- target の legacy `zephyr/` content は warning で許容し、不足 metadata / root `module.yml` は container 内だけで正規化する。
  host source は変更せず、metadata があれば target root を extra module に追加する。

### 明示module

- module はすべて `-m` で明示する。`dir/.` も host で path 解決してから、空白を含む basename 全体で重複判定する。
  明示した隠し directory も同じ一覧で検証・適用し、内部の path 一覧は NUL 区切りで渡す。
- 明示 module の root `CMakeLists.txt` / `Kconfig` は `build.cmake` / `build.kconfig`、`boards/` / `dts/` / `snippets/` は
  対応する `build.settings.*_root: .` を要求する。host は必要な metadata file の存在だけを確認する。
  YAML 構造・key は container 内で workspace 変更 / 依存更新前に strict に検証し、inline map / quoted key を許容する。
  `build.cmake` / `build.kconfig` の path は文字列とし、target の正規化前にも型を確認する。
  `proto/zmk` などの nested path を保持する。

### application

- 通常は `zmk/app`。top-level `application` は repo 内の `CMakeLists.txt` を持つ相対 directory を指定する。
  absolute / parent traversal / repo 外へ出る symlink を拒否する。standalone は manifest の `zephyr` project から package を
  解決し、extra module を `ZEPHYR_EXTRA_MODULES`、通常の ZMK は `ZMK_EXTRA_MODULES` へ渡す。
  standalone でも target の root settings を補完する。明示した module build 宣言は保持し、application の
  CMake / Kconfig 入口から `build.cmake` / `build.kconfig` を推定しない。

## Persistent workspace と cache

### workspaceの所有

- workspace へは `config/` だけ同期し、ZMK の `ZMK_CONFIG` は fresh な container source の `config/` に向ける。
  manifest 外の root を prune するため volume は repo / tool / 用途ごとに分離する。
  同じ workspace を変更する build は OS lock で排他し、競合時は同期・依存更新・削除前に停止する。
  lock file は prune 対象の外に置き、build process の終了時に解放する。保持 container の存在だけで再利用を拒否しない。

### overlayの復元とprune

- 前回 overlay を workspace 内 backup から復元してから今回 input を適用する。directory 名が west project 名と一致すれば
  overlay、それ以外は extra module。destination を変更する前に backup の復元記録を残す。
- 復元の copy / 削除失敗は明示して返す。if 条件内の関数の errexit に依存せず、失敗時は該当 backup / stamp を残して停止する。
  overlay path は absolute と親を表す独立した `..` component を拒否し、名前の途中の `..` は許容する。
  復元済み / 再取得が必要な状態を project ごとに atomic に記録してから backup を整理する。
  後続の失敗・中断後も復元済み project を再削除しない。旧2列の記録を受け入れる。
- prune は復元後、完全に成功した `west list` の結果だけで行う。root は空白 / hidden entry を含め配列で完全一致比較し、
  1 回ずつ整理する。一覧失敗・部分出力では cache を保持して update を要求し、成功後に再確認してから prune / stamp する。
  root 選択前に workspace 内の親 component を正規化し、workspace 外へ出る path は拒否する。
  削除失敗を無視しない。

### 依存の再利用と更新

- import を含む `west manifest --resolve` 全体の digest 変更 / 解決失敗、必要な ZMK / project の欠落、`west list` 失敗、
  復元不能な overlay では update する。入口 file の hash だけで再利用判定しない。
- update 前に ready marker を無効化し、完全成功時だけ resolved manifest を stamp する。旧記録も再検証する。
  失敗 / 中断後の非空 checkout や未解決 manifest を ready と扱わない。
- update は設定回数 retry し、各試行直前に空白を壊さず stale index lock を除去する。失敗後の続行には完全な project 一覧と、
  最終試行で明示された全失敗 project を満たす local override が必要。unknown / unsupported failure を missing list から推測せず、
  前の試行の失敗名を混ぜない。local override での続行を upstream update 成功と記録しない。

### cacheの寿命

- ccache は west workspace の外側、cache volume 上に保存する。`CCACHE_IGNOREOPTIONS=-specs=*` は選択 image 内で
  SDK specs が固定される前提。SDK / image 変更時は前提を再確認し、revision suffix も image tag 選択へ含める。
- `--pristine` は build / validate とも builder が volume 全体を削除する。完全な volume 一覧で対象を照合し、未作成なら続行、
  一覧 / 削除失敗なら container 作成前に停止する。依存 / ccache を含むため overlay 復元 test では使わない。

## Parser・build・output

### CLIとYAML

- 公開 CLI / 環境変数の表は README に維持する。正の整数は十進表記として扱い、`00` を含む全ゼロを拒否する。
- top-level / include matrix、defaults、exclude、skip、alias、artifact placeholder を保持する。
  exclude は CLI snippet 合成前の YAML 値で評価し、reset target は board ごとに重複させない。
- None と falsey の型を区別し、scalar list / quote を検証する。board / shield / snippet / CMake 引数の NUL は shell 受け渡し前に拒否。
  literal list は trim せず、shlex 結果は NUL 区切りで渡し、空引数・引用・前後空白を保持する。
- artifact 名は安全な file 名へ正規化する。最初の dot より前も検査して Windows 予約名を拒否し、大小文字を無視した重複と
  log / summary などの予約出力名との衝突も拒否する。

### targetの実行

- target ごとに build directory / log を分ける。並列失敗数は整数 data として保持し、8-bit exit status に詰めない。
  batch の失敗を回収し、未開始の後続 target を進めず、log 順序を保持する。外部 full / pristine の既定 target 並列は 1。
- 各 target は subshell EXIT で成功 / compile / artifact 選択・copy 失敗時とも中間 directory を削除し、依存 / ccache を保持する。
  削除失敗を log に残して成功を失敗に変え、元の build error の終了 status は保持する。

### 成果物とsummary

- firmware は target ごとに 1 個、`.uf2` → 指定 fallback → `.hex` → `.bin` の順。host 列挙 / summary / checker は
  log / summary 自体を除き同じ拡張子を認識する。拡張子には path / glob / 先頭 dot / hyphen を許可しない。
- run は `.build/run-YYYY-MM-DD_HH-MM-SS-pid-PID/`。開始済み run は setup / pristine / create / start / source copy /
  build / artifact copy / cleanup の失敗にも `build.log`、FAILED summary、Reason と error excerpt を残す。
  artifact copy の失敗は呼び出し元へ返す。main container log にも build stream を流し、`stdbuf` の `LD_PRELOAD` を子へ伝えない。
  SIGINT / SIGTERM は理由と終了 status を確定して同じ終了処理へ渡す。保持指定の container は中断時に停止して残す。
  ID 回収、終了 handler の入口、cleanup 中は signal を遅延する。先の build failure を保持し、cleanup 後に最終 summary を1回 atomic に公開する。
  summary 公開前に終了 status を確定する。firmware 存在確認では列挙を最後まで読み、SIGPIPE を誘発しない。
- summary の field は Status、失敗時 Reason、Mode、Target、Docker image / cache volume、Elapsed、Built targets、Pristine、
  Build jobs、Fallback binary、Extra snippets、Module inputs、Files。主要 field の重複と規則外 run の summary を拒否する。
- Built targets は CR / ANSI / prefix を除いた log 行から取得し、成功 build のみ firmware 数へ fallback する。
  checker は成功 status / mode / log / 正の target 数 / firmware 数の完全一致を要求する。旧 fallback 未記録は `bin`。
  保存先名も独立した `..` component だけを拒否し、`case..name` は許可する。

## Container・外部 source・workflow

### containerの所有

- build / clone / test は create が返した immutable ID で start / exec / copy / cleanup を行う。
  create 失敗時に同名の既存 container を消さず、要求した名前を所有の証拠にしない。
- container 削除失敗は log / FAILED summary に反映し、先の build failure の理由・exit status を保持する。
  `ZMK_KEEP_CONTAINER=1` を尊重する。clone container の削除失敗では retry / builder 起動へ進まない。

### 外部source

- URL / UNC / drive absolute / relative を区別し、slug 衝突を解消する。source ごとに clone / cache / container / artifact を分ける。
  JSON は shell で扱える全制御文字を escape し、source 選択後も元の index を保持する。
  CI source selector は常に list file を指定し、不足する list は matrix 解決時に拒否する。
- URL は daemon preflight 後、clone container 内で retry つき取得し、bind mount ではなく `docker cp` で host へ戻す。
  Windows だけ trailing 空白 / dot、禁止文字・control・newline、予約 device 名を警告つきで除き、合法名と Unix source は保持する。
- host clone 先の削除失敗では取得 / copy を止め、修復後も古い file を消してから copy する。終了時も clone コピー削除後だけ
  成功を報告する。先の clone / build failure があれば削除失敗も併記し、解決済み clone root 直下だけを削除する。local source は保持。
- rolling queue は worker の実 exit を回収する。status file 前の異常終了も失敗とし、他 source は落とさず空き枠へ次を流す。
  外部 source の layout / API incompatibility と builder defect を分ける。

### workflow

- source / input / runner 名などは `env:` 経由で quote し、`${{ ... }}` を shell text に直接埋め込まない。
  runner が開始前に表示する値には非公開の source 情報を置かず、matrix / step env は数値 index に限定する。
  source selector は event payload から実行時に非公開 file へ準備し、source の解決・選択は wrapper が行う。
  `continue-on-error` で build failure を隠さない。
  CI console と artifact は固定項目の公開用 report に限定する。raw log / firmware は local に保持し、
  公開用コピーを unchanged raw record と呼ばない。自動 upload は既知の report path だけを許可する。
- hosted Compatibility は 3 OS shell / Ubuntu Docker、Self-hosted Build は手動 smoke。外部 matrix は custom label で routing し、
  `runner.os` に応じて Git Bash / Bash を使う。label / Docker access は runner user で確認し、offline による queued を失敗と混同しない。
- schedule は UTC cron と換算 comment、concurrency / timeout を保持する。Heartbeat の commit / push をこの契約で自動許可しない。

## Container 内での test 実行

自動 test、build、依存環境の準備は Docker 内で実行します。host の入口は container の起動と結果の出力を
行えますが、host で test runtime を実行したり test package / toolchain を install したりしません。
対象 repository の source は read-only mount にできます。test 専用の ZMK / Zephyr / tool checkout、
runtime 環境、一時 file、build 出力、cache は container image または named volume に保持します。
test は host の隣接 dependency checkout や非公開の absolute path を必要としないものにします。

選択した revision は container 内で解決・検証します。不足する依存は分離した container workspace に明示的に
準備し、共有 cache や pin を暗黙に更新しません。対象 repository の全 scenario、assertion、必須 matrix を保持します。
hardware の受け入れ確認には文書化された device access が必要です。container transport が利用できない場合は
BLOCKED と報告し、host 実行や mock による受け入れ確認で代用しません。確認済みの証拠だけを出力し、
公開時のプライバシー規則を維持します。

### Container test 実行の高速化

準備済みの container 環境、永続 cache、上限を設けた並列実行で所要時間を短縮します。
必須の全 scenario、assertion、negative control、sanitizer、対応 core variant、反復を保持します。

- 環境準備と test 実行を分離します。container image は digest で固定し、依存 revision を明示的に解決します。
  image、toolchain、依存 revision、lockfile が一致する場合だけ準備済み環境を再利用します。
  通常の test 実行中に依存 input を fetch / update しません。不足 input は依存する確認だけを block します。
- dependency checkout、install 済み test 環境、一時 file、build directory、cache は container image または
  named volume に保持します。大量の file access には Linux filesystem を優先します。対象 source を staging する場合は、
  関係する untracked file を含む必要な test / compiler input をすべて保持し、source identity と実行前後の変化を確認します。
- 明示的に選択した compiler / package cache は、対応する identity / concurrency check とともに再利用します。
  非互換環境は分離します。独立 job 間で書き込み可能な build directory や変更可能な install 済み dependency tree を
  共有しません。必須の clean-cache check を保持し、その確認には分離した新規 cache を使います。
- 各対象 repository の正式な test 入口を container 内から実行します。共通 orchestration は入口の選択・schedule・結果収集を
  行えますが、assertion と fixture は対象 repository に置きます。Docker の入れ子起動と、互換 job 間の環境準備の繰り返しを
  避けます。各 job の環境、作業 file、出力を分離します。
- 並行する suite、target、compiler job、test worker 全体で、設定可能な共通の CPU / memory budget を適用します。
  入れ子の並列実行も計上します。独立 job だけを並列化し、必要な実行順序と出力順序を保持します。
- 1 回の run では、必須 binary を異なる input / configuration variant ごとに 1 回 build し、同一条件で必要な反復には
  その同じ binary を再利用します。各反復に必要な初期状態を用意します。必須 test はすべて実行し、cache された artifact や
  過去の PASS 記録を新たな test 実行の根拠にしません。
- build と証拠には新規 directory を使います。実際の command、exit、完了 marker、順序を保った出力、
  source / dependency / image identity、cache 設定を記録します。準備・staging・build・実行・検証を別々に計測します。

quick / full の既存契約は維持します。interface / infrastructure の変更には引き続き対象 repository の完全な matrix が
必要です。同等の input と check で高速化を評価し、cold / warm run を分けて報告し、失敗も保持します。

## 検証 gate と再発防止

不具合は host / copy / workspace / update / overlay / build / artifact / summary / workflow の境界で分類する。
修正前に失敗する case または識別可能な negative control を既存 helper / fixture に追加し、原因・対応・確認を
該当する契約と test に反映する。重複した bug 履歴を追加せず、既存の有効な回帰 assertion を削除・緩和しない。
OS / workflow の片側に同じ問題が残らないか確認する。

### 必須確認

| 変更範囲 | 必須確認 |
| --- | --- |
| 文書のみ | LF、`git diff --check`、変更した path / link / CLI 参照。文書のみを理由に firmware suite は実行しない |
| code / helper / workflow | 該当する syntax、LF、`git diff --check`、関連する behavior / build gate |
| helper / summary | 該当 behavior test と失敗時の status / reason / output |
| copy / module / sync / cache | runner preflight、copy helper、関連 validate / firmware、直後の output check |
| artifact / fallback | firmware fixture と output helper。非 UF2 の選択も確認 |
| workflow | YAML / run step syntax、関連 helper / step。未公開なら remote CI は未実行 |

local / CI は `bash .github/scripts/test.sh shell|docker|build|all` を入口とし、層の対応は README に置く。
標準 validate（通常 / reset）、target shapes と CLI snippet、標準 firmware、project overlay / extra module、
pristine 無しの復元を影響範囲に応じて確認し、各成功 build / validate の直後に run を明示して output checker を実行する。

### 証拠と回帰fixture

- 実行ごとに新しい repository 外または directory 全体が Git ignored の記録先を使う。visible な内部保存先は開始前に拒否する。
  command / status / 時間 / source checksum 前後 / image identity / raw failure を残し、既存証拠を上書きしない。
- 実行中の script を編集しない。修正後の source を固定して再実行し、前後 checksum が違う結果は最新 source の PASS としない。
- test は `bash <script>`、temp path は `pwd -P` を使う。host guard は到達 sentinel と拒否条件の両方を確認する。
  executable bit や Windows fake-bin の未正規化 path に依存しない。
- Bash 用 symlink fixture は Git Bash の copy fallback を避け、作成後に `-L` で確認する。
  必要な MSYS link mode は作成 command だけに指定し、権限不足による skip や拒否 assertion の省略で代用しない。
- LF は `.gitattributes` / `.editorconfig` に従う。raw byte を直接検査して CRLF / bare CR / Control-Z / 大きな入力 /
  Git failure を見逃さず、検証のために working tree を reset / 書換えしない。
- 独立した Docker 条件は同一 container に集約する。parser は production を実行して値・順序・実 argv を検査する。
  update retry / 空白つき stale lock / 部分失敗と復旧は現行 image 内の command boundary を制御して確認する。
- test container も取得済み ID だけを cleanup する。test cache は専用とし、明示指定の再利用 cache と自動作成 cache の所有を分ける。
- local / remote CI / 物理動作を分ける。実ネットワーク障害、別 west version、旧 image の実 build、非 amd64 native host、
  公開後の hosted / self-hosted 実行は、対応する証拠なしに fixture 成功から PASS としない。

## 完了判定と報告

最新 scope、既存差分の保持、不要な新規 file / 意図しない差分、LF / syntax / 必須 check を再確認する。
変更 file、PASS / FAIL / 未実行と理由、残る環境の境界、commit / push の有無、worktree の状態を報告する。
公開は各操作の明示指示がある場合だけ行い、公開した場合は関係する remote CI の結果も確認する。
