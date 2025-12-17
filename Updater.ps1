# ==========================================
# LiveApp/Updater.ps1  (差し替え可能)
# 役割：
#   - remote manifest を取得（必要なら移転先に切替）
#   - Updater更新（必要なら差し替え→exit 3010でLauncherに再実行させる）
#   - Build更新（zip DL→検証→Build_new解凍→Buildとリネーム入替）
#   - すべて成功後、exe起動直前に manifest.local.json を更新
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

$LogDir = Join-Path $RootPath "Log"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$UpdaterPath        = Join-Path $RootPath "Updater.ps1"
$LocalManifestPath  = Join-Path $RootPath "manifest.local.json"
$UpdaterLog         = Join-Path $LogDir "updater.log"
$BuildDir           = Join-Path $RootPath "Build"

# デバッグ残骸（過去版の名残り）を消しておく
$LegacyRemoteManifest = Join-Path $RootPath "manifest.remote.json"
if (Test-Path $LegacyRemoteManifest) {
    try { Remove-Item $LegacyRemoteManifest -Force -ErrorAction SilentlyContinue } catch {}
}

# 旧Buildを残すならtrue（必要ならfalseに）
$KeepOldBuild = $true

function Write-Log([string]$Message) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][Updater] $Message"
    Write-Host $line
    try { Add-Content -Path $UpdaterLog -Value $line -Encoding UTF8 } catch {}
}

function Ensure-Tls12() {
    # Windows PowerShell 5.1向け
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

function Add-CacheBuster([string]$Url) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($Url -match '\?') { return "${Url}&v=$ts" }
    return "${Url}?v=$ts"
}

function Get-Json([string]$Url) {
    Ensure-Tls12
    $u = Add-CacheBuster $Url
    return Invoke-RestMethod -Uri $u -Method Get
}

function Download-File([string]$Url, [string]$OutFile) {
    Ensure-Tls12
    New-Item -ItemType Directory -Path (Split-Path $OutFile -Parent) -Force | Out-Null

    # BITSが使えるなら安定。ダメならWebRequestへ。
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

function Get-SHA256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

function Assert-HashIfProvided([string]$Path, [string]$Expected) {
    if ([string]::IsNullOrWhiteSpace($Expected)) { return }
    $act = Get-SHA256 $Path
    $exp = $Expected.Trim().ToLowerInvariant()
    if ($act -ne $exp) {
        throw "SHA256 mismatch. expected=$exp actual=$act file=$Path"
    }
}

function Read-LocalManifest() {
    if (-not (Test-Path $LocalManifestPath)) { return $null }
    try {
        return (Get-Content -Path $LocalManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function New-EmptyLocalManifest() {
    return [pscustomobject]@{
        manifestUrl = ""
        build   = [pscustomobject]@{ version=""; url=""; sha256="" }
        updater = [pscustomobject]@{ version=""; url=""; sha256="" }
    }
}

function Write-LocalManifest($manifestObj) {
    # 「成功した最後」にだけ呼ぶ想定（安全に tmp→rename）
    $tmp = Join-Path $RootPath "manifest.local.json.tmp"
    $json = $manifestObj | ConvertTo-Json -Depth 10
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    Move-Item -Path $tmp -Destination $LocalManifestPath -Force
}

function Same-Field([string]$a, [string]$b) {
    return ([string]$a).Trim() -eq ([string]$b).Trim()
}

function Need-UpdateByManifest($localPart, $remotePart) {
    # version/url/sha256 のどれかが不一致なら更新対象
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

function Try-Resolve-ManifestUrl([string]$initialUrl) {
    # 1) まず初期URLで取得
    Write-Log "Fetch remote manifest: $initialUrl"
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

    # 2) 二段階確認：候補URLでも取得できるか確認できたら切替
    Write-Log "ManifestUrl differs. Validate new url: $candidate"
    try {
        $m2 = Get-Json $candidate
        if ([string]::IsNullOrWhiteSpace([string]$m2.manifestUrl)) {
            $m2 | Add-Member -NotePropertyName manifestUrl -NotePropertyValue $candidate -Force
        }
        Write-Log "ManifestUrl switched to: $candidate"
        return @{ url = $candidate; manifest = $m2 }
    } catch {
        Write-Log "New manifestUrl not reachable. Keep old url."
        return @{ url = $initialUrl; manifest = $m1 }
    }
}

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
        Write-Log "Updater: no update needed."
        return $false
    }

    Write-Log "Updater: update needed. Downloading..."

    $url = [string]$remoteUpdater.url
    if ([string]::IsNullOrWhiteSpace($url)) { throw "remote.updater.url is empty." }

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
    Set-Content -Path $normalized -Value $txt -Encoding UTF8   # PS5.1: UTF8はBOM付きで保存される

    # 比較も「正規化後」のファイル同士でやる（BOM差でループしない）
    $newHash = Get-SHA256 $normalized
    $oldHash = if (Test-Path $UpdaterPath) { Get-SHA256 $UpdaterPath } else { "" }

    if ($newHash -eq $oldHash) {
        Write-Log "Updater: downloaded but identical (normalized). Skip replace."
        return $false
    }

    # 差し替え（正規化済みを配置）
    $newPath = Join-Path $RootPath "Updater.ps1.new"
    Copy-Item -Path $normalized -Destination $newPath -Force
    Move-Item -Path $newPath -Destination $UpdaterPath -Force

    Write-Log "Updater updated. Request relaunch."
    return $true
}

function Get-MainExePath([string]$Dir) {
    if (-not (Test-Path $Dir)) { return $null }
    $c = Get-ChildItem -Path $Dir -Filter "*.exe" -File -ErrorAction SilentlyContinue
    if (-not $c) { return $null }

    $c = $c | Where-Object { $_.Name -notmatch 'UnityCrashHandler|CrashHandler|Launcher|Updater' }
    if (-not $c) { return $null }

    return ($c | Sort-Object Length -Descending | Select-Object -First 1).FullName
}

function Assert-AppNotRunning([string]$ExePath) {
    if ([string]::IsNullOrWhiteSpace($ExePath) -or -not (Test-Path $ExePath)) { return }
    $name = [IO.Path]::GetFileNameWithoutExtension($ExePath)
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($p) { throw "App is running ($name). Close it and run Launcher again." }
}

function Update-BuildIfNeeded($local, $remote) {
    if (-not (Test-Path $BuildDir)) {
        New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
    }

    $remoteBuild = $remote.build
    if ($null -eq $remoteBuild) { throw "remote.build is missing." }

    $need = Need-UpdateByManifest ($local.build) $remoteBuild

    $exe = Get-MainExePath $BuildDir
    if (-not $exe) { $need = $true }

    if (-not $need) {
        Write-Log "Build: no update needed."
        return $false
    }

    Write-Log "Build: update needed. Downloading zip..."

    if ($exe) { Assert-AppNotRunning $exe }

    $zipUrl = [string]$remoteBuild.url
    if ([string]::IsNullOrWhiteSpace($zipUrl)) { throw "remote.build.url is empty." }

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

    Write-Log "Build updated."
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

    # 4) Build更新
    [void](Update-BuildIfNeeded $local $remote)

    # 5) exe起動前に local manifest を更新（更新が無くてもURL移転の反映などのために書く）
    try {
        Write-LocalManifest $remote
        Write-Log "Local manifest updated."
    } catch {
        Write-Log "WARN: Failed to write manifest.local.json: $($_.Exception.Message)"
    }

    # 6) 起動
    $exe = Get-MainExePath $BuildDir
    if (-not $exe) { throw "Main exe not found in Build folder: $BuildDir" }

    Write-Log "Starting exe: $exe"
    Start-Process -FilePath $exe -WorkingDirectory $BuildDir | Out-Null
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    exit 1
}
