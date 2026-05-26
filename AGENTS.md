# AGENTS.md

このリポジトリでは日本語で応答します。

`build.sh` を変更する agent は、詳細仕様として `AGENT_SPEC.ja.md` を確認してください。

必ず守ること:

- host 側の必須依存は Docker と Bash だけにする
- Windows / macOS / Linux の差を build script 内で吸収する
- user が明示しない限り push しない
- user が明示しない限り commit しない
- 既存の user changes を revert しない
- `build.sh` を主対象にし、workflow / docs は build script 変更に直接関係する場合だけ触る
- `zmk`, `zephyr`, `modules`, `tools` などを無条件に generated dependency と決めつけない
- artifact を `.uf2` 固定と仮定しない
- host -> container -> persistent workspace の 2段階 copy を前提に設計する

bug を見つけた場合:

- まず原因箇所を host shell / host -> container copy / workspace sync / build / artifact / workflow scheduling に分ける
- 修正できる bug は最小差分で直し、同系統の再発を防ぐ確認を追加または実行する
- 対応した bug は `AGENT_SPEC.ja.md` の「対応済み bug / 注意点」に、症状 / 原因 / 対応 / 確認として追記する
- 仕様判断や user 操作が必要で直せない場合は、未対応理由と必要な次 action を明記する

完了報告では、変更 files、実行した check、未実行の理由、commit / push の有無を明記してください。

変更後は可能な範囲で実行してください:

```bash
bash -n ./build.sh
git -c core.autocrlf=false diff --check
./build.sh validate .github/fixtures/ci-zmk-config --settings-reset
```

artifact / fallback / sync を触った場合は、`AGENT_SPEC.ja.md` の追加検証も確認してください。
