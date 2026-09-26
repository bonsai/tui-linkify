# tui-linkify-open.ps1 — protocol handler for `tui-linkify://open?k=<kind>&p=<path>[&d=<distro>]`
#
# Called by Windows when a link emitted by tui-linkify.ts is clicked.
# Dispatches to an application per file extension using apps.json next to this
# script. Unknown extensions fall back to the Windows default handler.
#
#   tui-linkify://open?k=posix&p=%2Fhome%2Fsexy%2Fx.md&d=Ubuntu-24.04
#   tui-linkify://open?k=win&p=C%3A%5CUsers%5Cdance%5Cx.txt
#   tui-linkify://open?k=dir&p=%2Fhome%2Fsexy
#
# Manual test:
#   powershell -NoProfile -File tui-linkify-open.ps1 -DryRun 'tui-linkify://open?k=posix&p=%2Fhome%2Fsexy%2F.bashrc'

param(
    [Parameter(Position = 0)][string]$Uri = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$logPath = Join-Path $env:TEMP "tui-linkify-open.log"

function Write-Log([string]$Message) {
    try { Add-Content -Path $logPath -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) } catch {}
}

function Unescape([string]$Value) {
    try { return [System.Uri]::UnescapeDataString($Value) } catch { return $Value }
}

if (-not $Uri) {
    Write-Log "no argument"
    exit 2
}

# accept both a full URI and a bare path
$kind = "auto"; $distro = ""; $target = $Uri
if ($Uri -match '^(?<scheme>[a-zA-Z][a-zA-Z0-9+.\-]*)://(?<rest>.*)$') {
    $rest = $Matches["rest"]
    $query = ""
    if ($rest -match '^(?<path>[^?]*)\?(?<query>.*)$') { $query = $Matches["query"] }
    foreach ($pair in ($query -split '&')) {
        if ($pair -match '^(?<k>[^=]+)=(?<v>.*)$') {
            switch ($Matches["k"]) {
                "k" { $kind = Unescape $Matches["v"] }
                "p" { $target = Unescape $Matches["v"] }
                "d" { $distro = Unescape $Matches["v"] }
            }
        }
    }
}

# split a trailing :line[:col] (pi/opencode style) from the path
$line = ""
if ($target -match '^(?<path>.*?)(?::(?<ln>\d+)(?::(?<col>\d+))?)$') {
    $target = $Matches["path"]
    $line = $Matches["ln"] + $(if ($Matches["col"]) { ":" + $Matches["col"] } else { "" })
}

if (-not $distro) { $distro = $env:TUI_LINKIFY_DISTRO; if (-not $distro) { $distro = "Ubuntu-24.04" } }

# map the path to something Windows apps can open
$isDir = $false
switch ($kind) {
    "posix" {
        $win = "\\wsl.localhost\$distro" + ($target -replace '/', '\')
        # a directory in WSL is still a directory from Windows' point of view
        try { $isDir = (Test-Path -LiteralPath $win -PathType Container) } catch { $isDir = $false }
        $target = $win
    }
    "dir" {
        $win = "\\wsl.localhost\$distro" + ($target -replace '/', '\')
        $isDir = $true; $target = $win
    }
    default {
        try { $isDir = (Test-Path -LiteralPath $target -PathType Container) } catch { $isDir = $false }
    }
}

$ext = ""
if (-not $isDir) {
    try { $ext = [System.IO.Path]::GetExtension($target).ToLower() } catch { $ext = "" }
}

# ---- app table -------------------------------------------------------------
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$tablePath = Join-Path $dir "apps.json"
$apps = @{}
$byExt = @{}
if (Test-Path -LiteralPath $tablePath) {
    $table = Get-Content -LiteralPath $tablePath -Raw | ConvertFrom-Json
    if ($table.apps) { $table.apps.PSObject.Properties | ForEach-Object { $apps[$_.Name] = $_.Value } }
    if ($table.byExt) { $table.byExt.PSObject.Properties | ForEach-Object { $byExt[$_.Name.ToLower()] = $_.Value } }
}
if ($isDir) { $ext = "dir" }

$appName = ""
if ($ext -and $byExt.ContainsKey($ext)) { $appName = $byExt[$ext] }

$exe = ""
$argv = @()
if ($appName -and $apps.ContainsKey($appName)) {
    $exe = $apps[$appName]
} elseif ($appName -and (Test-Path -LiteralPath $appName)) {
    $exe = $appName
}

# VS Code understands \\wsl.localhost paths and a --goto target
if ($exe -and $line -and ($appName -match 'code|vscode')) {
    $argv = @("--goto", "$target`:$line")
} elseif ($exe) {
    $argv = @($target)
}

$action = if ($exe) { "$exe $($argv -join ' ')" } else { "Start-Process `"$target`" (Windows default)" }
Write-Log "uri=$Uri kind=$kind ext=$ext app=$appName -> $action"

if ($DryRun) {
    [pscustomobject]@{ kind = $kind; target = $target; ext = $ext; app = $appName; command = $action } | ConvertTo-Json -Compress
    exit 0
}

try {
    if ($exe) {
        Start-Process -FilePath $exe -ArgumentList $argv | Out-Null
    } elseif ($isDir) {
        Start-Process -FilePath "explorer.exe" -ArgumentList @($target) | Out-Null
    } else {
        Start-Process -FilePath $target | Out-Null
    }
} catch {
    Write-Log "error: $($_.Exception.Message)"
    exit 1
}
exit 0
