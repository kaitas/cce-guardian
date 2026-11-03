<#
.SYNOPSIS
  cce-guardian
  Claude in Chrome 拡張機能 (CCE) を使う前に「盗まれても大丈夫な環境か」を点検し、
  管理ポリシー (blockedUrlPatterns / forceLoginOrgUUID) を設定する Windows 用スクリプト。

.DESCRIPTION
  このスクリプトは手元の PC の中だけで動きます。ネットワークには一切つなぎません。
  パスワード、Cookie の値、閲覧した URL そのものは読み取りません。
  「どのプロファイルに、どの種類のサイトの痕跡があるか」というドメイン名の一致だけを数えます。

  モード:
    Check  : 点検だけ行う (既定)。何も変更しない。
    Apply  : blockedUrlPatterns を書き込む (必要なら forceLoginOrgUUID も)。変更前にバックアップを取る。
    Undo   : このスクリプトが書いたポリシーを削除する。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\guardian.ps1
  powershell -ExecutionPolicy Bypass -File .\guardian.ps1 -Mode Apply
  powershell -ExecutionPolicy Bypass -File .\guardian.ps1 -Mode Apply -Scope Machine   # 管理者として実行
  powershell -ExecutionPolicy Bypass -File .\guardian.ps1 -Mode Undo

.LINK
  https://github.com/kaitas/cce-guardian
#>
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Apply', 'Undo')]
    [string]$Mode = 'Check',

    # User = HKCU (管理者権限不要) / Machine = HKLM (管理者権限が必要、全ユーザーに効く)
    [ValidateSet('User', 'Machine')]
    [string]$Scope = 'User',

    [string]$BlocklistPath = (Join-Path $PSScriptRoot 'blocklist\default-jp.txt'),

    # 指定すると forceLoginOrgUUID も書き込む (例: 会社の Claude 組織の UUID)
    [string]$OrgUUID = '',

    # 点検結果を Markdown で保存する先 (空なら保存しない)
    [string]$ReportPath = '',

    # 機微ファイル名を探す深さ (デスクトップ・ドキュメント・ダウンロード)
    [int]$FileScanDepth = 3,

    # テスト用: Chrome の User Data フォルダを差し替える
    [string]$ChromeUserData = '',

    # メールアドレスを伏せずに表示する
    [switch]$ShowEmails
)

$ErrorActionPreference = 'Stop'
$Version = '0.1.0'
$ExtId = 'fcoeoabgfenejglbffodgkkbkcdhcgfn'
$OnWindows = ($PSVersionTable.PSVersion.Major -le 5) -or $IsWindows

# ---------------------------------------------------------------- 共通
$Findings = New-Object System.Collections.ArrayList
function Add-Finding {
    param([ValidateSet('High', 'Medium', 'Low', 'OK', 'Info')][string]$Level,
          [string]$Area, [string]$Message, [string]$Fix = '')
    [void]$Findings.Add([pscustomobject]@{ Level = $Level; Area = $Area; Message = $Message; Fix = $Fix })
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host ('== ' + $Title + ' ') -ForegroundColor Cyan
}

function Hide-Email([string]$Email) {
    if ($ShowEmails -or [string]::IsNullOrEmpty($Email) -or ($Email -notmatch '@')) { return $Email }
    $parts = $Email.Split('@')
    $head = $parts[0]
    if ($head.Length -gt 1) { $head = $head.Substring(0, 1) + '***' }
    return $head + '@' + $parts[1]
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-Prop($Obj, [string[]]$Names) {
    # ネストしたプロパティを安全にたどる。見つからなければ $null
    $cur = $Obj
    foreach ($n in $Names) {
        if ($null -eq $cur) { return $null }
        $p = $cur.PSObject.Properties[$n]
        if ($null -eq $p) { return $null }
        $cur = $p.Value
    }
    return $cur
}

function Read-LockedFileText([string]$Path) {
    # Chrome が開いていても読めるよう、共有モードでコピーしてから読む。中身は Latin1 として扱い、ドメイン文字列の一致だけ見る。
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            $ms = New-Object System.IO.MemoryStream
            $fs.CopyTo($ms)
            return [System.Text.Encoding]::GetEncoding(28591).GetString($ms.ToArray())
        } finally { $fs.Dispose() }
    } catch {
        return 'LOCKED'
    }
}

# ---------------------------------------------------------------- ブロックリスト
function Get-Blocklist([string]$Path) {
    $groups = [ordered]@{}
    $current = 'その他'
    if (-not (Test-Path -LiteralPath $Path)) { throw "ブロックリストが見つかりません: $Path" }
    foreach ($raw in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $line = $raw.Trim()
        if ($line -eq '') { continue }
        if ($line -match '^\[(.+)\]$') { $current = $Matches[1]; continue }
        if ($line.StartsWith('#')) { continue }
        $line = ($line -split '\s+#')[0].Trim()
        if (-not $groups.Contains($current)) { $groups[$current] = New-Object System.Collections.ArrayList }
        [void]$groups[$current].Add($line.ToLowerInvariant())
    }
    return $groups
}

function Expand-Patterns($Groups) {
    # "example.com" → "example.com" と "*.example.com"。パス付きやワイルドカード付きはそのまま。
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($g in $Groups.Keys) {
        foreach ($p in $Groups[$g]) {
            if ($p.Contains('/') -or $p.Contains('*')) { $out.Add($p) }
            else { $out.Add($p); $out.Add('*.' + $p) }
        }
    }
    return ($out | Select-Object -Unique)
}

# ---------------------------------------------------------------- 1. Chrome プロファイル
function Test-ChromeProfiles($Groups) {
    Write-Section '1. Chrome プロファイルと Claude 拡張機能'

    $userData = $ChromeUserData
    if ($userData -eq '') { $userData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data' }
    if (-not (Test-Path -LiteralPath $userData)) {
        Add-Finding Info 'Chrome' "Chrome のユーザーデータが見つかりません ($userData)。"
        return
    }

    $localState = Read-JsonFile (Join-Path $userData 'Local State')
    $cache = Get-Prop $localState @('profile', 'info_cache')
    $dirs = @()
    if ($null -ne $cache) { $dirs = @($cache.PSObject.Properties | ForEach-Object { $_.Name }) }
    if ($dirs.Count -eq 0) {
        $dirs = @(Get-ChildItem -LiteralPath $userData -Directory |
                  Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
                  ForEach-Object { $_.Name })
    }

    $withCce = 0
    foreach ($d in $dirs) {
        $pdir = Join-Path $userData $d
        if (-not (Test-Path -LiteralPath $pdir)) { continue }
        $info = Get-Prop $cache @($d)
        $label = Get-Prop $info @('name')
        if (-not $label) { $label = $d }
        $email = Hide-Email ([string](Get-Prop $info @('user_name')))

        $installed = Test-Path -LiteralPath (Join-Path $pdir "Extensions\$ExtId")
        $prefs = Read-JsonFile (Join-Path $pdir 'Preferences')
        $secure = Read-JsonFile (Join-Path $pdir 'Secure Preferences')
        $ext = Get-Prop $secure @('extensions', 'settings', $ExtId)
        if ($null -eq $ext) { $ext = Get-Prop $prefs @('extensions', 'settings', $ExtId) }

        $accounts = @()
        $ai = Get-Prop $prefs @('account_info')
        if ($ai) { $accounts = @($ai | ForEach-Object { Hide-Email ([string]$_.email) } | Where-Object { $_ }) }

        $title = "[$d] $label"
        if ($email) { $title += " <$email>" }
        Write-Host ''
        Write-Host $title -ForegroundColor White
        if ($accounts.Count -gt 0) { Write-Host ('   Chromeにログイン中のGoogleアカウント: ' + ($accounts -join ', ')) }

        if (-not $installed) {
            Write-Host '   Claude 拡張機能: なし' -ForegroundColor DarkGray
            Test-SensitiveTraces $pdir $title $Groups $false
            continue
        }
        $withCce++

        # 有効/無効 (Chrome のバージョンで表現が違うので、分かる範囲で判定)
        $state = Get-Prop $ext @('state')
        $reasons = Get-Prop $ext @('disable_reasons')
        $disabled = ($state -eq 0) -or ($reasons -and (@($reasons).Count -gt 0) -and ($reasons -ne 0))
        if ($disabled) { Write-Host '   Claude 拡張機能: インストール済み (無効)' -ForegroundColor Yellow }
        else { Write-Host '   Claude 拡張機能: インストール済み (有効)' -ForegroundColor Yellow }

        # サイトへのアクセス
        $withheld = Get-Prop $ext @('withholding_permissions')
        if ($withheld -eq $true) {
            Write-Host '   サイトへのアクセス: 制限あり (特定のサイト / クリック時)'
            Add-Finding OK $title 'サイトへのアクセスが制限されています。'
        } elseif (-not $disabled) {
            Write-Host '   サイトへのアクセス: すべてのサイト' -ForegroundColor Red
            Add-Finding Medium $title 'Claude 拡張機能が「すべてのサイト」で動ける設定です。' `
                "chrome://extensions/?id=$ExtId の「サイトへのアクセス」を「特定のサイト」か「クリック時」に変更"
        }

        # file:// へのアクセス
        if ((Get-Prop $ext @('newAllowFileAccess')) -eq $true) {
            Add-Finding High $title 'Claude 拡張機能に「ファイルの URL へのアクセス」が許可されています (PC内のファイルを開ける)。' `
                "chrome://extensions/?id=$ExtId で「ファイルの URL へのアクセスを許可する」をオフ"
        }

        # シークレット
        if ((Get-Prop $ext @('incognito')) -eq $true) {
            Add-Finding Medium $title 'シークレットモードでの実行が許可されています。' 'シークレットモードでの実行をオフ'
        }

        # 同期
        $everything = Get-Prop $prefs @('sync', 'keep_everything_synced')
        $syncExt = Get-Prop $prefs @('sync', 'extensions')
        if (($everything -eq $true) -or ($syncExt -eq $true)) {
            Add-Finding Medium $title 'Chrome 同期で拡張機能が同期される設定です。ほかの PC にも Claude が入ります。' `
                '設定 → 同期とGoogleサービス → 同期する内容を管理 → 「拡張機能」をオフ'
        }

        # 保存パスワード・カード
        if ((Get-Prop $prefs @('credentials_enable_service')) -ne $false) {
            Add-Finding Low $title 'このプロファイルは Chrome にパスワードを保存する設定です。' 'Claude 用プロファイルではパスワード保存をオフにし、パスワード管理アプリに任せる'
        }
        if ((Get-Prop $prefs @('autofill', 'credit_card_enabled')) -ne $false) {
            Add-Finding Medium $title 'お支払い方法 (カード) の自動入力がオンです。' '設定 → 自動入力とパスワード → お支払い方法 → オフ'
        }

        # ダウンロード
        if ((Get-Prop $prefs @('download', 'prompt_for_download')) -ne $true) {
            Add-Finding Low $title 'ダウンロード時に保存先を確認しない設定です。' '設定 → ダウンロード → 「ダウンロード前に各ファイルの保存場所を確認する」をオン'
        }

        Test-SensitiveTraces $pdir $title $Groups $true
    }

    if ($withCce -gt 1) {
        Add-Finding Medium 'Chrome' "Claude 拡張機能が $withCce 個のプロファイルに入っています。1 つに絞るのがおすすめです。" '使わないプロファイルの chrome://extensions で削除'
    } elseif ($withCce -eq 0) {
        Add-Finding Info 'Chrome' 'Claude 拡張機能が入っているプロファイルはありません。'
    }
}

function Test-SensitiveTraces([string]$ProfileDir, [string]$Title, $Groups, [bool]$HasCce) {
    # 保存パスワード (Login Data)、Cookie、閲覧履歴の中に、ブロックリストのドメイン名があるかだけを見る
    $sources = [ordered]@{
        '保存パスワード' = (Join-Path $ProfileDir 'Login Data')
        'Cookie (ログイン中の可能性)' = (Join-Path $ProfileDir 'Network\Cookies')
        '閲覧履歴' = (Join-Path $ProfileDir 'History')
    }
    $texts = @{}
    foreach ($k in $sources.Keys) { $texts[$k] = Read-LockedFileText $sources[$k] }

    $hitGroups = @()
    foreach ($g in $Groups.Keys) {
        $where = @()
        foreach ($k in $sources.Keys) {
            $t = $texts[$k]
            if ($null -eq $t -or $t -eq 'LOCKED') { continue }
            foreach ($dom in $Groups[$g]) {
                $needle = ($dom -replace '\*', '').Split('/')[0].Trim('.')
                if ($needle.Length -lt 4) { continue }
                if ($t.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $where += $k; break }
            }
        }
        if ($where.Count -gt 0) {
            $hitGroups += $g
            $msg = "「$g」の痕跡: " + ($where -join '・')
            Write-Host ('   ' + $msg) -ForegroundColor $(if ($HasCce) { 'Red' } else { 'Gray' })
            if ($HasCce) {
                $lvl = 'Medium'
                if ($where -contains '保存パスワード' -or $where -contains 'Cookie (ログイン中の可能性)') { $lvl = 'High' }
                Add-Finding $lvl $Title ("Claude 拡張機能と同じプロファイルに " + $msg) `
                    'このプロファイルでは該当サイトからログアウトするか、Claude を別プロファイルへ移す。-Mode Apply でブロックも可'
            }
        }
    }
    $locked = @($sources.Keys | Where-Object { $texts[$_] -eq 'LOCKED' })
    if ($locked.Count -gt 0) {
        Write-Host ('   (Chrome が使用中のため読めなかったもの: ' + ($locked -join '・') + ' → Chrome を閉じて再実行すると正確になります)') -ForegroundColor DarkGray
    }
    if ($HasCce -and $hitGroups.Count -eq 0 -and $locked.Count -eq 0) {
        Add-Finding OK $Title 'Claude と同じプロファイルに、ブロックリストのサイトの痕跡は見つかりませんでした。'
    }
}

# ---------------------------------------------------------------- 2. 広範なファイルアクセス
function Test-FileAccess {
    Write-Section '2. ファイルへのアクセス範囲'

    $home_ = $env:USERPROFILE
    if (-not $home_) { $home_ = $HOME }
    $appdata = $env:APPDATA
    if (-not $appdata) { $appdata = Join-Path $home_ 'AppData\Roaming' }

    # Claude Desktop の MCP サーバー設定
    $desk = Join-Path $appdata 'Claude\claude_desktop_config.json'
    $cfg = Read-JsonFile $desk
    $servers = Get-Prop $cfg @('mcpServers')
    if ($servers) {
        foreach ($s in $servers.PSObject.Properties) {
            $args_ = @(Get-Prop $s.Value @('args')) -join ' '
            $cmd = [string](Get-Prop $s.Value @('command'))
            Write-Host ("   Claude Desktop MCP: {0} ({1} {2})" -f $s.Name, $cmd, $args_)
            if ($args_ -match '(^|\s|")[A-Za-z]:\\?("|\s|$)' -or $args_ -match [regex]::Escape($home_) + '("|\s|\\?$)') {
                Add-Finding High 'Claude Desktop' "MCP サーバー「$($s.Name)」がドライブ全体またはユーザーフォルダ全体を対象にしています。" '作業用フォルダだけに絞る'
            }
        }
    } else {
        Write-Host '   Claude Desktop の MCP 設定: なし' -ForegroundColor DarkGray
    }

    # Claude Code の権限設定
    $cc = Join-Path $home_ '.claude\settings.json'
    $ccs = Read-JsonFile $cc
    if ($ccs) {
        $mode = [string](Get-Prop $ccs @('permissions', 'defaultMode'))
        if ($mode -eq 'bypassPermissions') {
            Add-Finding High 'Claude Code' 'Claude Code が確認なしで何でも実行するモード (bypassPermissions) です。' '~/.claude/settings.json の defaultMode を見直す'
        }
        $allow = @(Get-Prop $ccs @('permissions', 'allow'))
        if ($allow -contains 'Bash' -or $allow -contains 'Bash(*)') {
            Add-Finding Medium 'Claude Code' 'Claude Code にすべてのコマンド実行が許可されています。' '許可するコマンドを絞る'
        }
        Write-Host '   Claude Code の設定: あり (内容を点検しました)'
    }

    # ネイティブメッセージング (拡張機能と話せるローカルアプリ)
    if ($OnWindows) {
        foreach ($root in @('HKCU:\Software\Google\Chrome\NativeMessagingHosts', 'HKLM:\Software\Google\Chrome\NativeMessagingHosts')) {
            if (Test-Path $root) {
                Get-ChildItem $root | Where-Object { $_.PSChildName -match 'claude|anthropic' } | ForEach-Object {
                    Write-Host ("   拡張機能と通信できるローカルアプリ: {0}" -f $_.PSChildName)
                    Add-Finding Info 'ネイティブ連携' ("Chrome の Claude 拡張機能は、ローカルアプリ「{0}」と直接通信できます。" -f $_.PSChildName)
                }
            }
        }
    }

    # 機微ファイル名の検出 (中身は開かない)
    $patterns = @('*マイナンバー*', '*個人番号*', '*通帳*', '*口座*', '*免許証*', '*パスポート*', '*passport*',
                  '*源泉徴収*', '*確定申告*', '*給与明細*', '*パスワード*', '*password*', '*.pem', '*.pfx', '*.p12',
                  'id_rsa*', 'id_ed25519*', '*.kdbx', '.env', '*seed*phrase*', '*秘密鍵*')
    $roots = @('Desktop', 'Documents', 'Downloads') | ForEach-Object { Join-Path $home_ $_ } | Where-Object { Test-Path -LiteralPath $_ }
    $hits = New-Object System.Collections.ArrayList
    foreach ($r in $roots) {
        try {
            Get-ChildItem -LiteralPath $r -Recurse -Depth $FileScanDepth -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $n = $_.Name; @($patterns | Where-Object { $n -like $_ }).Count -gt 0 } |
                Select-Object -First 50 | ForEach-Object { [void]$hits.Add($_.FullName) }
        } catch { }
    }
    if ($hits.Count -gt 0) {
        Write-Host ("   機微そうなファイル名: {0} 件 (中身は開いていません)" -f $hits.Count) -ForegroundColor Red
        $hits | Select-Object -First 10 | ForEach-Object { Write-Host ('     ' + $_.Replace($home_, '~')) }
        Add-Finding Medium 'ファイル' ("デスクトップ・ドキュメント・ダウンロードに、機微そうな名前のファイルが {0} 件あります。Claude にフォルダを渡すときやアップロード時に混ざりやすい場所です。" -f $hits.Count) `
            '暗号化した保管場所へ移す、または Claude に渡すフォルダと分ける'
    } else {
        Write-Host '   機微そうなファイル名: 見つかりませんでした'
    }
}

# ---------------------------------------------------------------- 3. ポリシー
function Get-PolicyKey([string]$Hive) {
    return "$($Hive):\Software\Policies\Google\Chrome\3rdparty\extensions\$ExtId\policy"
}

function Test-Policy {
    Write-Section '3. 管理ポリシー (blockedUrlPatterns / forceLoginOrgUUID)'
    if (-not $OnWindows) { Write-Host '   (Windows 以外のためスキップ)'; return }
    $any = $false
    foreach ($h in @('HKLM', 'HKCU')) {
        $k = Get-PolicyKey $h
        if (Test-Path $k) {
            $any = $true
            $bk = Join-Path $k 'blockedUrlPatterns'
            $n = 0
            if (Test-Path $bk) { $n = @((Get-Item $bk).Property).Count }
            $org = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).forceLoginOrgUUID
            Write-Host ("   {0}: blockedUrlPatterns {1} 件 / forceLoginOrgUUID {2}" -f $h, $n, $(if ($org) { '設定あり' } else { 'なし' }))
            if ($n -gt 0) { Add-Finding OK "ポリシー ($h)" "blockedUrlPatterns が $n 件設定されています。chrome://policy で反映を確認してください。" }
        }
    }
    if (-not $any) {
        Write-Host '   ポリシー: 未設定' -ForegroundColor Yellow
        Add-Finding Medium 'ポリシー' '金融・行政サイトを Claude から守るブロックリストが未設定です。' '.\guardian.ps1 -Mode Apply'
    }
}

function Invoke-Apply($Groups) {
    Write-Section 'ポリシーを書き込みます'
    if (-not $OnWindows) { throw 'Apply は Windows でのみ実行できます。' }
    $hive = $(if ($Scope -eq 'Machine') { 'HKLM' } else { 'HKCU' })
    if ($hive -eq 'HKLM') {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $admin) { throw '-Scope Machine には管理者として実行した PowerShell が必要です。' }
    }
    $key = Get-PolicyKey $hive
    $regPath = $key -replace '^HKLM:', 'HKEY_LOCAL_MACHINE' -replace '^HKCU:', 'HKEY_CURRENT_USER'

    # バックアップ
    if (Test-Path $key) {
        $bak = Join-Path $PSScriptRoot ("backup-{0}-{1}.reg" -f $hive, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        & reg.exe export $regPath $bak /y | Out-Null
        Write-Host "   既存の設定をバックアップしました: $bak"
        Remove-Item -Path $key -Recurse -Force
    }

    $patterns = @(Expand-Patterns $Groups)
    $bk = Join-Path $key 'blockedUrlPatterns'
    New-Item -Path $bk -Force | Out-Null
    $i = 1
    foreach ($p in $patterns) {
        New-ItemProperty -Path $bk -Name ([string]$i) -Value $p -PropertyType String -Force | Out-Null
        $i++
    }
    Write-Host ("   blockedUrlPatterns: {0} 件を {1} に書き込みました。" -f $patterns.Count, $hive) -ForegroundColor Green

    if ($OrgUUID -ne '') {
        New-ItemProperty -Path $key -Name 'forceLoginOrgUUID' -Value $OrgUUID -PropertyType String -Force | Out-Null
        Write-Host '   forceLoginOrgUUID を書き込みました。' -ForegroundColor Green
    }
    Write-Host ''
    Write-Host '   次の手順: Chrome で chrome://policy を開き「ポリシーを再読み込み」。' -ForegroundColor Cyan
    Write-Host "   一覧に $ExtId の blockedUrlPatterns が表示されれば反映されています。"
}

function Invoke-Undo {
    Write-Section 'ポリシーを削除します'
    if (-not $OnWindows) { throw 'Undo は Windows でのみ実行できます。' }
    $hive = $(if ($Scope -eq 'Machine') { 'HKLM' } else { 'HKCU' })
    $key = Get-PolicyKey $hive
    if (Test-Path $key) {
        $regPath = $key -replace '^HKLM:', 'HKEY_LOCAL_MACHINE' -replace '^HKCU:', 'HKEY_CURRENT_USER'
        $bak = Join-Path $PSScriptRoot ("backup-{0}-{1}.reg" -f $hive, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        & reg.exe export $regPath $bak /y | Out-Null
        Remove-Item -Path $key -Recurse -Force
        Write-Host "   削除しました (バックアップ: $bak)。chrome://policy で再読み込みしてください。" -ForegroundColor Green
    } else {
        Write-Host "   $hive にはこのスクリプトのポリシーはありません。"
    }
}

# ---------------------------------------------------------------- まとめ
function Write-Summary {
    Write-Section 'まとめ：盗まれても大丈夫度'
    $high = @($Findings | Where-Object Level -eq 'High').Count
    $med = @($Findings | Where-Object Level -eq 'Medium').Count
    $low = @($Findings | Where-Object Level -eq 'Low').Count
    $score = [Math]::Max(0, 100 - 25 * $high - 10 * $med - 3 * $low)
    $color = $(if ($score -ge 80) { 'Green' } elseif ($score -ge 50) { 'Yellow' } else { 'Red' })
    Write-Host ''
    Write-Host ("   {0} / 100   (要対応 高:{1}  中:{2}  低:{3})" -f $score, $high, $med, $low) -ForegroundColor $color
    Write-Host ''
    foreach ($lv in @('High', 'Medium', 'Low')) {
        foreach ($f in @($Findings | Where-Object Level -eq $lv)) {
            $c = @{ High = 'Red'; Medium = 'Yellow'; Low = 'Gray' }[$lv]
            Write-Host ("   [{0}] {1}: {2}" -f $lv, $f.Area, $f.Message) -ForegroundColor $c
            if ($f.Fix) { Write-Host ("          → {0}" -f $f.Fix) }
        }
    }
    if ($ReportPath -ne '') {
        $md = New-Object System.Text.StringBuilder
        [void]$md.AppendLine("# cce-guardian レポート")
        [void]$md.AppendLine('')
        [void]$md.AppendLine("- 実行日時: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
        [void]$md.AppendLine("- バージョン: $Version")
        [void]$md.AppendLine("- 盗まれても大丈夫度: **$score / 100**")
        [void]$md.AppendLine('')
        [void]$md.AppendLine('| 重要度 | 対象 | 内容 | 対策 |')
        [void]$md.AppendLine('| --- | --- | --- | --- |')
        $order = @{ High = 0; Medium = 1; Low = 2; Info = 3; OK = 4 }
        foreach ($f in @($Findings | Sort-Object { $order[$_.Level] })) {
            [void]$md.AppendLine(("| {0} | {1} | {2} | {3} |" -f $f.Level, $f.Area.Replace('|', '/'), $f.Message.Replace('|', '/'), $f.Fix.Replace('|', '/')))
        }
        [System.IO.File]::WriteAllText($ReportPath, $md.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ''
        Write-Host "   レポートを保存しました: $ReportPath"
    }
}

# ---------------------------------------------------------------- 実行
Write-Host "cce-guardian v$Version  (mode: $Mode)" -ForegroundColor Cyan
Write-Host 'この PC の中だけで点検します。ネットワーク通信はしません。パスワードや閲覧 URL は読み取りません。' -ForegroundColor DarkGray

$groups = Get-Blocklist $BlocklistPath

switch ($Mode) {
    'Apply' { Invoke-Apply $groups }
    'Undo' { Invoke-Undo }
}

Test-ChromeProfiles $groups
Test-FileAccess
Test-Policy
Write-Summary
