[CmdletBinding()]
param(
    [switch]$TestOnly,
    [switch]$DryRun,
    [string[]]$Files
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "ftp_config.local.json"

# 1. 設定ファイルの読み込み（存在する場合）
$HostName = "post-5.cc.uec.ac.jp"
$Username = ""
$RemoteRoot = "/html"

if (Test-Path $ConfigFile) {
    try {
        $Config = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Config.host) { $HostName = $Config.host }
        if ($Config.username) { $Username = $Config.username }
        if ($Config.remoteRoot) { $RemoteRoot = $Config.remoteRoot }
    } catch {
        if (-not $DryRun) {
            Write-Host "[ERROR] 設定ファイル '$ConfigFile' のJSON解析に失敗しました: $_" -ForegroundColor Red
            exit 1
        }
    }
} elseif (-not $DryRun) {
    Write-Host "[ERROR] 設定ファイル '$ConfigFile' が見つかりません。" -ForegroundColor Red
    Write-Host "ftp_config.example.json をコピーして ftp_config.local.json を作成し、接続情報を設定してください。" -ForegroundColor Yellow
    exit 1
}

# 先頭・末尾スラッシュの正規化
$RemoteRoot = "/" + ($RemoteRoot.Trim("/"))

# ----------------------------------------------------
# アップロード対象判定ルール（ホワイトリスト・ブラックリスト）
# ----------------------------------------------------
$AllowedExtensions = @(
    ".html", ".htm", ".css", ".js",
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".ico",
    ".pdf", ".mp4", ".webm", ".txt"
)

$BlockedNames = @(
    "deploy.ps1", "ftp_config.local.json", "ftp_config.example.json",
    "access_log", "desktop.ini", "Thumbs.db", ".DS_Store",
    "Untitled-1.html", "Untitled*.html"
)

function Get-UploadEligibility {
    param([System.IO.FileInfo]$file)

    $relative = $file.FullName.Substring($ScriptDir.Length).TrimStart("\", "/")
    $segments = $relative.Split([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

    # 隠しディレクトリ・特殊ディレクトリの除外
    foreach ($seg in $segments) {
        if ($seg.StartsWith(".") -or $seg -in @("access_log", "secrets", "node_modules")) {
            return @{ Allowed = $false; RelativePath = $relative; Reason = "隠し・除外ディレクトリ ($seg)" }
        }
    }

    # ブロック対象ファイル名の判定
    foreach ($blocked in $BlockedNames) {
        if ($file.Name -like $blocked) {
            return @{ Allowed = $false; RelativePath = $relative; Reason = "除外ファイル ($($file.Name))" }
        }
    }
    if ($file.Name -like "*.log" -or $file.Name -like "*.env*" -or $file.Name -like "*local.json" -or $file.Name -like "README*") {
        return @{ Allowed = $false; RelativePath = $relative; Reason = "除外パターン" }
    }

    # 拡張子ホワイトリスト判定
    $ext = $file.Extension.ToLower()
    if ($ext -notin $AllowedExtensions) {
        return @{ Allowed = $false; RelativePath = $relative; Reason = "非対象拡張子 ($ext)" }
    }

    return @{
        Allowed = $true
        LocalPath = $file.FullName
        RelativePath = $relative.Replace("\", "/")
        Size = $file.Length
    }
}

# ----------------------------------------------------
# 対象ファイルの収集
# ----------------------------------------------------
$UploadFiles = @()
$ExcludedFiles = @()

if ($Files -and $Files.Count -gt 0) {
    # -Files 指定モード（カンマ区切り文字列にも対応）
    $TargetFileList = @()
    foreach ($f in $Files) {
        if ($f.Contains(",")) {
            $TargetFileList += $f.Split(",").Trim()
        } else {
            $TargetFileList += $f.Trim()
        }
    }

    foreach ($relPath in $TargetFileList) {
        if ([string]::IsNullOrWhiteSpace($relPath)) { continue }
        $fullPath = Join-Path $ScriptDir $relPath
        if (-not (Test-Path $fullPath -PathType Leaf)) {
            Write-Host "[ERROR] 指定されたファイル '$relPath' がローカルに存在しません。" -ForegroundColor Red
            exit 1
        }
        $fileInfo = Get-Item $fullPath
        $check = Get-UploadEligibility -file $fileInfo
        if (-not $check.Allowed) {
            Write-Host "[ERROR] 指定されたファイル '$relPath' は公開除外対象です（理由: $($check.Reason)）。" -ForegroundColor Red
            exit 1
        }
        $UploadFiles += $check
    }
} else {
    # 全ファイル自動収集モード
    $AllFiles = Get-ChildItem -Path $ScriptDir -Recurse -File
    foreach ($file in $AllFiles) {
        $check = Get-UploadEligibility -file $file
        if ($check.Allowed) {
            $UploadFiles += $check
        } else {
            $ExcludedFiles += $check
        }
    }
}

# ----------------------------------------------------
# モード 1: DryRun（事前確認・FTP通信なし）
# ----------------------------------------------------
if ($DryRun) {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  FTP デプロイ Dry-Run（事前確認モード）" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "接続先予定 : ftp://$HostName$RemoteRoot" -ForegroundColor Gray
    if ($Files -and $Files.Count -gt 0) {
        Write-Host "実行モード : 個別ファイル指定モード ($($UploadFiles.Count) 件)" -ForegroundColor Yellow
    } else {
        Write-Host "実行モード : 全公開ファイル対象モード ($($UploadFiles.Count) 件)" -ForegroundColor Yellow
    }
    Write-Host "※ FTPサーバーへの接続・書き込み・変更は一切行いません。" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "【アップロード予定ファイル一覧】" -ForegroundColor Green

    $totalBytes = 0
    foreach ($item in $UploadFiles) {
        $totalBytes += $item.Size
        $sizeKB = [math]::Round($item.Size / 1KB, 1)
        $remoteDest = "$RemoteRoot/$($item.RelativePath)"
        Write-Host "  [UPLOAD] " -ForegroundColor Green -NoNewline
        Write-Host "$($item.RelativePath) " -ForegroundColor White -NoNewline
        Write-Host "($sizeKB KB)" -ForegroundColor Gray
        Write-Host "           -> $remoteDest" -ForegroundColor DarkCyan
    }

    Write-Host ""
    Write-Host "------------------------------------------" -ForegroundColor Gray
    Write-Host "【サマリー】" -ForegroundColor Cyan
    Write-Host "  アップロード予定ファイル総数 : $($UploadFiles.Count) 件"
    $totalMB = [math]::Round($totalBytes / 1MB, 2)
    Write-Host "  合計データ容量             : $totalMB MB ($totalBytes bytes)"

    if (-not ($Files -and $Files.Count -gt 0)) {
        Write-Host ""
        Write-Host "【除外された主なファイル・フォルダ】" -ForegroundColor Magenta
        $excludedSample = $ExcludedFiles | Select-Object -First 10
        foreach ($ex in $excludedSample) {
            Write-Host "  [EXCLUDE] $($ex.RelativePath) ($($ex.Reason))" -ForegroundColor Gray
        }
        if ($ExcludedFiles.Count -gt 10) {
            Write-Host "  ... 他 $($ExcludedFiles.Count - 10) 件除外" -ForegroundColor Gray
        }
    }

    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "※ Dry-Run 完了：FTPサーバーへの書き込みは一切発生していません。" -ForegroundColor Cyan
    exit 0
}

# ----------------------------------------------------
# 認証情報の確認とパスワードプロンプト（TestOnly / 通常デプロイ用）
# ----------------------------------------------------
if ([string]::IsNullOrWhiteSpace($HostName) -or [string]::IsNullOrWhiteSpace($Username)) {
    Write-Host "[ERROR] host または username が設定されていません。" -ForegroundColor Red
    exit 1
}

$Password = $Config.password
if ([string]::IsNullOrEmpty($Password)) {
    $SecurePass = Read-Host -Prompt "FTP Password for '$Username@$HostName'" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePass)
    $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}

if ([string]::IsNullOrEmpty($Password)) {
    Write-Host "[ERROR] パスワードが入力されませんでした。" -ForegroundColor Red
    exit 1
}

$Credentials = New-Object System.Net.NetworkCredential($Username, $Password)

function Create-FtpRequest {
    param(
        [string]$UriString,
        [string]$Method
    )
    $req = [System.Net.FtpWebRequest]::Create($UriString)
    $req.Method = $Method
    $req.Credentials = $Credentials
    $req.UsePassive = $true
    $req.UseBinary = $true
    $req.KeepAlive = $false
    $req.Timeout = 15000
    $req.ReadWriteTimeout = 30000
    return $req
}

# ----------------------------------------------------
# モード 2: TestOnly（読み取り専用・接続確認）
# ----------------------------------------------------
if ($TestOnly) {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  FTP 接続テスト（読み取り専用・変更なし）" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "接続先ホスト : $HostName"
    Write-Host "ユーザー名   : $Username"
    Write-Host "公開ルート   : $RemoteRoot"
    Write-Host ""
    Write-Host "接続テスト中..." -ForegroundColor Yellow

    $TargetUri = "ftp://$HostName$RemoteRoot/"
    try {
        $req = Create-FtpRequest -UriString $TargetUri -Method ([System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails)
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $output = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()

        Write-Host "[SUCCESS] FTPサーバーへの接続およびディレクトリ一覧の取得に成功しました！" -ForegroundColor Green
        Write-Host "--- サーバー側 '$RemoteRoot' のディレクトリ一覧 ---" -ForegroundColor Gray
        Write-Host $output
        Write-Host "--------------------------------------------------" -ForegroundColor Gray
        Write-Host "※ ファイルのアップロードや変更は一切行われていません。" -ForegroundColor Cyan
    } catch {
        Write-Host "[FAILED] 接続に失敗しました: $_" -ForegroundColor Red
        Write-Host "ヒント: 学内Wi-Fiまたは大学VPN（UEC VPN）に接続されているか確認してください。" -ForegroundColor Yellow
        exit 1
    }
    exit 0
}

# ----------------------------------------------------
# モード 3: 通常デプロイ（安全なファイルアップロード）
# ----------------------------------------------------
if ($UploadFiles.Count -eq 0) {
    Write-Host "[WARNING] アップロード対象となるWebファイルが見つかりませんでした。" -ForegroundColor Yellow
    exit 0
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Webサイト デプロイ（FTPアップロード）" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host "接続先 : ftp://$HostName$RemoteRoot"
Write-Host "アップロード対象 ($($UploadFiles.Count) 件):" -ForegroundColor Cyan
foreach ($item in $UploadFiles) {
    $sizeKB = [math]::Round($item.Size / 1KB, 1)
    Write-Host "  - $($item.RelativePath) ($sizeKB KB) -> $RemoteRoot/$($item.RelativePath)"
}
Write-Host ""

# 明示的確認プロンプト
$confirm = Read-Host -Prompt "公開対象 $($UploadFiles.Count) 件を大学公式Webサーバーへアップロードします。よろしいですか？ [y/N]"
if ($confirm -notmatch "^[yY]$") {
    Write-Host "[ABORTED] デプロイを中止しました。" -ForegroundColor Yellow
    exit 0
}

$CreatedDirs = @{}
function Ensure-RemoteDir {
    param([string]$RemoteDirPath)
    if ($CreatedDirs.ContainsKey($RemoteDirPath)) { return }

    $parts = $RemoteDirPath.Trim("/").Split("/")
    $current = ""
    foreach ($part in $parts) {
        $current += "/" + $part
        if ($current -eq $RemoteRoot) { continue }
        if (-not $CreatedDirs.ContainsKey($current)) {
            try {
                $dirUri = "ftp://$HostName$current"
                $req = Create-FtpRequest -UriString $dirUri -Method ([System.Net.WebRequestMethods+Ftp]::MakeDirectory)
                $resp = $req.GetResponse()
                $resp.Close()
            } catch {
                # 既に存在する場合は無視
            }
            $CreatedDirs[$current] = $true
        }
    }
}

$successCount = 0
foreach ($item in $UploadFiles) {
    $rel = $item.RelativePath
    $destUri = "ftp://$HostName$RemoteRoot/$rel"

    $parentDir = [System.IO.Path]::GetDirectoryName($rel).Replace("\", "/")
    if ($parentDir) {
        Ensure-RemoteDir -RemoteDirPath "$RemoteRoot/$parentDir"
    }

    Write-Host "  -> アップロード中: $rel ($([math]::Round($item.Size / 1KB, 1)) KB)..." -NoNewline
    try {
        $req = Create-FtpRequest -UriString $destUri -Method ([System.Net.WebRequestMethods+Ftp]::UploadFile)
        $fileBytes = [System.IO.File]::ReadAllBytes($item.LocalPath)
        $req.ContentLength = $fileBytes.Length

        $stream = $req.GetRequestStream()
        $stream.Write($fileBytes, 0, $fileBytes.Length)
        $stream.Close()

        $resp = $req.GetResponse()
        $resp.Close()

        Write-Host " [完了]" -ForegroundColor Green
        $successCount++
    } catch {
        Write-Host " [失敗]" -ForegroundColor Red
        Write-Host "[ERROR] ファイル '$rel' のアップロード中にエラーが発生しました: $_" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  デプロイ完了: $successCount / $($UploadFiles.Count) ファイルが正常に更新されました" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
