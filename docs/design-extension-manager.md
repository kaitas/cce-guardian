# 設計メモ：Claude Extension Manager（次のバージョン候補）

2026-11-03 時点の検討。未実装。

## 目標
Default プロファイルには CCE を置かず、代わりに小さな「Manager」を置いて、
別プロファイル・別フォルダにある複数の CCE（Claudeアカウントごと）を見渡し、止められるようにする。

## Chrome の制約（設計の前提）
- 拡張機能はプロファイル単位。Default の拡張機能から、ほかのプロファイルの拡張機能は見えず、操作もできない（`chrome.management` は自分のプロファイル内だけ）
- ほかの拡張機能のストレージは読めない。CCE がどの Claude アカウントにサインインしているかは、拡張機能からは直接分からない
- ネイティブメッセージングのホスト登録（HKCU / ~/Library/...）は OS ユーザー単位で、全プロファイル共通

## 構成案
```
[Default プロファイル]          [CCE用プロファイル / --user-data-dir フォルダ ×N]
  Manager 拡張（CCEなし）          CCE + Companion 拡張（名札・キルスイッチ）
          \                               /
           \__ ネイティブメッセージング __/
                       |
              ローカルの Manager ホスト（台帳 devices.json を持つ）
                       |
          ledger.sh（Claude側から見た deviceId 一覧）と突き合わせ
```

| 部品 | 置き場所 | 権限 | 役割 |
| --- | --- | --- | --- |
| Manager 拡張 | Default | `nativeMessaging` のみ | 全コンテキストの一覧表示、Switcher（フォルダを指定してChrome起動）の呼び出し |
| Companion 拡張 | 各 CCE プロファイル | `management`, `nativeMessaging`, `tabs` | 名札バッジ、CCE の有効/無効、ブロックリストのサイトで自動停止、状態をホストへ報告 |
| Manager ホスト | OS ユーザー | ローカルファイルのみ | 台帳、`chrome --user-data-dir=...` の起動、guardian 点検の実行 |

## 守ること
- Default の Manager には `debugger` も `<all_urls>` も持たせない。Default は「強い拡張がない場所」であることが価値
- ネットワーク通信なし。台帳はローカルのみ
- Companion の `debugger`（アタッチ中のタブ表示）は任意機能にし、既定では使わない

## 未確認
- Claude 側の deviceId と、ブラウザ側で Companion が知りうる情報を結びつける方法（現状は ledger の手動ラベル）
- CCE のサインイン先アカウントを外から知る方法
