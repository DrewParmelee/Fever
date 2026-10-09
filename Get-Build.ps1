#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'build-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-ContainedPath([string] $root, [string] $relativePath) {
    $fullRoot = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath((Join-Path $fullRoot $relativePath))
    if (-not $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside its expected directory: $relativePath"
    }
    return $fullPath
}

if ($manifest.release -notmatch '^[A-Za-z0-9._-]+$' -or $manifest.archive -ne 'Fever-Windows-x64.tar.gz') {
    throw 'Invalid release or archive in build-manifest.json.'
}
$parts = @($manifest.parts)
$files = @($manifest.files)
if ($parts.Count -eq 0 -or $files.Count -eq 0) {
    throw 'The build manifest must contain archive parts and runtime files.'
}
for ($index = 0; $index -lt $parts.Count; $index++) {
    $part = $parts[$index]
    if ($part.name -ne ('{0}.part{1:D3}' -f $manifest.archive, ($index + 1)) -or
        [long] $part.size -le 0 -or $part.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "Invalid archive part at position $($index + 1)."
    }
}
$expectedFiles = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $files) {
    $path = [string] $file.path
    if ($path -notmatch '^Build/[^\\]+$' -or $path.Split('/') -contains '..' -or
        $path.Split('/') -contains '.' -or [long] $file.size -lt 0 -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "Invalid runtime file in manifest: $path"
    }
    # Resolve every manifest path before using it for verification or extraction.
    $null = Get-ContainedPath $repoRoot $path
    $expectedFiles.Add($path, $file)
}
if (-not $expectedFiles.ContainsKey('Build/Hivemind.exe')) {
    throw 'The manifest does not contain Build/Hivemind.exe.'
}

function Assert-Build([string] $buildRoot) {
    if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
        throw 'The extracted build directory is missing.'
    }
    $entries = @((Get-Item -LiteralPath $buildRoot -Force)) + @(Get-ChildItem -LiteralPath $buildRoot -Recurse -Force)
    if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
        throw 'Build verification rejected a link or junction.'
    }
    $actualFiles = @($entries | Where-Object { -not $_.PSIsContainer })
    if ($actualFiles.Count -ne $expectedFiles.Count) {
        throw "Build file count differs from the manifest: $($actualFiles.Count) instead of $($expectedFiles.Count)."
    }
    foreach ($file in $files) {
        $filePath = Get-ContainedPath $buildRoot $file.path.Substring('Build/'.Length)
        $actualFile = Get-Item -LiteralPath $filePath -Force
        if ($actualFile.PSIsContainer -or $actualFile.Length -ne [long] $file.size -or
            (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash -ne $file.sha256) {
            throw "Build verification failed: $($file.path)"
        }
    }
}

$buildPath = Get-ContainedPath $repoRoot 'Build'
if (Test-Path -LiteralPath $buildPath) {
    if (-not (Test-Path -LiteralPath $buildPath -PathType Container)) {
        throw 'Build exists as a file. Move it aside before downloading the game.'
    }
    try {
        Write-Host 'Checking the installed build...'
        Assert-Build $buildPath
        Write-Host "The build already matches $($manifest.release). Run .\Build\Hivemind.exe."
        return
    } catch {
        Write-Host 'The installed build differs; it will be backed up after the download is verified.'
    }
}
$tar = (Get-Command tar.exe -ErrorAction Stop).Source
$temporaryRoot = Get-ContainedPath $repoRoot ('.fever-download-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporaryRoot
$archivePath = Get-ContainedPath $temporaryRoot $manifest.archive
$partPath = Get-ContainedPath $temporaryRoot 'download.part'
$extractPath = Get-ContainedPath $temporaryRoot 'extracted'
$archiveStream = $null
$originalProgressPreference = $ProgressPreference
$originalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    foreach ($part in $parts) {
        Write-Host "Downloading $($part.name)..."
        $url = 'https://github.com/DrewParmelee/Fever/releases/download/{0}/{1}' -f $manifest.release, $part.name
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $partPath
        if ((Get-Item -LiteralPath $partPath).Length -ne [long] $part.size -or
            (Get-FileHash -LiteralPath $partPath -Algorithm SHA256).Hash -ne $part.sha256) {
            throw "Download verification failed: $($part.name). Run this script again to retry."
        }
        $partStream = [IO.File]::OpenRead($partPath)
        try { $partStream.CopyTo($archiveStream) } finally { $partStream.Dispose() }
        Remove-Item -LiteralPath $partPath
    }
    $archiveStream.Dispose()
    $archiveStream = $null

    Write-Host 'Extracting and checking every runtime file...'
    $null = New-Item -ItemType Directory -Path $extractPath
    & $tar -xzf $archivePath -C $extractPath
    if ($LASTEXITCODE -ne 0) { throw 'Archive extraction failed.' }
    $extractedBuild = Get-ContainedPath $extractPath 'Build'
    Assert-Build $extractedBuild

    $backupPath = $null
    if (Test-Path -LiteralPath $buildPath) {
        $backupPath = Get-ContainedPath $repoRoot ('Build.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        Move-Item -LiteralPath $buildPath -Destination $backupPath
    }
    try {
        Move-Item -LiteralPath $extractedBuild -Destination $buildPath
    } catch {
        if ($backupPath -and -not (Test-Path -LiteralPath $buildPath)) {
            Move-Item -LiteralPath $backupPath -Destination $buildPath
        }
        throw
    }
    Write-Host "Installed $($manifest.release). Run .\Build\Hivemind.exe."
    if ($backupPath) { Write-Host "Previous build preserved at $backupPath" }
} finally {
    if ($archiveStream) { $archiveStream.Dispose() }
    $ProgressPreference = $originalProgressPreference
    [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
    # This unique, contained directory was created by this invocation only.
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
