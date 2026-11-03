# AGENTS.md

AIエージェント（Claude Code など）がこのリポジトリを触るときのルールです。

## 目的
Claude in Chrome 拡張機能（`fcoeoabgfenejglbffodgkkbkcdhcgfn`）を使うWindows PCの点検と、管理ポリシーの設定。

## 守ること
- `guardian.ps1` はネットワーク通信をしない。`Invoke-WebRequest` などを追加しない
- パスワード・Cookieの値・URLそのものを読み取る処理を追加しない。ドメイン名の一致判定だけにとどめる
- Windows PowerShell 5.1 で動くこと（`??`、三項演算子、`-Parallel` は使わない）
- `guardian.ps1` は UTF-8 (BOM付き) で保存する。BOMがないと 5.1 で日本語が化ける
- 既定モードは `Check`（変更なし）のまま。レジストリを書く処理は必ずバックアップを先に取る

## テスト
Linux/macOS の pwsh でも点検部分は動く。`-ChromeUserData` に偽のプロファイルフォルダを渡し、`USERPROFILE` と `APPDATA` を差し替えて実行する。レジストリ部分（Apply/Undo）は Windows 実機で確認する。
