# ==============================================================================
# 電気通信大学競技ダンス研究部 公式Webサイト
# デプロイ環境 初回セットアップスクリプト (setup.ps1)
# ==============================================================================
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExampleFile = Join-Path $ScriptDir "ftp_config.example.json"
$ConfigFile = Join-Path $ScriptDir "ftp_config.local.json"
$PasswordFile = Join-Path $ScriptDir "ftp_password.local.dat"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  電気通信大学競技ダンス研究部 Webサイト デプロイ初期設定" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "このスクリプトは、新しいPCで最初に1回だけ実行する設定ツールです。"
Write-Host "入力されたパスワードはWindowsの暗号化機能（DPAPI）で安全に保護され、"
Write-Host "このPC・ログインユーザー以外からは復号できない形式でローカルに保存されます。"
Write-Host "※ GitHubリポジトリへパスワードが送信されることは絶対にありません。" -ForegroundColor Green
Write-Host "------------------------------------------------------------" -ForegroundColor Gray
Write-Host ""

# 1. テンプレート設定の読み込み
$DefaultHost = "post-5.cc.uec.ac.jp"
$DefaultRemoteRoot = "/html"
$DefaultUsername = ""

if (Test-Path $ExampleFile) {
    try {
        $example = Get-Content $ExampleFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($example.host) { $DefaultHost = $example.host }
        if ($example.remoteRoot) { $DefaultRemoteRoot = $example.remoteRoot }
        if ($example.username) { $DefaultUsername = $example.username }
    } catch {}
}

if (Test-Path $ConfigFile) {
    try {
        $existing = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($existing.username) { $DefaultUsername = $existing.username }
    } catch {}
}

# 2. ユーザー名の入力
if ($DefaultUsername) {
    $inputUser = Read-Host -Prompt "FTPユーザー名を入力してください [現在/既定: $DefaultUsername]"
    if ([string]::IsNullOrWhiteSpace($inputUser)) {
        $Username = $DefaultUsername
    } else {
        $Username = $inputUser.Trim()
    }
} else {
    $Username = (Read-Host -Prompt "FTPユーザー名を入力してください (例: ballroomdancewww)").Trim()
}

if ([string]::IsNullOrWhiteSpace($Username)) {
    Write-Host "[ERROR] ユーザー名が入力されませんでした。処理を中断します。" -ForegroundColor Red
    exit 1
}

# 3. パスワードの入力（伏せ字）
$SecurePass = Read-Host -Prompt "FTPパスワードを入力してください (入力内容は画面に表示されません)" -AsSecureString

$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePass)
$PlainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

if ([string]::IsNullOrEmpty($PlainPass)) {
    Write-Host "[ERROR] パスワードが入力されませんでした。処理を中断します。" -ForegroundColor Red
    exit 1
}

# 4. ftp_config.local.json の保存（パスワードは保存しない）
$ConfigObj = [ordered]@{
    host       = $DefaultHost
    username   = $Username
    remoteRoot = $DefaultRemoteRoot
}

$ConfigJson = $ConfigObj | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($ConfigFile, $ConfigJson, [System.Text.Encoding]::UTF8)

# 5. パスワードのDPAPI暗号化保存
try {
    $encrypted = ConvertFrom-SecureString -SecureString $SecurePass
    Set-Content -Path $PasswordFile -Value $encrypted -Encoding ASCII
} catch {
    Write-Host "[ERROR] パスワードの暗号化保存に失敗しました: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "[OK] 設定ファイル (ftp_config.local.json) を作成しました。" -ForegroundColor Green
Write-Host "[OK] 暗号化パスワード (ftp_password.local.dat) を保存しました。" -ForegroundColor Green
Write-Host ""

# 6. FTP接続テストの実行（読み取り専用）
Write-Host "------------------------------------------------------------" -ForegroundColor Gray
Write-Host "大学サーバーへの接続確認テストを実行します..." -ForegroundColor Yellow
Write-Host "接続先: ftp://$DefaultHost$DefaultRemoteRoot"
Write-Host ""

$Credentials = New-Object System.Net.NetworkCredential($Username, $PlainPass)
$TargetUri = "ftp://$DefaultHost$DefaultRemoteRoot/"

try {
    $req = [System.Net.FtpWebRequest]::Create($TargetUri)
    $req.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
    $req.Credentials = $Credentials
    $req.UsePassive = $true
    $req.UseBinary = $true
    $req.KeepAlive = $false
    $req.Timeout = 10000

    $resp = $req.GetResponse()
    $stream = $resp.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    $output = $reader.ReadToEnd()
    $reader.Close()
    $resp.Close()

    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  初期設定および接続テストが正常に完了しました！" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "以降は以下のコマンドでWebサイトを安全に公開・更新できます：" -ForegroundColor Cyan
    Write-Host "  - 変更したファイルだけ公開 : .\deploy.ps1 -Files index.html" -ForegroundColor White
    Write-Host "  - 公開前の事前確認         : .\deploy.ps1 -DryRun -Files index.html" -ForegroundColor White
    Write-Host "  - 接続のみ確認             : .\deploy.ps1 -TestOnly" -ForegroundColor White
    Write-Host ""
} catch {
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  設定の保存は完了しましたが、接続テストに失敗しました。" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "エラー詳細: $_" -ForegroundColor Gray
    Write-Host ""
    Write-Host "※ 保存した設定・パスワードは保持されています。" -ForegroundColor Cyan
    Write-Host "大学VPNまたは学内Wi-Fi（UEC Wireless等）に接続されていることを確認の上、" -ForegroundColor Yellow
    Write-Host "以下のコマンドで接続確認を実行してください：" -ForegroundColor Yellow
    Write-Host "  .\deploy.ps1 -TestOnly" -ForegroundColor White
    Write-Host ""
}
