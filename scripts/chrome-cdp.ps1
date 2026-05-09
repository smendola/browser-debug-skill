#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Launch Chrome with remote debugging on port 9222 using a clean/shared profile.
  Windows PowerShell version of chrome-cdp-normal.sh.
#>
param(
  [switch] $Reset,
  [string] $Clone,
  [switch] $Help
)

$ErrorActionPreference = "Stop"

# --- config ---
$DataDir = "$env:USERPROFILE\.chrome-debug-profile"
$ChromeUserData = "$env:LOCALAPPDATA\Google\Chrome\User Data"
$ChromeExe = "C:\Program Files\Google\Chrome\Application\chrome.exe"

# --- usage ---
function Usage($code = 0) {
  Write-Host @"
Usage: $($MyInvocation.MyCommand.Name) [-Reset | -Clone <ProfileName>] [-Help]
  -Reset             Clear the test data dir before launching
  -Clone <Profile>   Copy Bookmarks, History, Cookies, Preferences,
                     Local Storage, Extensions, and Local State from
                     %LOCALAPPDATA%\Google\Chrome\User Data\<Profile>
                     into the test dir, skipping all cache directories.
  -Reset and -Clone are mutually exclusive.
"@
  exit $code
}

# --- help ---
if ($Help) { Usage 0 }

# --- mutually exclusive ---
if ($Reset -and $Clone) {
  Write-Host "ERROR: -Reset and -Clone are mutually exclusive" -ForegroundColor Red
  Usage 1
}

# --- stop any running Chrome so the profile is not locked ---
$null = Get-Process -Name "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

# --- -Reset: blow away the test data dir ---
if ($Reset) {
  Write-Host "==> Removing $DataDir"
  Remove-Item -Recurse -Force $DataDir -ErrorAction SilentlyContinue
}

# --- -Clone: copy selected profile data (no cache) ---
if ($Clone) {
  $Src = Join-Path $ChromeUserData $Clone
  if (-not (Test-Path $Src)) {
    Write-Host "ERROR: profile '$Clone' not found at $Src" -ForegroundColor Red
    exit 1
  }

  $Dst = Join-Path $DataDir "Default"
  Write-Host "==> Cloning '$Clone' -> $Dst"
  Remove-Item -Recurse -Force $DataDir -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $Dst | Out-Null

  $items = @("Bookmarks", "History", "Cookies", "Preferences", "Local Storage", "Extensions")
  foreach ($item in $items) {
    $srcPath = Join-Path $Src $item
    if (Test-Path $srcPath) {
      Copy-Item -Recurse -Force $srcPath $Dst
      Write-Host "    $item"
    }
  }

  # Local State lives one level above profiles (browser-wide)
  $localState = Join-Path $ChromeUserData "Local State"
  if (Test-Path $localState) {
    Copy-Item -Force $localState $DataDir
    Write-Host "    Local State"
  }
}

# --- launch Chrome with CDP ---
$logFile = "$env:TEMP\chrome-cdp.log"
$null = New-Item -Force $logFile

$proc = Start-Process -FilePath $ChromeExe -ArgumentList @(
  "--remote-debugging-address=127.0.0.1",
  "--remote-debugging-port=9222",
  "--user-data-dir=$DataDir",
  "--no-first-run",
  "--no-default-browser-check"
) -PassThru -RedirectStandardOutput $logFile -RedirectStandardError $logFile -WindowStyle Hidden

Write-Host "PID=$($proc.Id)"
Write-Host "Log: $logFile"

# Quick check
Start-Sleep -Seconds 5
try {
  $version = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/version"
  $version | ConvertTo-Json
} catch {
  Write-Host "WARNING: CDP not reachable yet (Chrome may still be starting)" -ForegroundColor Yellow
}
