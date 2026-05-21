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

変更後は可能な範囲で実行してください:

```bash
bash -n ./build.sh
git -c core.autocrlf=false diff --check
./build.sh validate .github/fixtures/ci-zmk-config --settings-reset
```

artifact / fallback / sync を触った場合は、`AGENT_SPEC.ja.md` の追加検証も確認してください。
