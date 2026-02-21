# altered-carbon.ps1 — Bootstrap a fresh Windows developer environment.
# Compatible with Windows PowerShell 5.1+ (the default shell on a fresh install).
#
# Usage:
#   .\altered-carbon.ps1 -Work                                 # work mode (core + work apps)
#   .\altered-carbon.ps1 -Personal                             # personal mode (core + personal apps)
#   .\altered-carbon.ps1 -Work -OmpTheme 'jandedobbeleer'      # different oh-my-posh theme
#   .\altered-carbon.ps1 -Personal -NerdFont 'FiraCode'        # different Nerd Font
#   .\altered-carbon.ps1 -Work -SkipPackages 'Spotify.Spotify' # skip specific packages
#   .\altered-carbon.ps1 -Personal -ExtraPackages @(@{Id='Mozilla.Firefox'; Name='Firefox'})

[CmdletBinding(DefaultParameterSetName = 'None')]
param(
    # Install for work environment (core + work-specific apps).
    [Parameter(Mandatory, ParameterSetName = 'Work')]
    [switch] $Work,

    # Install for personal environment (core + personal-specific apps).
    [Parameter(Mandatory, ParameterSetName = 'Personal')]
    [switch] $Personal,

    # oh-my-posh theme name (without .omp.json extension).
    [string] $OmpTheme = 'night-owl',

    # Nerd Font to install via oh-my-posh and set in Windows Terminal / VS Code.
    [string] $NerdFont = 'CodeNewRoman',

    # winget package IDs to skip from the default list.
    [string[]] $SkipPackages = @(),

    # Additional winget packages to install (array of @{Id='...'; Name='...'} hashtables).
    [hashtable[]] $ExtraPackages = @()
)

# Require -Work or -Personal
if (-not $Work -and -not $Personal) {
    Write-Error 'You must specify either -Work or -Personal mode.'
    exit 1
}

$ErrorActionPreference = 'Stop'

# ── Helper Functions ──────────────────────────────────────────────────────────

function Get-WingetVersionInfo {
    <#
    .SYNOPSIS
        Parses winget output and extracts Version and Available columns using header positions.
    .PARAMETER Lines
        Array of output lines from winget list or winget search command.
    .PARAMETER PackageId
        The exact package ID to find in the output.
    .RETURNS
        Hashtable with Version and Available keys, or $null if not found.
    #>
    param(
        [string[]] $Lines,
        [string] $PackageId
    )

    # Find header line containing column names
    $headerLine = $Lines | Where-Object { $_ -match '^\s*Name\s+' -and $_ -match 'Version' } | Select-Object -First 1
    if (-not $headerLine) { return $null }

    # Find the data line containing the package ID
    $dataLine = $Lines | Where-Object { $_ -match [regex]::Escape($PackageId) } | Select-Object -First 1
    if (-not $dataLine) { return $null }

    # Get column positions from header
    $versionPos = $headerLine.IndexOf('Version')
    $availablePos = $headerLine.IndexOf('Available')
    $sourcePos = $headerLine.IndexOf('Source')

    if ($versionPos -lt 0) { return $null }

    # Extract version (from Version column to Available or Source column)
    $versionEnd = if ($availablePos -gt $versionPos) { $availablePos } elseif ($sourcePos -gt $versionPos) { $sourcePos } else { $dataLine.Length }
    $version = $null
    if ($dataLine.Length -gt $versionPos -and $versionEnd -gt $versionPos) {
        $extractLength = [Math]::Min($versionEnd - $versionPos, $dataLine.Length - $versionPos)
        if ($extractLength -gt 0) {
            $version = $dataLine.Substring($versionPos, $extractLength).Trim()
        }
    }

    # Extract available version if present
    $available = $null
    if ($availablePos -gt 0 -and $dataLine.Length -gt $availablePos) {
        $availableEnd = if ($sourcePos -gt $availablePos) { $sourcePos } else { $dataLine.Length }
        if ($availableEnd -gt $availablePos) {
            $extractLength = [Math]::Min($availableEnd - $availablePos, $dataLine.Length - $availablePos)
            if ($extractLength -gt 0) {
                $available = $dataLine.Substring($availablePos, $extractLength).Trim()
            }
        }
    }

    return @{
        Version   = if ($version) { $version } else { $null }
        Available = if ($available) { $available } else { $null }
    }
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error 'winget is not available. Install "App Installer" from the Microsoft Store first.'
}

# ── Installations ─────────────────────────────────────────────────────────────

# Core packages — installed in both Work and Personal modes
$corePackages = @(
    @{ Id = 'Microsoft.VisualStudioCode';          Name = 'Visual Studio Code';      Source = 'winget' }
    @{ Id = 'Microsoft.VisualStudioCode.Insiders'; Name = 'Visual Studio Code Insiders'; Source = 'winget' }
    @{ Id = 'Microsoft.WindowsTerminal.Preview';   Name = 'Windows Terminal Preview'; Source = 'winget' }
    @{ Id = 'Microsoft.PowerShell';                Name = 'PowerShell 7';            Source = 'winget' }
    @{ Id = 'Microsoft.PowerShell.Preview';        Name = 'PowerShell Preview';      Source = 'winget' }
    @{ Id = 'Git.Git';                             Name = 'git';                     Source = 'winget' }
    @{ Id = 'GitHub.GitHubDesktop';                Name = 'GitHub Desktop';          Source = 'winget' }
    @{ Id = 'GitHub.cli';                          Name = 'GitHub CLI';              Source = 'winget' }
    @{ Id = 'JanDeDobbeleer.OhMyPosh';             Name = 'oh-my-posh';              Source = 'winget' }
    @{ Id = 'Microsoft.PowerToys';                 Name = 'PowerToys';               Source = 'winget' }
    @{ Id = 'Spotify.Spotify';                     Name = 'Spotify';                 Source = 'winget' }
    @{ Id = 'Microsoft.AzureCLI';                  Name = 'Azure CLI (Az CLI)';      Source = 'winget' }
    @{ Id = '7zip.7zip';                           Name = '7zip';                    Source = 'winget' }
    @{ Id = 'WinSCP.WinSCP';                       Name = 'WinSCP';                  Source = 'winget' }
    @{ Id = 'Logitech.GHUB';                       Name = 'Logitech G Hub';          Source = 'winget' }
    @{ Id = 'Logitech.OptionsPlus';                Name = 'Logitech Options+';       Source = 'winget' }
    @{ Id = 'Yealink.YealinkUSBConnect';           Name = 'Yealink USB Connect';     Source = 'winget' }
    @{ Id = 'Elgato.StreamDeck';                   Name = 'Elgato StreamDeck';       Source = 'winget' }
    @{ Id = '9N1F85V9T8BN';                         Name = 'Windows App';             Source = 'msstore' }
)

# Personal-only packages
$personalPackages = @(
    @{ Id = 'Valve.Steam';                                  Name = 'Steam';                  Source = 'winget' }
    @{ Id = 'Discord.Discord';                              Name = 'Discord';                Source = 'winget' }
    @{ Id = 'Blizzard.BattleNet';                           Name = 'Battle.net';             Source = 'winget' }
    @{ Id = 'OpenWhisperSystems.Signal';                    Name = 'Signal';                 Source = 'winget' }
    @{ Id = 'Google.Chrome';                                Name = 'Google Chrome';          Source = 'winget' }
    @{ Id = 'Brave.Brave';                                  Name = 'Brave Browser';          Source = 'winget' }
    @{ Id = 'PrivateInternetAccess.PrivateInternetAccessVPN'; Name = 'PIA VPN Client';         Source = 'winget' }
    @{ Id = 'Anysphere.Cursor';                             Name = 'Cursor IDE';             Source = 'winget' }
    @{ Id = 'LMStudio.LMStudio';                            Name = 'LM Studio';              Source = 'winget' }
    @{ Id = 'Adobe.CreativeCloud';                          Name = 'Adobe Creative Cloud';   Source = 'winget' }
    @{ Id = 'Adobe.Lightroom';                              Name = 'Adobe Lightroom';        Source = 'winget' }
    @{ Id = 'Microsoft.GamingApp';                          Name = 'Xbox';                   Source = 'msstore' }
)

# Build the final package list based on mode
$wingetPackages = $corePackages
if ($Personal) {
    $wingetPackages += $personalPackages
}

# Apply SkipPackages filter and add any extras
if ($SkipPackages.Count -gt 0) {
    $wingetPackages = $wingetPackages | Where-Object { $_.Id -notin $SkipPackages }
}
if ($ExtraPackages.Count -gt 0) {
    $wingetPackages += $ExtraPackages
}

foreach ($pkg in $wingetPackages) {
    Write-Host "Checking $($pkg.Name) ($($pkg.Id))..." -ForegroundColor Cyan

    # Determine source (default to 'winget' if not specified)
    $source = if ($pkg.Source) { $pkg.Source } else { 'winget' }

    # Generic handling for all packages
    $installedVersion = $null
    $availableVersion = $null

    # Get installed version using column-position parsing
    $listLines = winget list --id $pkg.Id --exact --source $source --accept-source-agreements 2>&1 | ForEach-Object { $_.ToString() }
    $versionInfo = Get-WingetVersionInfo -Lines $listLines -PackageId $pkg.Id
    if ($versionInfo) {
        $installedVersion = $versionInfo.Version
        $availableVersion = $versionInfo.Available
    }

    # If no available version in list output, check search output
    $latestVersion = $availableVersion
    if (-not $latestVersion) {
        $searchLines = winget search --id $pkg.Id --exact --source $source --accept-source-agreements 2>&1 | ForEach-Object { $_.ToString() }
        $searchInfo = Get-WingetVersionInfo -Lines $searchLines -PackageId $pkg.Id
        if ($searchInfo -and $searchInfo.Version) {
            $latestVersion = $searchInfo.Version
        }
    }

    if ($installedVersion) {
        if ($latestVersion -and $installedVersion -ne $latestVersion) {
            Write-Host "  Updating $($pkg.Name) from $installedVersion to $latestVersion..." -ForegroundColor Cyan
            winget upgrade --id $pkg.Id --exact --source $source --accept-source-agreements --accept-package-agreements --silent
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Done: $($pkg.Name) updated." -ForegroundColor Green
            } elseif ($LASTEXITCODE -eq -1978335135) {
                Write-Warning "  $($pkg.Name) is currently in use. Close it and re-run the script to update."
            } else {
                Write-Warning "  winget exited with code $LASTEXITCODE updating $($pkg.Name)"
            }
        } else {
            Write-Host "  Skipped: $($pkg.Name) already installed ($installedVersion)." -ForegroundColor Yellow
        }
        continue
    }

    Write-Host "  Installing $($pkg.Name)..." -ForegroundColor Cyan
    winget install --id $pkg.Id --exact --source $source --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Done: $($pkg.Name) installed." -ForegroundColor Green
    } elseif ($LASTEXITCODE -eq -1978335135) {
        Write-Warning "  $($pkg.Name) installer reports the app is in use. Close it and re-run to complete installation."
    } else {
        Write-Warning "  winget exited with code $LASTEXITCODE for $($pkg.Name)"
    }
}

# ── Windows Features ──────────────────────────────────────────────────────────
# Enable Hyper-V and WSL 2 (both modes). Requires admin privileges.

Write-Host 'Enabling Windows features (Hyper-V and WSL 2)...' -ForegroundColor Cyan

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    # Enable Hyper-V
    $hypervState = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
    if ($hypervState -and $hypervState.State -eq 'Enabled') {
        Write-Host '  Skipped: Hyper-V already enabled.' -ForegroundColor Yellow
    } else {
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart -ErrorAction Stop | Out-Null
            Write-Host '  Done: Hyper-V enabled (reboot required).' -ForegroundColor Green
        } catch {
            Write-Warning "  Failed to enable Hyper-V: $_"
        }
    }

    # Enable WSL 2
    $wslState = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
    $vmPlatformState = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
    
    if ($wslState -and $wslState.State -eq 'Enabled' -and $vmPlatformState -and $vmPlatformState.State -eq 'Enabled') {
        Write-Host '  Skipped: WSL 2 features already enabled.' -ForegroundColor Yellow
    } else {
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -All -NoRestart -ErrorAction Stop | Out-Null
            Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop | Out-Null
            Write-Host '  Done: WSL 2 features enabled (reboot required). Run "wsl --install" after reboot to complete setup.' -ForegroundColor Green
        } catch {
            Write-Warning "  Failed to enable WSL 2: $_"
        }
    }
} else {
    Write-Warning '  Skipped: Hyper-V and WSL 2 require admin privileges. Re-run script as Administrator to enable.'
}

# ── Nvidia App (if Nvidia GPU present) ────────────────────────────────────────

Write-Host 'Checking for Nvidia GPU...' -ForegroundColor Cyan

$nvidiaGpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'NVIDIA' }

if ($nvidiaGpu) {
    Write-Host "  Detected: $($nvidiaGpu.Name)" -ForegroundColor Green
    Write-Host '  Installing Nvidia App...' -ForegroundColor Cyan
    
    $nvidiaInstalled = winget list --id 'Nvidia.NvidiaApp' --exact --source winget --accept-source-agreements 2>&1 | Select-String 'Nvidia.NvidiaApp'
    if ($nvidiaInstalled) {
        Write-Host '  Skipped: Nvidia App already installed.' -ForegroundColor Yellow
    } else {
        winget install --id 'Nvidia.NvidiaApp' --exact --source winget --accept-source-agreements --accept-package-agreements --silent
        if ($LASTEXITCODE -eq 0) {
            Write-Host '  Done: Nvidia App installed.' -ForegroundColor Green
        } elseif ($LASTEXITCODE -eq -1978335135) {
            Write-Warning '  Nvidia App installer reports the app is in use. Close it and re-run to complete installation.'
        } else {
            Write-Warning "  winget exited with code $LASTEXITCODE for Nvidia App"
        }
    }
} else {
    Write-Host '  Skipped: No Nvidia GPU detected.' -ForegroundColor Yellow
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

# ── PowerShell Modules ─────────────────────────────────────────────────────────
# Install commonly used modules into CurrentUser scope (no admin required).

$psModules = @(
    # Core
    @{ Name = 'Microsoft.Graph';           Description = 'Microsoft Graph' }
    @{ Name = 'Az';                        Description = 'Azure PowerShell' }
    @{ Name = 'ExchangeOnlineManagement';  Description = 'Exchange Online Management' }
    @{ Name = 'MicrosoftTeams';            Description = 'Microsoft Teams' }
    @{ Name = 'PnP.PowerShell';            Description = 'PnP PowerShell (SharePoint / M365)' }
    @{ Name = 'MicrosoftPowerBIMgmt';      Description = 'Power BI Management' }
    @{ Name = 'Microsoft365DSC';           Description = 'Microsoft 365 DSC' }
    @{ Name = 'ActiveDirectory';           Description = 'Active Directory' }
    @{ Name = 'Microsoft.Graph.Intune';    Description = 'Microsoft Graph Intune' }
)

foreach ($mod in $psModules) {
    Write-Host "Installing module $($mod.Description) ($($mod.Name))..." -ForegroundColor Cyan
    if (Get-Module -ListAvailable -Name $mod.Name -ErrorAction SilentlyContinue) {
        Write-Host "  Skipped: $($mod.Name) already installed." -ForegroundColor Yellow
    }
    else {
        try {
            Install-Module -Name $mod.Name -Scope CurrentUser -Force -AllowClobber -AcceptLicense -ErrorAction Stop
            Write-Host "  Done: $($mod.Name)" -ForegroundColor Green
        }
        catch {
            Write-Warning "  Failed to install $($mod.Name): $_"
        }
    }
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

$ompLine = "oh-my-posh init pwsh --config `"`$env:POSH_THEMES_PATH\$OmpTheme.omp.json`" | Invoke-Expression"

if (Test-Path $ps7ProfilePath) {
    $profileContent = Get-Content $ps7ProfilePath -Raw
    # Check if oh-my-posh init line already exists (exact match or similar pattern)
    if ($profileContent -notmatch 'oh-my-posh\s+init\s+pwsh') {
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

Write-Host "`nSetup complete. Some changes (default terminal delegation) require you to log out and back in for Windows to apply them." -ForegroundColor Green
Write-Host "If you do not log out, Windows Terminal may be unable to launch until you do." -ForegroundColor Yellow
Write-Host "Would you like to log out now? (Y/n) [Default: Y]" -ForegroundColor Cyan
$logoutPrompt = Read-Host
if ($logoutPrompt -eq '' -or $logoutPrompt -match '^(Y|y)$') {
    Write-Host 'Logging out...' -ForegroundColor Yellow
    shutdown.exe /l
} else {
    Write-Host 'Logout skipped. Please log out manually to apply terminal changes.' -ForegroundColor Yellow
}

# 5. Configure File Explorer options
Write-Host 'Configuring File Explorer options...' -ForegroundColor Cyan
try {
    # Show file extensions
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -Value 0
    # Show hidden files
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Hidden' -Value 1
    # Show system files
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowSuperHidden' -Value 1
    # Show full path in title bar
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' -Name 'FullPath' -Value 1
    # Show "Run as different user" in Start (requires Group Policy or registry tweak)
    $runAsKey = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
    $runAsName = 'ShowRunAsDifferentUserInStart'
    try {
        Set-ItemProperty -Path $runAsKey -Name $runAsName -Value 1 -Force
    } catch {
        Write-Warning "  Could not enable 'Run as different user' in Start menu. This setting may require admin rights or Group Policy access."
        Write-Host "  To enable manually, open Group Policy Editor (gpedit.msc) and go to: User Configuration > Administrative Templates > Start Menu and Taskbar > Show 'Run as different user' command on Start. Or, open System Settings: " -ForegroundColor Yellow
        Write-Host "  ms-settings:personalization-start" -ForegroundColor Cyan
        Write-Host "  (Copy and paste the above URI into the Run dialog [Win+R] or a browser address bar.)" -ForegroundColor Yellow
    }
    Write-Host '  Done: File Explorer options configured.' -ForegroundColor Green
} catch {
    Write-Warning "  Failed to configure File Explorer options: $_"
}
