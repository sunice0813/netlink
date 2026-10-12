# 编译 Windows 版并打成安装包：测试 → 发布应用和服务 → 取 openconnect → Inno Setup。
# 产物：windows\out\NetLink-<版本>-x64-setup.exe
param(
    [string]$Version = $env:NETLINK_VERSION
)
$ErrorActionPreference = 'Stop'
if (-not $Version) { $Version = '0.0.0' }

$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'out'
Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $out | Out-Null

Write-Host '▸ 测试'
dotnet test (Join-Path $root 'tests\NetLink.Tests') -c Release
if ($LASTEXITCODE -ne 0) { throw 'tests failed' }

Write-Host '▸ 发布应用和后台服务'
$common = @('-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', "-p:NETLINK_VERSION=$Version", '-p:EnableCompressionInSingleFile=true', '-p:DebugType=none')
dotnet publish (Join-Path $root 'src\NetLink.App') @common -o (Join-Path $out 'app')
if ($LASTEXITCODE -ne 0) { throw 'publish app failed' }
dotnet publish (Join-Path $root 'src\NetLink.Service') @common -o (Join-Path $out 'service')
if ($LASTEXITCODE -ne 0) { throw 'publish service failed' }

Write-Host '▸ openconnect'
& (Join-Path $PSScriptRoot 'fetch-openconnect.ps1') -Destination (Join-Path $out 'openconnect')

Write-Host '▸ 安装包'
$iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
if (-not $iscc) { $iscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' }
if (-not (Test-Path $iscc) -and (Get-Command choco -ErrorAction SilentlyContinue)) {
    # CI 镜像不一定预装 Inno Setup。
    choco install innosetup -y --no-progress | Out-Host
}
if (-not (Test-Path $iscc)) { throw 'Inno Setup 6 (ISCC.exe) is required' }
& $iscc "/DAppVersion=$Version" "/O$out" (Join-Path $root 'installer\NetLink.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with $LASTEXITCODE" }

Get-ChildItem $out -Filter '*.exe' | Format-Table Name, Length
