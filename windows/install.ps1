# install.ps1 — register the `tui-linkify://` protocol handler on Windows.
#
#   powershell -NoProfile -File install.ps1 -DryRun            # show the plan
#   powershell -NoProfile -File install.ps1 -Apply             # copy handler + register
#   powershell -NoProfile -File install.ps1 -Apply -Uninstall   # remove the registration
#
# Copies to %USERPROFILE%\.local\bin\: tui-linkify-open.ps1, apps.json
# Registers HKCU:\Software\Classes\tui-linkify (per-user, no admin needed).

param(
    [string]$Source = "",                # dir holding tui-linkify-open.ps1 + apps.json (UNC ok)
    [string]$Distro = "",
    [string]$Dest = "",
    [switch]$Apply,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

if (-not $Source) { $Source = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Dest) { $Dest = Join-Path $env:USERPROFILE ".local\bin" }
if (-not $Distro) { $Distro = $env:WSL_DISTRO_NAME; if (-not $Distro) { $Distro = "Ubuntu-24.04" } }

$handler = Join-Path $Dest "tui-linkify-open.ps1"
$table = Join-Path $Dest "apps.json"
$key = "HKCU:\Software\Classes\tui-linkify"
$command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$handler`" `"%1`""

if ($Uninstall) {
    if (Test-Path $key) {
        if ($Apply) { Remove-Item -Recurse -Force $key; Write-Host "removed: $key" }
        else { Write-Host "would remove: $key" }
    } else { Write-Host "not registered: $key" }
    exit 0
}

Write-Host "source    : $Source"
Write-Host "dest      : $Dest"
Write-Host "distro    : $Distro"
Write-Host "registry  : $key"
Write-Host "command   : $command"

if (-not $Apply) {
    Write-Host ""
    Write-Host "dry run — add -Apply to copy the handler and write the registry key."
    exit 0
}

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($file in @("tui-linkify-open.ps1", "apps.json")) {
    $from = Join-Path $Source $file
    if (-not (Test-Path -LiteralPath $from)) { throw "missing: $from" }
    Copy-Item -LiteralPath $from -Destination (Join-Path $Dest $file) -Force
    Write-Host "copied: $file -> $Dest"
}

if (Test-Path $key) {
    $existing = (Get-ItemProperty -Path "$key\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
    Write-Host "existing registration: $existing (overwriting)"
} else {
    New-Item -Path $key -Force | Out-Null
}
New-Item -Path "$key\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path $key -Name "(default)" -Value "URL:tui-linkify Protocol"
Set-ItemProperty -Path $key -Name "URL Protocol" -Value ""
Set-ItemProperty -Path "$key\shell\open\command" -Name "(default)" -Value $command
Write-Host "registered: $key"

# remember the distro for links that carry no ?d=
[Environment]::SetEnvironmentVariable("TUI_LINKIFY_DISTRO", $Distro, "User")
Write-Host "env (User): TUI_LINKIFY_DISTRO=$Distro"
Write-Host ""
Write-Host "verify:  powershell -NoProfile -File `"$handler`" -DryRun 'tui-linkify://open?k=posix&p=%2Fhome%2Fsexy%2F.bashrc'"
