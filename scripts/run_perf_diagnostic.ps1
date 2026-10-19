# SPDX-License-Identifier: GPL-2.0-or-later
param(
    [Parameter(Mandatory=$true)][string]$GameDir,
    [Parameter(Mandatory=$true)][string]$UserDir,
    [Parameter(Mandatory=$true)][string]$Probe,
    [string]$Python = 'python',
    [string]$MsysRoot = 'C:\msys64',
    [switch]$NoTrace
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$gamePath = (Resolve-Path -LiteralPath $GameDir).Path
$probePath = (Resolve-Path -LiteralPath $Probe).Path
$dataPath = [IO.Path]::GetFullPath($UserDir)
if ($dataPath.TrimEnd('\') -eq $gamePath.TrimEnd('\')) { throw 'Use a separate folder for user data.' }
if (-not (Test-Path -LiteralPath (Join-Path $gamePath 'eboot.bin'))) { throw 'Missing eboot.bin.' }
$pythonPath = (Get-Command $Python -ErrorAction Stop).Source
$keys = @('ISS_GAME_DIR','ISS_USER_DIR','ISS_DIAG_PROBE','TLG_PERF_TRACE','TLG_PERF_FRAMES','TLG_FRAME_STATS','TLG_DCB_STATS','PYTHONPATH','PATH')
$saved = @{}
foreach ($key in $keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key,'Process') }
try {
    $env:ISS_GAME_DIR = $gamePath
    $env:ISS_USER_DIR = $dataPath
    $env:ISS_DIAG_PROBE = $probePath
    $env:TLG_PERF_TRACE = if ($NoTrace) { '0' } else { '1' }
    $env:TLG_PERF_FRAMES = '1'
    $env:TLG_FRAME_STATS = '1'
    $env:TLG_DCB_STATS = '1'
    $env:PYTHONPATH = Join-Path $repo 'port\launcher'
    $env:PATH = (Join-Path $MsysRoot 'clang64\bin') + [IO.Path]::PathSeparator + $env:PATH
    & $pythonPath -c 'import sys; from pathlib import Path; import infamous_run as r; r.PROBE=Path(sys.argv[1]); raise SystemExit(r.main([]))' $probePath
    $result = $LASTEXITCODE
} finally {
    foreach ($key in $keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key],'Process') }
}
exit $result
