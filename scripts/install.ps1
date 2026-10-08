<#
.SYNOPSIS
  Installs Plomada: the SketchUp extension, the Python bridge, and the MCP
  registrations for Claude Desktop and Claude Code.

.DESCRIPTION
  0. Checks the installed SketchUp builds (and warns if SketchUp is running).
  1. Copies extension\plomada.rb and extension\plomada\ into the SketchUp
     Plugins folder (a previous plomada\ folder is replaced).
  2. Runs uv sync for the bridge.
  3. Backs up the Claude Desktop config and sets only mcpServers.sketchup.
  4. Registers the server for Claude Code (user scope).
  5. Offers to move the old Tarkiin plugin (sketchup_mcp_server.rb) out of the
     Plugins folder into C:\mcp\_desactivados, after asking y/n.
  Restart SketchUp afterwards.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\install.ps1
#>
param(
    [string]$SketchUpYear = "2025",
    [switch]$Yes  # answer yes to the Tarkiin question (unattended installs)
)

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$Plugins = Join-Path $env:APPDATA "SketchUp\SketchUp $SketchUpYear\SketchUp\Plugins"
$DesktopConfig = Join-Path $env:LOCALAPPDATA "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json"
$Exe = Join-Path $Repo ".venv\Scripts\plomada-mcp.exe"
$Python = Join-Path $Repo ".venv\Scripts\python.exe"
$Deactivated = "C:\mcp\_desactivados"

function Step($n, $text) { Write-Host "`n[$n] $text" -ForegroundColor Cyan }

# 0. Compatibility --------------------------------------------------------------
Step 0 "Checking SketchUp"
$Install = "C:\Program Files\SketchUp\SketchUp $SketchUpYear\SketchUp\SketchUp.exe"
if (-not (Test-Path $Install)) { throw "SketchUp $SketchUpYear is not installed at $Install" }
$Version = (Get-Item $Install).VersionInfo.FileVersion
Write-Host "  SketchUp $SketchUpYear build $Version (Plomada targets 2024-2026 by feature detection)"
if (Get-Process SketchUp -ErrorAction SilentlyContinue) {
    Write-Host "  SketchUp is running: restart it after this script so it loads the new extension." -ForegroundColor Yellow
}

# 1. Extension ------------------------------------------------------------------
Step 1 "Copying the extension to $Plugins"
New-Item -ItemType Directory -Force $Plugins | Out-Null
$Target = Join-Path $Plugins "plomada"
if (Test-Path $Target) { Remove-Item -Recurse -Force $Target }
Copy-Item (Join-Path $Repo "extension\plomada.rb") $Plugins -Force
Copy-Item (Join-Path $Repo "extension\plomada") $Plugins -Recurse -Force
Write-Host "  plomada.rb + plomada\ ($((Get-ChildItem $Target -Recurse -File).Count) files)"

# 2. Bridge ---------------------------------------------------------------------
Step 2 "uv sync"
Push-Location $Repo
try { uv sync; if ($LASTEXITCODE -ne 0) { throw "uv sync failed" } } finally { Pop-Location }
if (-not (Test-Path $Exe)) { throw "uv sync did not produce $Exe" }
Write-Host "  bridge: $Exe"

# 3. Claude Desktop -------------------------------------------------------------
Step 3 "Claude Desktop config (only mcpServers.sketchup changes)"
& $Python (Join-Path $Repo "scripts\merge_claude_config.py") $DesktopConfig $Exe
if ($LASTEXITCODE -ne 0) { throw "could not update $DesktopConfig" }

# 4. Claude Code ----------------------------------------------------------------
Step 4 "Claude Code (user scope)"
if (Get-Command claude -ErrorAction SilentlyContinue) {
    & claude mcp remove -s user sketchup 2>$null | Out-Null
    & claude mcp add -s user sketchup -- $Exe
    if ($LASTEXITCODE -ne 0) { throw "claude mcp add failed" }
} else {
    Write-Host "  claude CLI not found; register it later with: claude mcp add -s user sketchup -- `"$Exe`"" -ForegroundColor Yellow
}

# 5. Old Tarkiin plugin -----------------------------------------------------------
Step 5 "Old Tarkiin SketchUp-MCP plugin"
$Old = Join-Path $Plugins "sketchup_mcp_server.rb"
if (Test-Path $Old) {
    Write-Host "  Found $Old"
    Write-Host "  It runs its own server on port 8080 with Ruby threads. Plomada replaces it."
    Write-Host "  This will MOVE it to $Deactivated (nothing is deleted)."
    $answer = if ($Yes) { "y" } else { Read-Host "  Move it now? (y/n)" }
    if ($answer -match '^(y|yes|s|si)$') {
        New-Item -ItemType Directory -Force $Deactivated | Out-Null
        $Dest = Join-Path $Deactivated "sketchup_mcp_server.rb"
        if (Test-Path $Dest) { $Dest = Join-Path $Deactivated ("sketchup_mcp_server.{0:yyyyMMdd-HHmmss}.rb" -f (Get-Date)) }
        Move-Item $Old $Dest
        Write-Host "  moved to $Dest"
    } else {
        Write-Host "  left in place"
    }
} else {
    Write-Host "  not present"
}

Write-Host "`nDone. Restart SketchUp, then reconnect the MCP and call status." -ForegroundColor Green
