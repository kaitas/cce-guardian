# cce-guardian

**Audit Chrome profiles, block banking sites via managed policy, and map which Claude account controls which browser — for Claude in Chrome.**

> One Claude account can drive every browser it's connected to — and every login inside them. See what your agent can reach, then fence it off.

> **Unofficial.** This project is not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic.

Claude in Chrome 拡張機能（ID: `fcoeoabgfenejglbffodgkkbkcdhcgfn`）は、あなたのChromeプロファイルの権限で、ログイン中のすべてのサイトを操作できます。さらに、その拡張機能がサインインしているClaudeアカウントからは、チャット・アプリ・クラウドのセッションのどれからでも、つながったブラウザを操作できます。

このツールは、その「手の届く範囲」に銀行・カード・行政サイトや機微なファイルが入っていないかを点検し、拡張機能の管理ポリシーでブロックを設定し、どのClaudeアカウントからどのブラウザが見えるかを台帳にします。合言葉は「**盗まれてもいい環境で使う**」です。

| 部品 | 内容 | Windows | macOS |
| --- | --- | --- | --- |
| `guardian.ps1` | プロファイル・ファイル・Claude設定の点検、ポリシーの書き込み | ✅ | 予定（v0.2） |
| `probe/probe.sh` / `probe.ps1` | 指定したマシンのChromeでURLを開く実験（読み取りのみ） | ✅ | ✅ |
| `probe/ledger.sh` | Claudeアカウント × deviceId の台帳 | WSL/Git Bash | ✅ |
| Manager 拡張機能 | 複数のCCEを見渡して止める | 設計中（[docs](docs/design-extension-manager.md)） | 設計中 |

### English quick start

```powershell
# Windows: audit only (changes nothing)
powershell -ExecutionPolicy Bypass -File .\guardian.ps1
# Block banking / government sites for Claude in Chrome (current user, no admin)
powershell -ExecutionPolicy Bypass -File .\guardian.ps1 -Mode Apply
```

```bash
# macOS: which browsers can the current Claude account reach?
./probe/ledger.sh
```

Read the script before you run it. It makes no network calls and never reads passwords, cookie values or visited URLs — only whether a domain name appears.

## 何を調べるか

| 区分 | 点検内容 |
| --- | --- |
| Chromeプロファイル | どのプロファイルに拡張機能が入っているか／有効か／「サイトへのアクセス」の範囲／ファイルURLへのアクセス／シークレットモード許可／拡張機能の同期 |
| 金融・行政の痕跡 | 拡張機能と同じプロファイルの保存パスワード・Cookie・閲覧履歴に、ブロックリストのドメインがあるか |
| 自動入力 | パスワード保存・カード自動入力・ダウンロード確認の設定 |
| ファイルアクセス | Claude DesktopのMCPがドライブやユーザーフォルダ全体を開けていないか／Claude Codeの権限モード／拡張機能と通信できるローカルアプリ |
| 機微ファイル名 | デスクトップ・ドキュメント・ダウンロードに「マイナンバー」「通帳」「確定申告」「.env」「id_rsa」などの名前のファイルがないか（中身は開かない） |
| 管理ポリシー | `blockedUrlPatterns` と `forceLoginOrgUUID` が設定済みか |

最後に「盗まれても大丈夫度」を100点満点で表示します。

## プライバシー

- ネットワークには一切つなぎません
- パスワード、Cookieの値、閲覧したURLそのものは読みません。ドメイン名が含まれるかどうかだけを数えます
- 表示するメールアドレスは伏せ字にします（`-ShowEmails` で解除）

実行前に、必ず `guardian.ps1` を自分の目で（またはAIに読ませて）確認してください。「中身を知らないスクリプトを管理者で実行しない」のも、このツールが伝えたいことの一つです。

## 使い方

```powershell
# 1. ダウンロードして展開したフォルダで PowerShell を開く

# 2. 点検だけ（何も変更しない）
powershell -ExecutionPolicy Bypass -File .\guardian.ps1

# 3. 結果をMarkdownで保存
powershell -ExecutionPolicy Bypass -File .\guardian.ps1 -ReportPath .\report.md

# 4. ブロックリストを書き込む（自分のユーザーだけ。管理者権限不要）
powershell -ExecutionPolicy Bypass -File .\guardian.ps1 -Mode Apply

# 5. PC全体に書き込む（管理者として実行した PowerShell で）
powershell -ExecutionPolicy Bypass -File .\guardian.ps1 -Mode Apply -Scope Machine

# 6. 会社のClaude組織以外では動かないようにする
powershell -ExecutionPolicy Bypass -File .\guardian.ps1 -Mode Apply -OrgUUID "<組織のUUID>"

# 7. 元に戻す
powershell -ExecutionPolicy Bypass -File .\guardian.ps1 -Mode Undo
```

Applyのあとは、Chromeで `chrome://policy` を開いて「ポリシーを再読み込み」を押してください。拡張機能ID `fcoeoabgfenejglbffodgkkbkcdhcgfn` の `blockedUrlPatterns` が表示されれば反映されています。**表示されなければ効いていません。**

Chromeを閉じてから実行すると、Cookieや履歴も読めるので点検が正確になります。

## ブロックリストの編集

`blocklist/default-jp.txt` を編集します。

```
[銀行]
bk.mufg.jp            # bk.mufg.jp と *.bk.mufg.jp をブロック
github.com/settings   # パス単位でブロック
```

ドメインだけを書くと、そのドメインとサブドメイン（`*.`）の両方を登録します。ドメインは各社の公式サイトで確認してから使ってください。

## 書き込まれるレジストリ

```
HKEY_CURRENT_USER\Software\Policies\Google\Chrome\3rdparty\extensions\fcoeoabgfenejglbffodgkkbkcdhcgfn\policy
  blockedUrlPatterns\1 = "bk.mufg.jp"
  blockedUrlPatterns\2 = "*.bk.mufg.jp"
  ...
  forceLoginOrgUUID    = "<UUID>"   (-OrgUUID 指定時のみ)
```

`-Scope Machine` では `HKEY_LOCAL_MACHINE` に書きます。既存の設定は `backup-*.reg` として同じフォルダに保存してから上書きします。

## 限界

- ブロックリストは「Claudeがそのサイトを操作しない」ための仕組みです。ログイン情報が盗まれないことを保証するものではありません
- 同じプロファイル内の複数Googleアカウントは分けられません。分けたいアカウントはプロファイルごと分けてください
- 痕跡の検出は簡易的なものです。見つからない＝安全、ではありません
- 組織で管理されていないWindowsでは、Chromeが一部のポリシーを無視することがあります。必ず `chrome://policy` で確認してください

## ライセンス

MIT License — AICU Japan株式会社 / 白井暁彦（[@o_ob](https://x.com/o_ob)）

関連記事: 窓の杜ブログ「Claude in Chromeは『強すぎる』」（公開後にリンク追加）

## 実験：どのマシンのChromeに手が届くか（probe）

`probe/` には、「いまのClaudeアカウントから、どのマシンのChromeを開けるか」を確かめるスクリプトがあります。Claude Code を `--chrome` 付き・プロンプト引数で起動し、指定したURLを新しいタブで開いて、ページタイトルだけを報告させます。

```bash
# Mac / Linux
./probe/probe.sh                                   # 接続中のブラウザ一覧
./probe/probe.sh https://example.com               # 選択中のブラウザで開く
./probe/probe.sh https://example.com <deviceId>    # 別のマシンのブラウザで開く
./probe/probe.sh --block-test                      # 銀行サイトで止まるか（ブロックリストの効果確認）
./probe/probe.sh --demo                            # 3つのサンプルURLを順に開くデモ
```

### デモ：別のマシンのChromeで、好きなURLを次々に開ける

クラウド上のClaudeセッション（aki@aicu.ai）から、つながっているWindowsのChromeで、次の3つを新しいタブで順に開きました（2026-11-03）。クリックや入力はしていません。

| URL | 開けたか | ページタイトル |
| --- | --- | --- |
| https://akihiko.shirai.as | ✅ | CEO of AICU Inc. · VR, Metaverse & Generative-AI Researcher \| Akihiko SHIRAI, Ph.D. |
| https://note.com/o_ob | ✅ | 白井暁彦 aka しらいはかせ｜note |
| https://note.com/aicu | ✅ | AICU｜note |

![akihiko.shirai.as](docs/img/demo-1-akihiko-shirai-as.jpg)
![note.com/o_ob](docs/img/demo-2-note-o_ob.jpg)
![note.com/aicu](docs/img/demo-3-note-aicu.jpg)

公開ページなら、URLを渡すだけで開けます。そのChromeでログインしているサイトなら、ログイン後の画面も同じように開けます。

```powershell
# Windows
.\probe\probe.ps1 -Url https://example.com -Device <deviceId>
.\probe\probe.ps1 -BlockTest
```

- 事前承認するのは、ブラウザ一覧・ブラウザ選択・タブを開く・ページを読む・タブを閉じる、だけです。クリック・入力・JavaScript実行・ファイルのアップロードは `--disallowedTools` で禁止しています
- Claude Code が `/login` でサインインしている必要があります（APIキー認証では `--chrome` は使えません）
- ブラウザが複数つながっていて選択していない場合、`-p` では選べずに止まることがあります。そのときは先に `claude --chrome` で `/chrome` →「Select browser…」で選んでおくか、`<deviceId>` を指定してください
- 自分の管理するマシンとアカウントでのみ使ってください

## 台帳：Claudeアカウントを切り替えても迷わない（ledger）

Claude側から見えるブラウザの表示名は「Browser 1」「Browser 2」のような**アカウントごとの通し番号**です。別のClaudeアカウントから見ると、同じ「Browser 1」でも別のブラウザのことがあります。頼れるのは `deviceId` だけです。

`probe/ledger.sh` は、今のClaudeアカウントから見えるブラウザを `~/.cce-guardian/devices.json` に記録し、初めて見る `deviceId` にはラベル（どのマシンのどのプロファイルか）を付けさせます。Claudeアカウントを切り替えるたびに1回実行してください。

```bash
./probe/ledger.sh                                   # 調べて記録
./probe/ledger.sh show                              # 台帳を表示
./probe/ledger.sh label cad14262 "Win自宅/Default"   # ラベルを付け直す
CEG_ACCOUNT=info@aicu.jp ./probe/ledger.sh          # アカウント名を自動で取れないとき
```

```
| Claudeアカウント | ラベル（マシン/プロファイル） | OS | deviceId | そのアカウントでの表示名 |
| --- | --- | --- | --- | --- |
| aki@aicu.ai  | Win自宅/Default          | Windows | cad14262… | Browser 1 |
| info@aicu.jp | Win自宅/実験プロファイル | Windows | 12c41036… | Browser 1 |

⚠ Mac/Default は 2 つのClaudeアカウントから見えています。
```

- 今のClaudeアカウントは、Claude Codeの `~/.claude.json` から読みます（取れなければ `unknown`）
- 一覧の取得だけを許可して Claude Code を起動するので、ブラウザには触れません
- 同じ `deviceId` が複数のClaudeアカウントから見えていたら警告します

## ドキュメント

- [docs/blog-draft.md](docs/blog-draft.md) — 窓の杜ブログ記事の草稿
- [docs/design-extension-manager.md](docs/design-extension-manager.md) — 次のバージョン候補「Claude Extension Manager」の設計メモ
