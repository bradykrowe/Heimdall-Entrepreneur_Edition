<#
    Heimdall Entrepreneur Edition: download, verify and install on Windows.

    One line, pasted into PowerShell:
      irm https://raw.githubusercontent.com/bradykrowe/Heimdall-Entrepreneur_Edition/v0.1.0-beta/get.ps1 | iex

    To pass installer flags, download the script first and run it:
      irm https://raw.githubusercontent.com/bradykrowe/Heimdall-Entrepreneur_Edition/v0.1.0-beta/get.ps1 -OutFile get.ps1
      powershell -ExecutionPolicy Bypass -File .\get.ps1 -SkipSoftware

    What it does, in order:
      1. Reads the GitHub Release for the pinned tag below.
      2. Downloads the install zip and its .sha256 into your Downloads folder.
      3. Refuses to continue if the hash does not match.
      4. Unpacks the zip and runs Install_Heimdall.ps1.

    It never asks for administrator rights itself. Install_Heimdall.ps1 uses
    winget for the software step, which may prompt on its own.
#>
param(
    [string]$Tag = $(if ($env:SECOND_BRAIN_TAG) { $env:SECOND_BRAIN_TAG } else { "v0.1.0-beta" }),
    [string]$VaultPath = "",
    [switch]$SkipSoftware,
    [switch]$Unattended,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = "bradykrowe/Heimdall-Entrepreneur_Edition"
$Dest = Join-Path $env:USERPROFILE "Downloads"

# Private beta only: a GitHub token in HEIMDALL_GITHUB_TOKEN (or GH_TOKEN)
# lets this script read a release that is not public yet. Leave it unset
# otherwise; a public release needs no token and the script never sends one.
$Token = $env:HEIMDALL_GITHUB_TOKEN
if (-not $Token) { $Token = $env:GH_TOKEN }
$ApiHeaders = @{ Accept = "application/vnd.github+json" }
if ($Token) { $ApiHeaders["Authorization"] = "Bearer $Token" }

Write-Host "Reading release $Tag ..."
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$Tag" -Headers $ApiHeaders
$zipAsset = $rel.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
$shaAsset = $rel.assets | Where-Object { $_.name -like "*.sha256" } | Select-Object -First 1
if (-not $zipAsset) { throw "release $Tag has no .zip asset." }
if (-not $shaAsset) { throw "release $Tag has no .sha256 asset." }

$zipPath = Join-Path $Dest $zipAsset.name
$shaPath = Join-Path $Dest $shaAsset.name
Write-Host "Downloading $($zipAsset.name) ..."
if ($Token) {
    # A release that is not public: assets come through the API by asset URL.
    $dlHeaders = @{ Accept = "application/octet-stream"; Authorization = "Bearer $Token" }
    Invoke-WebRequest -Uri $zipAsset.url -Headers $dlHeaders -OutFile $zipPath
    Invoke-WebRequest -Uri $shaAsset.url -Headers $dlHeaders -OutFile $shaPath
} else {
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zipPath
    Invoke-WebRequest -Uri $shaAsset.browser_download_url -OutFile $shaPath
}

$expected = ((Get-Content $shaPath -TotalCount 1) -split '\s+')[0].ToLower()
$actual = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
if (-not $expected -or $expected -ne $actual) {
    Remove-Item $zipPath -Force
    throw "sha256 mismatch. Expected $expected, got $actual. The download was removed; nothing was installed."
}
Write-Host "sha256 verified."

$unpack = Join-Path $Dest ([IO.Path]::GetFileNameWithoutExtension($zipAsset.name))
if (Test-Path $unpack) { Remove-Item $unpack -Recurse -Force }
Expand-Archive -Path $zipPath -DestinationPath $unpack

$inner = Get-ChildItem -Path $unpack -Directory | Select-Object -First 1
if (-not $inner) { throw "unexpected zip layout." }
$installer = Join-Path $inner.FullName "Install_Heimdall.ps1"
if (-not (Test-Path $installer)) { throw "Install_Heimdall.ps1 not found in the zip." }

$args = @()
if ($VaultPath)    { $args += @("-VaultPath", $VaultPath) }
if ($SkipSoftware) { $args += "-SkipSoftware" }
if ($Unattended)   { $args += "-Unattended" }
if ($NoLaunch)     { $args += "-NoLaunch" }

Write-Host "Starting the installer from $($inner.FullName)"
Write-Host ""
Push-Location $inner.FullName
try { & powershell -NoProfile -ExecutionPolicy Bypass -File $installer @args; $code = $LASTEXITCODE }
finally { Pop-Location }

# Pasted as "irm ... | iex" this runs inside your own PowerShell window, where
# "exit" would close the window and take the installer's last words with it.
# Only a file run (powershell -File get.ps1, as CI does) carries the code out.
if ($MyInvocation.MyCommand.Path) { exit $code }
if ($code -ne 0) { Write-Host "The installer stopped with code $code. install_log.txt beside it says why." }
