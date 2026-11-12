# Run after: pnpm tauri build --bundles nsis (Windows x64 MSVC).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $repoRoot 'src-tauri/target/release'
$app = Join-Path $releaseDir 'huangguo-client.exe'
$setupName = "HGhub_${Version}_x64-setup.exe"
$setup = Join-Path $releaseDir "bundle/nsis/$setupName"
$license = Join-Path $repoRoot 'LICENSE'
$outputDir = Join-Path $repoRoot 'artifacts'

function Assert-PeExecutable {
    param([string]$Path, [switch]$RequireX64)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing executable: $Path"
    }
    $reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($Path))
    try {
        if ($reader.BaseStream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "Invalid DOS/PE header: $Path"
        }
        $reader.BaseStream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 64 -or $peOffset -gt ($reader.BaseStream.Length - 26)) {
            throw "Invalid PE offset: $Path"
        }
        $reader.BaseStream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $Path" }
        $machine = $reader.ReadUInt16()
        $reader.BaseStream.Position = $peOffset + 22
        $characteristics = $reader.ReadUInt16()
        $magic = $reader.ReadUInt16()
        if (($characteristics -band 0x0002) -eq 0 -or ($characteristics -band 0x2000) -ne 0) {
            throw "PE is not an application executable: $Path"
        }
        if (-not (($machine -eq 0x8664 -and $magic -eq 0x020B) -or
                  ($machine -eq 0x014C -and $magic -eq 0x010B))) {
            throw "Unsupported PE machine/header: $Path"
        }
        if ($RequireX64 -and $machine -ne 0x8664) { throw "Application must be x64: $Path" }
        Write-Host ('Verified PE: {0} (machine 0x{1:X4})' -f $Path, $machine)
    }
    finally { $reader.Dispose() }
}

$config = Get-Content -LiteralPath (Join-Path $repoRoot 'src-tauri/tauri.conf.json') -Raw | ConvertFrom-Json
if ($config.version -ne $Version) { throw "Requested version differs from tauri.conf.json: $Version" }
if ($config.productName -ne 'HGhub') { throw 'Unexpected product name; review artifact naming first.' }
if (-not (Test-Path -LiteralPath $license -PathType Leaf)) { throw 'LICENSE is missing.' }
if (-not (Select-String -LiteralPath $license -Pattern '^Required Notice:' -Quiet)) {
    throw 'LICENSE is missing its Required Notice.'
}
if (Test-Path -LiteralPath $outputDir) {
    throw 'artifacts/ already exists. Move it aside before packaging to avoid stale release assets.'
}
Assert-PeExecutable -Path $app -RequireX64
# NSIS can use a 32-bit installer stub containing a 64-bit application.
Assert-PeExecutable -Path $setup

# Keep staging on the workspace volume so the final directory move is reliable.
$stage = Join-Path $repoRoot ('.package-windows-' + [guid]::NewGuid().ToString('N'))
$portableDir = Join-Path $stage 'portable'
$stagedArtifacts = Join-Path $stage 'artifacts'
$utf8 = [System.Text.UTF8Encoding]::new($false)
try {
    New-Item -ItemType Directory -Path $portableDir, $stagedArtifacts | Out-Null
    Copy-Item -LiteralPath $app -Destination (Join-Path $portableDir 'HGhub.exe')
    Copy-Item -LiteralPath $license -Destination (Join-Path $portableDir 'LICENSE.txt')
    $readme = @"
HGhub $Version — Windows x64 免安装版

1. 将 ZIP 中的全部文件解压到一个文件夹，双击 HGhub.exe 启动。
2. 适用于 64 位 Windows 10 / 11，需要 Microsoft Edge WebView2 Runtime。
   如缺少运行时，请使用同一版本的 x64-setup.exe 安装包；安装器可联网安装 WebView2。
3. 此包无需安装，但设置、会话等仍保存在 Windows 用户应用数据目录，
   不会随 HGhub.exe 一起移动。

本构建来自 https://github.com/cymx333/HGhub，基于上游 Minireel/HGhub。
本软件仅限非商业用途；完整许可证及原有版权声明见 LICENSE.txt。
"@
    [System.IO.File]::WriteAllText((Join-Path $portableDir 'README.txt'), $readme + "`n", $utf8)
    Copy-Item -LiteralPath $setup -Destination (Join-Path $stagedArtifacts $setupName)
    Copy-Item -LiteralPath $license -Destination (Join-Path $stagedArtifacts 'LICENSE.txt')
    $zipPath = Join-Path $stagedArtifacts "HGhub_${Version}_x64_portable.zip"
    Compress-Archive -Path (Join-Path $portableDir '*') -DestinationPath $zipPath -CompressionLevel Optimal

    # Read back the ZIP and compare the actual packaged executable to the build output.
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names = @($archive.Entries | ForEach-Object { $_.FullName } | Sort-Object)
        $expected = @('HGhub.exe', 'LICENSE.txt', 'README.txt') | Sort-Object
        if ($names.Count -ne 3 -or (Compare-Object $names $expected)) {
            throw 'Portable ZIP does not contain exactly HGhub.exe, LICENSE.txt and README.txt.'
        }
    }
    finally { $archive.Dispose() }
    $verificationDir = Join-Path $stage 'verification'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $verificationDir
    foreach ($entry in @(@($app, 'HGhub.exe'), @($license, 'LICENSE.txt'))) {
        if ((Get-FileHash -LiteralPath $entry[0] -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath (Join-Path $verificationDir $entry[1]) -Algorithm SHA256).Hash) {
            throw "Portable ZIP verification failed: $($entry[1])"
        }
    }
    $checksums = @(Get-ChildItem -LiteralPath $stagedArtifacts -File | Sort-Object Name | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
    })
    [System.IO.File]::WriteAllText((Join-Path $stagedArtifacts 'SHA256SUMS.txt'), ($checksums -join "`n") + "`n", $utf8)
    Move-Item -LiteralPath $stagedArtifacts -Destination $outputDir
    Get-ChildItem -LiteralPath $outputDir -File | Select-Object Name, Length
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
