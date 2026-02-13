# altered-carbon.ps1 — Bootstrap a fresh Windows developer environment.
# Compatible with Windows PowerShell 5.1+ (the default shell on a fresh install).
#
# Usage:
#   .\altered-carbon.ps1                                       # run with defaults
#   .\altered-carbon.ps1 -OmpTheme 'jandedobbeleer'            # different oh-my-posh theme
#   .\altered-carbon.ps1 -NerdFont 'FiraCode'                  # different Nerd Font
#   .\altered-carbon.ps1 -SkipPackages 'Spotify.Spotify'       # skip specific packages
#   .\altered-carbon.ps1 -ExtraPackages @(@{Id='Mozilla.Firefox'; Name='Firefox'})  # add packages

param(
    # oh-my-posh theme name (without .omp.json extension).
    [string] $OmpTheme = 'night-owl',

    # Nerd Font to install via oh-my-posh and set in Windows Terminal / VS Code.
    [string] $NerdFont = 'CodeNewRoman',

    # winget package IDs to skip from the default list.
    [string[]] $SkipPackages = @(),

    # Additional winget packages to install (array of @{Id='...'; Name='...'} hashtables).
    [hashtable[]] $ExtraPackages = @()
)

$ErrorActionPreference = 'Stop'

# ── Pre-flight ────────────────────────────────────────────────────────────────

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error 'winget is not available. Install "App Installer" from the Microsoft Store first.'
}

# ── Installations ─────────────────────────────────────────────────────────────

$wingetPackages = @(
    @{ Id = 'Microsoft.VisualStudioCode';          Name = 'Visual Studio Code' }
    @{ Id = 'Microsoft.VisualStudioCode.Insiders'; Name = 'Visual Studio Code Insiders' }
    @{ Id = 'Microsoft.WindowsTerminal.Preview';   Name = 'Windows Terminal Preview' }
    @{ Id = 'Microsoft.PowerShell';                Name = 'PowerShell 7' }
    @{ Id = 'Microsoft.PowerShell.Preview';        Name = 'PowerShell Preview' }
    @{ Id = 'Git.Git';                             Name = 'git' }
    @{ Id = 'GitHub.GitHubDesktop';                Name = 'GitHub Desktop' }
    @{ Id = 'GitHub.cli';                          Name = 'GitHub CLI' }
    @{ Id = 'JanDeDobbeleer.OhMyPosh';             Name = 'oh-my-posh' }
    @{ Id = 'Microsoft.PowerToys';                 Name = 'PowerToys' }
    @{ Id = 'Spotify.Spotify';                     Name = 'Spotify' }
)

# Apply SkipPackages filter and add any extras
if ($SkipPackages.Count -gt 0) {
    $wingetPackages = $wingetPackages | Where-Object { $_.Id -notin $SkipPackages }
}
if ($ExtraPackages.Count -gt 0) {
    $wingetPackages += $ExtraPackages
}

foreach ($pkg in $wingetPackages) {
    Write-Host "Installing $($pkg.Name) ($($pkg.Id))..." -ForegroundColor Cyan
    winget install --id $pkg.Id --exact --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Done: $($pkg.Name)" -ForegroundColor Green
    }
    else {
        Write-Warning "  winget exited with code $LASTEXITCODE for $($pkg.Name) (may already be installed)"
    }
}

# Refresh PATH so newly installed tools (oh-my-posh, git, etc.) are available
# in this session without restarting the terminal.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

# ── NerdFont: Code New Roman ─────────────────────────────────────────────────
# oh-my-posh ships a CLI to install Nerd Fonts from the official releases
# (https://github.com/ryanoasis/nerd-fonts). Installs per-user, no admin needed.

Write-Host "Installing NerdFont $NerdFont..." -ForegroundColor Cyan
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    oh-my-posh font install $NerdFont
    Write-Host "  Done: $NerdFont Nerd Font" -ForegroundColor Green
}
else {
    Write-Warning '  oh-my-posh not found on PATH after install. Install the font manually.'
}

# ── Configuration ─────────────────────────────────────────────────────────────

# 1. oh-my-posh night-owl theme in the PowerShell 7 profile
#    We build the PS 7 profile path explicitly because this script may be
#    running under Windows PowerShell 5.1 where $PROFILE points elsewhere.
Write-Host "Configuring oh-my-posh $OmpTheme theme..." -ForegroundColor Cyan

$documentsPath  = [Environment]::GetFolderPath('MyDocuments')
$ps7ProfilePath = Join-Path $documentsPath 'PowerShell\Microsoft.PowerShell_profile.ps1'
$ps7ProfileDir  = Split-Path $ps7ProfilePath -Parent

if (-not (Test-Path $ps7ProfileDir)) {
    New-Item -ItemType Directory -Path $ps7ProfileDir -Force | Out-Null
}

$ompLine = "oh-my-posh init pwsh --config `"\`$env:POSH_THEMES_PATH\$OmpTheme.omp.json`" | Invoke-Expression"

if (Test-Path $ps7ProfilePath) {
    $profileContent = Get-Content $ps7ProfilePath -Raw
    if ($profileContent -notmatch 'oh-my-posh init') {
        Add-Content -Path $ps7ProfilePath -Value "`n$ompLine"
        Write-Host '  Done: oh-my-posh line appended to profile.' -ForegroundColor Green
    }
    else {
        Write-Host '  Skipped: oh-my-posh already configured.' -ForegroundColor Yellow
    }
}
else {
    Set-Content -Path $ps7ProfilePath -Value $ompLine
    Write-Host '  Done: PS 7 profile created with oh-my-posh config.' -ForegroundColor Green
}

# 2. Windows Terminal Preview — default profile + font
Write-Host 'Configuring Windows Terminal Preview...' -ForegroundColor Cyan

$wtPackageDir = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter 'Microsoft.WindowsTerminalPreview_*' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName

if ($wtPackageDir) {
    $wtLocalState   = Join-Path $wtPackageDir 'LocalState'
    $wtSettingsPath = Join-Path $wtLocalState 'settings.json'

    if (-not (Test-Path $wtLocalState)) {
        New-Item -ItemType Directory -Path $wtLocalState -Force | Out-Null
    }

    if (Test-Path $wtSettingsPath) {
        $wt = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json
    }
    else {
        # Minimal settings — WT merges with its built-in defaults on launch.
        $wt = [PSCustomObject]@{
            '$help'   = 'https://aka.ms/terminal-documentation'
            '$schema' = 'https://aka.ms/terminal-profiles-schema'
            profiles  = [PSCustomObject]@{
                defaults = [PSCustomObject]@{}
            }
        }
    }

    # Default profile → PowerShell Preview
    $pwshPreviewGuid = '{2595cd9c-8f05-55ff-a1d4-93f3041ca67f}'
    if ($wt.PSObject.Properties['defaultProfile']) {
        $wt.defaultProfile = $pwshPreviewGuid
    }
    else {
        $wt | Add-Member -NotePropertyName 'defaultProfile' -NotePropertyValue $pwshPreviewGuid -Force
    }

    # Font → selected Nerd Font for all profiles
    if (-not $wt.profiles) {
        $wt | Add-Member -NotePropertyName 'profiles' -NotePropertyValue ([PSCustomObject]@{ defaults = [PSCustomObject]@{} }) -Force
    }
    if (-not $wt.profiles.defaults) {
        $wt.profiles | Add-Member -NotePropertyName 'defaults' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $fontObj = [PSCustomObject]@{ face = "$NerdFont Nerd Font" }
    if ($wt.profiles.defaults.PSObject.Properties['font']) {
        $wt.profiles.defaults.font = $fontObj
    }
    else {
        $wt.profiles.defaults | Add-Member -NotePropertyName 'font' -NotePropertyValue $fontObj -Force
    }

    $wt | ConvertTo-Json -Depth 10 | Set-Content $wtSettingsPath -Encoding UTF8
    Write-Host "  Done: $wtSettingsPath" -ForegroundColor Green
}
else {
    Write-Warning '  Windows Terminal Preview package folder not found. Launch it once, then re-run this script.'
}

# 3. Set Windows Terminal Preview as the default terminal (Windows 11)
Write-Host 'Setting Windows Terminal Preview as default terminal...' -ForegroundColor Cyan
$regPath = 'HKCU:\Console\%%Startup'
try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    # COM class IDs for Windows Terminal Preview delegation
    Set-ItemProperty -Path $regPath -Name 'DelegationConsole'  -Value '{06171993-2EB2-4CB9-8A6E-492235E1EAFC}'
    Set-ItemProperty -Path $regPath -Name 'DelegationTerminal' -Value '{86633F1F-6C40-4FA7-B9A0-E7E6D27C4B72}'
    Write-Host '  Done: default terminal set.' -ForegroundColor Green
}
catch {
    Write-Warning "  Failed to set default terminal: $_"
}

# 4. VS Code & VS Code Insiders — CodeNewRoman Nerd Font Mono
Write-Host 'Configuring VS Code editor font...' -ForegroundColor Cyan

$vsCodeSettingsPaths = @(
    (Join-Path $env:APPDATA 'Code\User\settings.json'),
    (Join-Path $env:APPDATA 'Code - Insiders\User\settings.json')
)

foreach ($settingsPath in $vsCodeSettingsPaths) {
    $label = if ($settingsPath -match 'Insiders') { 'VS Code Insiders' } else { 'VS Code' }

    if (Test-Path $settingsPath) {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    }
    else {
        $settingsDir = Split-Path $settingsPath -Parent
        if (-not (Test-Path $settingsDir)) {
            New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        }
        $settings = [PSCustomObject]@{}
    }

    $fontValue = "'$NerdFont Nerd Font Mono', Consolas, 'Courier New', monospace"
    if ($settings.PSObject.Properties['editor.fontFamily']) {
        $settings.'editor.fontFamily' = $fontValue
    }
    else {
        $settings | Add-Member -NotePropertyName 'editor.fontFamily' -NotePropertyValue $fontValue -Force
    }

    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
    Write-Host "  Done: $label font configured." -ForegroundColor Green
}

Write-Host "`nSetup complete. Restart your terminal to apply all changes." -ForegroundColor Green
