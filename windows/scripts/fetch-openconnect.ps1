# 下载 openconnect 官方的 Windows 构建（GitLab CI 产出的 NSIS 安装包），校验 sha256，
# 取出 openconnect.exe、依赖的 DLL、wintun.dll 和 vpnc-script-win.js，放进安装包。
# 固定到 v9.12 tag 的那次构建，每次发布打进去的都是同一份文件。
param(
    [Parameter(Mandatory = $true)][string]$Destination
)
$ErrorActionPreference = 'Stop'

$Url = 'https://gitlab.com/openconnect/openconnect/-/jobs/4319289314/artifacts/raw/openconnect-installer-MinGW64-GnuTLS.exe'
$Sha256 = 'bb7fe698c757e003af74dcfbf1ec30f64432fa4bb0e1a27e28b8a9e86f765f8e'

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("openconnect-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $installer = Join-Path $work 'openconnect-installer.exe'
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $installer -UseBasicParsing
    $actual = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) {
        throw "sha256 mismatch: expected $Sha256, got $actual"
    }

    $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
    if (-not $sevenZip) { $sevenZip = 'C:\Program Files\7-Zip\7z.exe' }
    if (-not (Test-Path $sevenZip)) { throw '7-Zip is required to unpack the openconnect installer' }

    $unpacked = Join-Path $work 'unpacked'
    & $sevenZip x -y "-o$unpacked" $installer | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip failed with $LASTEXITCODE" }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    # 只要程序本身：NSIS 的插件目录和卸载程序不要。
    Get-ChildItem -Path $unpacked -File |
        Where-Object { $_.Extension -in '.exe', '.dll', '.js' -and $_.Name -ne 'Uninstall OpenConnect.exe' } |
        Copy-Item -Destination $Destination -Force

    foreach ($required in 'openconnect.exe', 'libopenconnect-5.dll', 'wintun.dll', 'vpnc-script-win.js') {
        if (-not (Test-Path (Join-Path $Destination $required))) { throw "missing $required after unpacking" }
    }
    Get-ChildItem $Destination | Format-Table Name, Length
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
