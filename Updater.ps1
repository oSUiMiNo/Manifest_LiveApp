# ==========================================
# LiveApp/Updater.ps1（差し替え可能）
# 役割：
#   1) remote manifest を取得（manifestUrl移転があれば「二段階確認」で切替）
#   2) Updater 自己更新（必要なら差し替え→ exit 3010 で Launcher に再実行させる）
#   3) Build 更新（Build.zip DL→検証→解凍→Build_new→Buildへ原子的に入替）
#   4) すべて成功後、exe起動直前に manifest.local.json を更新（途中失敗で詰むのを防ぐ）
#
# 重要な既知対策：
#   - PS 5.1 の UTF-8 BOM差で自己更新が無限ループしないよう「正規化して比較」する
#   - Get-ChildItem が単体ヒットだと .Count が無い問題があるため @(...) で配列化し .Length を使う
# ==========================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestUrl,

    [Parameter(Mandatory = $false)]
    [string]$RootPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Launcherと合意：自己更新後の再実行シグナル
$EXIT_RELAUNCH = 3010

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = $PSScriptRoot
}

# ログ出力先（LiveApp\Log\updater.log）
$LogDir = Join-Path $RootPath "Log"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$UpdaterPath       = Join-Path $RootPath "Updater.ps1"
$LocalManifestPath = Join-Path $RootPath "manifest.local.json"
$UpdaterLog        = Join-Path $LogDir "updater.log"
$BuildDir          = Join-Path $RootPath "Build"

# デバッグ残骸（旧版の名残り）を消しておく
$LegacyRemoteManifest = Join-Path $RootPath "manifest.remote.json"
if (Test-Path $LegacyRemoteManifest) {
    try { Remove-Item $LegacyRemoteManifest -Force -ErrorAction SilentlyContinue } catch {}
}

# 旧Buildを残すならtrue（必要ならfalseに）
$KeepOldBuild = $true

# ------------------------------------------------------------
# ログ出力
# 目的：
#   - コンソールと updater.log へ同じ内容を出す
# ------------------------------------------------------------
function Write-Log([string]$Message) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][Updater] $Message"
    Write-Host $line
    try { Add-Content -Path $UpdaterLog -Value $line -Encoding UTF8 } catch {}
}

# ------------------------------------------------------------
# TLS 1.2 を強制（PowerShell 5.1でHTTPS取得が失敗しがちなため）
# ------------------------------------------------------------
function Ensure-Tls12() {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

# ------------------------------------------------------------
# キャッシュ回避用にURLへクエリを付ける
# ------------------------------------------------------------
function Add-CacheBuster([string]$Url) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($Url -match '\?') { return "${Url}&v=$ts" }
    return "${Url}?v=$ts"
}

# ------------------------------------------------------------
# JSONを取得してPowerShellオブジェクトとして返す
# ------------------------------------------------------------
function Get-Json([string]$Url) {
    Ensure-Tls12
    $u = Add-CacheBuster $Url
    return Invoke-RestMethod -Uri $u -Method Get
}

# ------------------------------------------------------------
# ファイルをダウンロードする（BITS優先→WebRequestへフォールバック）
# ------------------------------------------------------------
function Download-File([string]$Url, [string]$OutFile) {
    Ensure-Tls12
    New-Item -ItemType Directory -Path (Split-Path $OutFile -Parent) -Force | Out-Null

    try {
        Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop
        return
    } catch {}

    $params = @{
        Uri         = $Url
        OutFile     = $OutFile
        Method      = "Get"
        ErrorAction = "Stop"
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $params.UseBasicParsing = $true }
    Invoke-WebRequest @params | Out-Null
}

# ------------------------------------------------------------
# ファイルのSHA256を計算して（小文字の）ハッシュ文字列として返す
# ------------------------------------------------------------
function Get-SHA256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

# ------------------------------------------------------------
# expected が空でない場合のみSHA256一致を検証する
# ------------------------------------------------------------
function Assert-HashIfProvided([string]$Path, [string]$Expected) {
    if ([string]::IsNullOrWhiteSpace($Expected)) { return }
    $act = Get-SHA256 $Path
    $exp = $Expected.Trim().ToLowerInvariant()
    if ($act -ne $exp) {
        throw "SHA256が一致しません。期待=$exp 実際=$act ファイル=$Path"
    }
}

# ------------------------------------------------------------
# manifest.local.json を読む（壊れていたらnull）
# ------------------------------------------------------------
function Read-LocalManifest() {
    if (-not (Test-Path $LocalManifestPath)) { return $null }
    try {
        return (Get-Content -Path $LocalManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# ------------------------------------------------------------
# ローカルmanifestが無い場合の「空」オブジェクトを作る
# 目的：
#   - nullチェック地獄を避ける
# ------------------------------------------------------------
function New-EmptyLocalManifest() {
    return [pscustomobject]@{
        manifestUrl = ""
        build   = [pscustomobject]@{ version=""; url=""; sha256="" }
        updater = [pscustomobject]@{ version=""; url=""; sha256="" }
    }
}

# ------------------------------------------------------------
# manifest.local.json を安全に書き込む（tmp→rename）
# 注意：
#   - 途中失敗で「最新扱い」になって詰むのを防ぐため、
#     これは “最後（成功後）” にのみ呼ぶ設計。
# ------------------------------------------------------------
function Write-LocalManifest($manifestObj) {
    $tmp = Join-Path $RootPath "manifest.local.json.tmp"
    $json = $manifestObj | ConvertTo-Json -Depth 10
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    Move-Item -Path $tmp -Destination $LocalManifestPath -Force
}

# ------------------------------------------------------------
# 文字列同士をトリムして同一判定する
# ------------------------------------------------------------
function Same-Field([string]$a, [string]$b) {
    return ([string]$a).Trim() -eq ([string]$b).Trim()
}

# ------------------------------------------------------------
# manifest上の差分で更新が必要か判定する
# ルール：
#   - version / url / sha256 のどれかが不一致なら更新対象
# ------------------------------------------------------------
function Need-UpdateByManifest($localPart, $remotePart) {
    if ($null -eq $remotePart) { return $false }

    $lv = if ($null -ne $localPart) { [string]$localPart.version } else { "" }
    $lu = if ($null -ne $localPart) { [string]$localPart.url }     else { "" }
    $lh = if ($null -ne $localPart) { [string]$localPart.sha256 }  else { "" }

    $rv = [string]$remotePart.version
    $ru = [string]$remotePart.url
    $rh = [string]$remotePart.sha256

    if (-not (Same-Field $lv $rv)) { return $true }
    if (-not (Same-Field $lu $ru)) { return $true }
    if (-not (Same-Field $lh $rh)) { return $true }
    return $false
}

# ------------------------------------------------------------
# manifestUrl 移転を考慮して remote manifest を解決する（二段階確認）
# 手順：
#   1) initialUrl で取得
#   2) manifestUrl が別URLなら、候補URLでも取得できるか確認してから切替
# 戻り値：
#   - @{ url = 実際に使うURL; manifest = 取得したmanifestオブジェクト }
# ------------------------------------------------------------
function Try-Resolve-ManifestUrl([string]$initialUrl) {
    Write-Log "remote manifest を取得します：$initialUrl"
    $m1 = Get-Json $initialUrl

    $candidate = [string]$m1.manifestUrl
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $m1 | Add-Member -NotePropertyName manifestUrl -NotePropertyValue $initialUrl -Force
        return @{ url = $initialUrl; manifest = $m1 }
    }

    $candidate = $candidate.Trim()
    if ($candidate -eq $initialUrl) {
        return @{ url = $initialUrl; manifest = $m1 }
    }

    Write-Log "manifestUrl が異なります。移転先を確認します：$candidate"
    try {
        $m2 = Get-Json $candidate
        if ([string]::IsNullOrWhiteSpace([string]$m2.manifestUrl)) {
            $m2 | Add-Member -NotePropertyName manifestUrl -NotePropertyValue $candidate -Force
        }
        Write-Log "manifestUrl を移転先へ切り替えます：$candidate"
        return @{ url = $candidate; manifest = $m2 }
    } catch {
        Write-Log "移転先manifestUrlにアクセスできません。旧URLを使います。"
        return @{ url = $initialUrl; manifest = $m1 }
    }
}

# ------------------------------------------------------------
# Updater 自己更新（必要なら差し替え）
# 超重要：
#   - PS 5.1 の UTF-8 BOM差で無限自己更新ループが起きないよう、
#     ダウンロード後に「UTF-8 BOM付きへ正規化」して、そのファイル同士でhash比較する。
# 戻り値：
#   - $true  : 更新して差し替えた（→ exit 3010 で再実行させる）
#   - $false : 更新不要
# ------------------------------------------------------------
function Update-UpdaterIfNeeded($local, $remote) {
    $remoteUpdater = $remote.updater
    if ($null -eq $remoteUpdater) { return $false }

    $need = Need-UpdateByManifest ($local.updater) $remoteUpdater

    # 念のため：manifest上一致でも、sha256があるなら実ファイルも比較して壊れ検知
    if (-not $need) {
        $rh = [string]$remoteUpdater.sha256
        if (-not [string]::IsNullOrWhiteSpace($rh) -and (Test-Path $UpdaterPath)) {
            $actual = Get-SHA256 $UpdaterPath
            if ($actual -ne $rh.Trim().ToLowerInvariant()) {
                $need = $true
            }
        }
    }

    if (-not $need) {
        Write-Log "Updater：更新不要です。"
        return $false
    }

    Write-Log "Updater：更新が必要です。ダウンロードします。"

    $url = [string]$remoteUpdater.url
    if ([string]::IsNullOrWhiteSpace($url)) { throw "remote.updater.url が空です。" }

    $tmpDir = Join-Path $RootPath "_update_tmp"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    # まずはそのままDL（rawの実体）
    $downloaded = Join-Path $tmpDir "Updater.downloaded.ps1"
    Download-File $url $downloaded
    try { Unblock-File -Path $downloaded -ErrorAction SilentlyContinue } catch {}

    # remoteがsha256を持つなら「DL直後の実体」で検証（BOM付与前）
    Assert-HashIfProvided $downloaded ([string]$remoteUpdater.sha256)

    # その後、PowerShell 5.1で安定するようにUTF-8 BOM付きへ正規化
    $normalized = Join-Path $tmpDir "Updater.normalized.ps1"
    $txt = Get-Content -Path $downloaded -Raw -Encoding UTF8
    Set-Content -Path $normalized -Value $txt -Encoding UTF8

    # 比較も「正規化後」のファイル同士でやる（BOM差でループしない）
    $newHash = Get-SHA256 $normalized
    $oldHash = if (Test-Path $UpdaterPath) { Get-SHA256 $UpdaterPath } else { "" }

    if ($newHash -eq $oldHash) {
        Write-Log "Updater：ダウンロードしましたが内容は同一です（正規化後比較）。差し替えません。"
        return $false
    }

    # 差し替え（正規化済みを配置）
    $newPath = Join-Path $RootPath "Updater.ps1.new"
    Copy-Item -Path $normalized -Destination $newPath -Force
    Move-Item -Path $newPath -Destination $UpdaterPath -Force

    Write-Log "Updater：更新しました。Launcher に再実行を要求します（3010）。"
    return $true
}

# ------------------------------------------------------------
# Buildフォルダから「本体っぽいexe」を推測して1つ返す
# 方針：
#   - UnityCrashHandler系などは除外
#   - サイズが一番大きいexeを本体扱い
# ------------------------------------------------------------
function Get-MainExePath([string]$Dir) {
    if (-not (Test-Path $Dir)) { return $null }
    $c = Get-ChildItem -Path $Dir -Filter "*.exe" -File -ErrorAction SilentlyContinue
    if (-not $c) { return $null }

    $c = $c | Where-Object { $_.Name -notmatch 'UnityCrashHandler|CrashHandler|Launcher|Updater' }
    if (-not $c) { return $null }

    return ($c | Sort-Object Length -Descending | Select-Object -First 1).FullName
}

# ------------------------------------------------------------
# 実行中プロセスがある場合は更新できないので停止を促す
# ------------------------------------------------------------
function Assert-AppNotRunning([string]$ExePath) {
    if ([string]::IsNullOrWhiteSpace($ExePath) -or -not (Test-Path $ExePath)) { return }
    $name = [IO.Path]::GetFileNameWithoutExtension($ExePath)
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($p) { throw "アプリが実行中です（$name）。終了してから Launcher を実行してください。" }
}

# ------------------------------------------------------------
# Build 更新（必要ならBuild.zipをダウンロード→解凍→Buildへ入替）
# 更新条件（確定）：
#   - version / url / sha256 のどれかが不一致なら更新対象
#   - または Build 内にexeが見つからない場合も更新対象
#
# 重要：
#   - zipの中身が「Build/..」1階層でも「直置き」でも動くように判定する
#   - Get-ChildItem の結果は @(...) で配列化し .Length を使う（Count問題対策）
# ------------------------------------------------------------
function Update-BuildIfNeeded($local, $remote) {
    if (-not (Test-Path $BuildDir)) {
        New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
    }

    $remoteBuild = $remote.build
    if ($null -eq $remoteBuild) { throw "remote.build がありません。" }

    $need = Need-UpdateByManifest ($local.build) $remoteBuild

    $exe = Get-MainExePath $BuildDir
    if (-not $exe) { $need = $true }

    if (-not $need) {
        Write-Log "Build：更新不要です。"
        return $false
    }

    Write-Log "Build：更新が必要です。Build.zip をダウンロードします。"

    if ($exe) { Assert-AppNotRunning $exe }

    $zipUrl = [string]$remoteBuild.url
    if ([string]::IsNullOrWhiteSpace($zipUrl)) { throw "remote.build.url が空です。" }

    $tmpDir = Join-Path $RootPath "_update_tmp"
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $zipPath = Join-Path $tmpDir "Build.zip"
    Download-File $zipUrl $zipPath
    try { Unblock-File -Path $zipPath -ErrorAction SilentlyContinue } catch {}

    Assert-HashIfProvided $zipPath ([string]$remoteBuild.sha256)

    $extractDir = Join-Path $tmpDir "extracted"
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    # zipの中身が「Build/..」1階層か、直置きか両対応
    $newRoot = $extractDir
    $dirs  = @(Get-ChildItem -Path $extractDir -Directory -ErrorAction SilentlyContinue)
    $files = @(Get-ChildItem -Path $extractDir -File      -ErrorAction SilentlyContinue)
    if ($dirs.Length -eq 1 -and $files.Length -eq 0) {
        $newRoot = $dirs[0].FullName
    }

    $BuildNew = Join-Path $RootPath "Build_new"
    $BuildOld = Join-Path $RootPath "Build_old"

    if (Test-Path $BuildNew) { Remove-Item $BuildNew -Recurse -Force -ErrorAction SilentlyContinue }
    Move-Item -Path $newRoot -Destination $BuildNew -Force

    if (Test-Path $BuildOld) { Remove-Item $BuildOld -Recurse -Force -ErrorAction SilentlyContinue }

    # 原子的に近い入替（失敗時は可能な範囲で戻す）
    try {
        if (Test-Path $BuildDir) { Rename-Item -Path $BuildDir -NewName "Build_old" }
        Rename-Item -Path $BuildNew -NewName "Build"
    } catch {
        if ((Test-Path $BuildOld) -and -not (Test-Path $BuildDir)) {
            try { Rename-Item -Path $BuildOld -NewName "Build" } catch {}
        }
        throw
    }

    if (-not $KeepOldBuild -and (Test-Path $BuildOld)) {
        Remove-Item $BuildOld -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Log "Build：更新が完了しました。"
    return $true
}

try {
    # 1) local manifest 読み込み（無ければ空扱い）
    $local = Read-LocalManifest
    if ($null -eq $local) { $local = New-EmptyLocalManifest }

    # 2) remote manifest 取得（移転先があれば二段階確認）
    $resolved     = Try-Resolve-ManifestUrl $ManifestUrl
    $effectiveUrl = [string]$resolved.url
    $remote       = $resolved.manifest

    if ([string]::IsNullOrWhiteSpace([string]$remote.manifestUrl)) {
        $remote | Add-Member -NotePropertyName manifestUrl -NotePropertyValue $effectiveUrl -Force
    }

    # 3) Updater自己更新（必要なら差し替え→exit 3010）
    if (Update-UpdaterIfNeeded $local $remote) {
        exit $EXIT_RELAUNCH
    }

    # 4) Build更新（必要なら更新）
    [void](Update-BuildIfNeeded $local $remote)

    # 5) exe起動直前に local manifest を更新（重要：途中で書くと詰む）
    try {
        Write-LocalManifest $remote
        Write-Log "local manifest（manifest.local.json）を更新しました。"
    } catch {
        Write-Log "警告：manifest.local.json の書き込みに失敗しました：$($_.Exception.Message)"
    }

    # 6) 起動
    $exe = Get-MainExePath $BuildDir
    if (-not $exe) { throw "Buildフォルダ内に本体exeが見つかりません：$BuildDir" }

    Write-Log "アプリを起動します：$exe"
    Start-Process -FilePath $exe -WorkingDirectory $BuildDir | Out-Null
    exit 0
}
catch {
    Write-Log "エラー：$($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    exit 1
}
