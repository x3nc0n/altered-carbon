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

    # Nerd Font to install and set in Windows Terminal / VS Code.
    [string] $NerdFont = 'CodeNewRoman',

    # winget package IDs to skip from the default list.
    [string[]] $SkipPackages = @(),

    # Additional winget packages to install (array of @{Id='...'; Name='...'} hashtables).
    [hashtable[]] $ExtraPackages = @()
)

$ErrorActionPreference = 'Stop'

# ── Admin Check ────────────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

function Get-WingetVersionInfo {
    [CmdletBinding()]
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

function Invoke-ElevatedFontPromotion {
    # Write a small helper script to a temp file and run it elevated so that
    # per-user Nerd Font files are copied to the system Fonts directory and
    # registered in HKLM, making them visible to Windows Terminal (UWP).
    # Uses a temp file to avoid newline-in-argument issues on Windows when
    # passing multi-line scripts to pwsh -Command.
    [CmdletBinding()]
    param(
        # The regex pattern (already single-quote–escaped) that identifies the
        # target font entries in the Windows font registry.
        [string] $NfPattern
    )

    $tmpScript = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -Path $tmpScript -Encoding UTF8 -Value (
        '$hkcuReg = ''HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts''' + "`r`n" +
        '$hklmReg = ''HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts''' + "`r`n" +
        '$entries = (Get-ItemProperty $hkcuReg).PSObject.Properties | Where-Object { $_.Name -match ''Nerd Font'' -and $_.Name -match ''' + $NfPattern + ''' }' + "`r`n" +
        'foreach ($e in $entries) {' + "`r`n" +
        '    $srcFile = $e.Value' + "`r`n" +
        '    $destName = Split-Path $srcFile -Leaf' + "`r`n" +
        '    Copy-Item $srcFile (Join-Path $env:SystemRoot ''Fonts'' $destName) -Force -ErrorAction SilentlyContinue' + "`r`n" +
        '    Set-ItemProperty -Path $hklmReg -Name $e.Name -Value $destName -Force' + "`r`n" +
        '}'
    )
    try {
        Start-Process pwsh -ArgumentList "-NoProfile -File `"$tmpScript`"" -Verb RunAs -Wait -ErrorAction Stop
        Write-Host '  Done: fonts promoted to system-wide.' -ForegroundColor Green
    } catch {
        Write-Warning '  Could not elevate to promote fonts. Windows Terminal may not see per-user fonts.'
        Write-Host '  Re-run this script as Administrator to fix this.' -ForegroundColor Yellow
    } finally {
        Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
    }
}

# ── Custom PSModulePath Setup ───────────────────────────────────────────────
# Create a hidden .psmodule folder in the user's profile and set PSModulePath to it
$psModuleDir = Join-Path $env:USERPROFILE '.psmodule'
if (-not (Test-Path $psModuleDir)) {
    New-Item -Path $psModuleDir -ItemType Directory | Out-Null
    # Set hidden attribute
    (Get-Item $psModuleDir).Attributes += 'Hidden'
    Write-Host "Created hidden module folder: $psModuleDir" -ForegroundColor Green
} else {
    Write-Host ".psmodule folder already exists: $psModuleDir" -ForegroundColor Yellow
}

# Prepend the custom module folder to PSModulePath (keep system paths so built-in modules like PowerShellGet still load)
if ($env:PSModulePath -notlike "*$psModuleDir*") {
    $env:PSModulePath = "$psModuleDir;$env:PSModulePath"
}
# Persist only the custom folder as the User-level PSModulePath; machine/process
# paths are inherited automatically by new sessions.
[System.Environment]::SetEnvironmentVariable('PSModulePath', $psModuleDir, 'User')
Write-Host "PSModulePath includes $psModuleDir (user environment)" -ForegroundColor Cyan

# ── Custom PowerShell Profile Directory ─────────────────────────────────────
# Create a hidden .psprofile folder in the user's profile directory so the
# real PowerShell profile lives outside the OneDrive-synced Documents folder.
# A tiny stub at the default $PROFILE location dot-sources the real file.
$psProfileDir = Join-Path $env:USERPROFILE '.psprofile'
if (-not (Test-Path $psProfileDir)) {
    New-Item -Path $psProfileDir -ItemType Directory | Out-Null
    (Get-Item $psProfileDir).Attributes += 'Hidden'
    Write-Host "Created hidden profile folder: $psProfileDir" -ForegroundColor Green
} else {
    Write-Host ".psprofile folder already exists: $psProfileDir" -ForegroundColor Yellow
}

# The actual profile file that will hold all config (oh-my-posh, etc.)
$psProfileFile = Join-Path $psProfileDir 'profile.ps1'

# ── Pre-flight ────────────────────────────────────────────────────────────────

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error 'winget is not available. Install "App Installer" from the Microsoft Store first.'
}

# ── Chocolatey ────────────────────────────────────────────────────────────────
# Chocolatey provides more reliable PATH handling and version management for
# developer tools like git. Used alongside winget, not as a full replacement.

Write-Host 'Bootstrapping Chocolatey...' -ForegroundColor Cyan

if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Host '  Skipped: Chocolatey already installed.' -ForegroundColor Yellow
} elseif ($isAdmin) {
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        # Refresh PATH so choco is available immediately
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path', 'User')
        Write-Host '  Done: Chocolatey installed.' -ForegroundColor Green
    }
    catch {
        Write-Warning "  Failed to install Chocolatey: $_"
    }
} else {
    Write-Warning '  Chocolatey requires admin privileges. Re-run script as Administrator to install.'
}

# ── Chocolatey Packages ──────────────────────────────────────────────────────
# Git benefits most from Chocolatey: it's immediately on PATH with Git
# Credential Manager and no session restart is needed.


# Command is the expected binary name — used to verify the install is healthy.
$chocoPackages = @(
    @{ Id = 'git';        Name = 'git';           Command = 'git' }
    @{ Id = 'nodejs-lts'; Name = 'Node.js (LTS)'; Command = 'node' }
)

if (Get-Command choco -ErrorAction SilentlyContinue) {
    foreach ($pkg in $chocoPackages) {
        Write-Host "Checking $($pkg.Name) ($($pkg.Id)) [choco]..." -ForegroundColor Cyan

        $chocoList = choco list --exact $pkg.Id --limit-output 2>&1
        if ($chocoList -match [regex]::Escape($pkg.Id)) {
            # Verify the binary actually exists — winget uninstall can remove
            # files that Chocolatey installed, leaving stale choco metadata.
            $cmdInfo = if ($pkg.Command) { Get-Command $pkg.Command -ErrorAction SilentlyContinue } else { $null }
            $isHealthy = (-not $pkg.Command) -or (
                $cmdInfo -and $cmdInfo.Source -notmatch 'Microsoft\\WindowsApps'
            )
            if ($isHealthy -and $isAdmin) {
                Write-Host "  Upgrading $($pkg.Name) via Chocolatey (no-op if already latest)..." -ForegroundColor Cyan
                choco upgrade $pkg.Id -y --no-progress
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Done: $($pkg.Name) is up to date." -ForegroundColor Green
                } else {
                    Write-Warning "  choco exited with code $LASTEXITCODE upgrading $($pkg.Name)"
                }
            } elseif ($isHealthy) {
                Write-Host "  Skipped: $($pkg.Name) already installed via Chocolatey (run as admin to upgrade)." -ForegroundColor Yellow
            } elseif ($isAdmin) {
                Write-Host "  $($pkg.Name) metadata found but binary missing or shadowed. Reinstalling..." -ForegroundColor Cyan
                choco install $pkg.Id -y --force --no-progress
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Done: $($pkg.Name) reinstalled via Chocolatey." -ForegroundColor Green
                } else {
                    Write-Warning "  choco exited with code $LASTEXITCODE reinstalling $($pkg.Name)"
                }
            } else {
                Write-Host "  $($pkg.Name) choco install is broken (binary missing). Will fall back to winget. Re-run as admin to repair." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Installing $($pkg.Name) via Chocolatey..." -ForegroundColor Cyan
            choco install $pkg.Id -y --no-progress
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Done: $($pkg.Name) installed via Chocolatey." -ForegroundColor Green
            } else {
                Write-Warning "  choco exited with code $LASTEXITCODE for $($pkg.Name)"
            }
        }
    }

    # Refresh PATH after Chocolatey installs
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')

    # Skip git in winget — Chocolatey already handled it
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $SkipPackages += 'Git.Git'
    }
} else {
    Write-Host 'Chocolatey not available — git will be installed via winget as fallback.' -ForegroundColor Yellow
}

# ── Installations ─────────────────────────────────────────────────────────────

# Core packages — installed in both Work and Personal modes.
# git is installed via Chocolatey above when available; it remains here as a
# winget fallback and is auto-skipped when choco handled it.
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
    @{ Id = '9P0PQ8B65N8X';                         Name = 'WinSCP';                  Source = 'msstore' }
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

    # Fallback: some packages (e.g. Spotify) install as MSIX with a different ID.
    # If the exact-ID check found nothing, try a name-based lookup.
    if (-not $installedVersion) {
        $nameLines = winget list --name $pkg.Name --accept-source-agreements 2>&1 | ForEach-Object { $_.ToString() }
        $nameHeader = $nameLines | Where-Object { $_ -match '^\s*Name\s+' -and $_ -match 'Version' } | Select-Object -First 1
        if ($nameHeader) {
            # At least one installed entry matched by name — treat as installed.
            $installedVersion = 'detected'
        }
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
            } elseif ($LASTEXITCODE -eq $WINGET_APP_IN_USE) {
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
    } elseif ($LASTEXITCODE -eq $WINGET_APP_IN_USE) {
        Write-Warning "  $($pkg.Name) installer reports the app is in use. Close it and re-run to complete installation."
    } else {
        Write-Warning "  winget exited with code $LASTEXITCODE for $($pkg.Name)"
    }
}

# ── Windows Features ──────────────────────────────────────────────────────────
# Enable Hyper-V and WSL 2 (both modes). Requires admin privileges.

Write-Host 'Enabling Windows features (Hyper-V and WSL 2)...' -ForegroundColor Cyan

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
        } elseif ($LASTEXITCODE -eq $WINGET_APP_IN_USE) {
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

# ── Nerd Font ────────────────────────────────────────────────────────────────
# oh-my-posh ships a CLI to install Nerd Fonts from the official nerd-fonts releases.
# NOTE: Per-user font installs (--user) are NOT visible to Windows Terminal
# (a packaged/UWP app). We always install system-wide first — if that fails
# (non-admin), we fall back to --user and then promote the per-user fonts to
# system scope via an elevated helper so WT can see them.

Write-Host "Installing Nerd Font '$NerdFont'..." -ForegroundColor Cyan

if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    # Check font registry to see if already installed (prefer HKLM for WT compat).
    $nfPattern = '(' + [regex]::Escape($NerdFont) + '|' + ($NerdFont -creplace '([a-z])([A-Z])', '$1\s*$2') + ')'
    $nfPatternEscaped = $nfPattern -replace "'", "''"
    $fontInstalledScope = $null   # 'Machine' or 'User' or $null
    foreach ($scope in @(
        @{ Key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'; Scope = 'Machine' },
        @{ Key = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'; Scope = 'User' }
    )) {
        if (Test-Path $scope.Key) {
            $match = (Get-ItemProperty -Path $scope.Key).PSObject.Properties |
                Where-Object { $_.Name -match 'Nerd Font' -and $_.Name -match $nfPattern }
            if ($match) { $fontInstalledScope = $scope.Scope; break }
        }
    }

    if ($fontInstalledScope -eq 'Machine') {
        Write-Host "  Skipped: $NerdFont Nerd Font already installed system-wide." -ForegroundColor Yellow
    } elseif ($fontInstalledScope -eq 'User') {
        Write-Host "  $NerdFont Nerd Font installed per-user — promoting to system-wide for Windows Terminal compatibility..." -ForegroundColor Cyan
        # Promote per-user fonts to system scope via elevation
        Invoke-ElevatedFontPromotion -NfPattern $nfPatternEscaped
    } else {
        # Not installed — install system-wide if admin, per-user + promote otherwise
        if ($isAdmin) {
            & oh-my-posh font install $NerdFont
        } else {
            & oh-my-posh font install $NerdFont --user
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Done: $NerdFont Nerd Font installed." -ForegroundColor Green

            if (-not $isAdmin) {
                # Promote the per-user install to system scope
                Write-Host "  Promoting per-user fonts to system-wide for Windows Terminal..." -ForegroundColor Cyan
                Invoke-ElevatedFontPromotion -NfPattern $nfPatternEscaped
            }
        } else {
            Write-Warning "  oh-my-posh font install exited with code $LASTEXITCODE for $NerdFont"
        }
    }

    # Resolve the actual font face name from the registry so Windows Terminal
    # and VS Code settings use the exact family name.
    $fontFace     = $null
    $fontFaceMono = $null
    foreach ($fontReg in @(
        'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    )) {
        if (-not (Test-Path $fontReg)) { continue }
        $entries = (Get-ItemProperty -Path $fontReg).PSObject.Properties |
            Where-Object { $_.Name -match 'Nerd Font' -and $_.Name -match $nfPattern }
        if ($entries) {
            $baseEntry = $entries |
                Where-Object { $_.Name -notmatch 'Nerd Font (Mono|Propo)' -and $_.Name -match 'Regular' } |
                Select-Object -First 1
            if ($baseEntry) {
                $fontFace = ($baseEntry.Name -replace '\s*(Regular|Bold|Italic|BoldItalic|Light|Medium|Thin|ExtraLight|SemiBold|ExtraBold|Black)\b.*$', '').Trim()
            }
            $monoEntry = $entries |
                Where-Object { $_.Name -match 'Nerd Font Mono' -and $_.Name -match 'Regular' } |
                Select-Object -First 1
            if ($monoEntry) {
                $fontFaceMono = ($monoEntry.Name -replace '\s*(Regular|Bold|Italic|BoldItalic|Light|Medium|Thin|ExtraLight|SemiBold|ExtraBold|Black)\b.*$', '').Trim()
            }
            if ($fontFace) { break }
        }
    }
} else {
    Write-Warning '  oh-my-posh not found on PATH. Nerd Font installation skipped.'
}

# Fallback font names if registry lookup didn't resolve them.
if (-not $fontFace)     { $fontFace     = "$NerdFont Nerd Font" }
if (-not $fontFaceMono) { $fontFaceMono = "$fontFace Mono" }
Write-Host "  Resolved font face: $fontFace | Mono: $fontFaceMono" -ForegroundColor Cyan

# ── PSGallery Trust ────────────────────────────────────────────────────────────
# Ensure PSGallery is registered and trusted so module installs don't prompt.

Write-Host 'Ensuring PSGallery is a trusted repository...' -ForegroundColor Cyan
$psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
if (-not $psGallery) {
    Register-PSRepository -Default -ErrorAction SilentlyContinue
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Write-Host '  Done: PSGallery registered and trusted.' -ForegroundColor Green
} elseif ($psGallery.InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Write-Host '  Done: PSGallery set to Trusted.' -ForegroundColor Green
} else {
    Write-Host '  Skipped: PSGallery already trusted.' -ForegroundColor Yellow
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
    # Sentinel / Security
    @{ Name = 'AzSentinel';                Description = 'Azure Sentinel (community)' }
    @{ Name = 'MSAL.PS';                   Description = 'MSAL.PS (token acquisition)' }
    @{ Name = 'PSKusto';                   Description = 'PSKusto (KQL from PowerShell)' }
)

foreach ($mod in $psModules) {
    Write-Host "Installing module $($mod.Description) ($($mod.Name))..." -ForegroundColor Cyan
    if (Get-Module -ListAvailable -Name $mod.Name -ErrorAction SilentlyContinue) {
        Write-Host "  Skipped: $($mod.Name) already installed." -ForegroundColor Yellow
    }
    else {
        try {
            # Use Save-Module to install directly into the custom .psmodule folder
            # instead of Install-Module -Scope CurrentUser, which always targets
            # the Documents folder (often synced via OneDrive).
            Save-Module -Name $mod.Name -Path $psModuleDir -Force -AcceptLicense -ErrorAction Stop
            Write-Host "  Done: $($mod.Name)" -ForegroundColor Green
        }
        catch {
            Write-Warning "  Failed to install $($mod.Name): $_"
        }
    }
}

# ── VS Code Extensions ─────────────────────────────────────────────────────────
# Install useful extensions into both VS Code and VS Code Insiders.

$vsCodeExtensions = @(
    @{ Id = 'ms-azuretools.vscode-azureresourcegroups'; Name = 'Azure Resources' }
    @{ Id = 'ms-azuretools.vscode-bicep';               Name = 'Bicep' }
    @{ Id = 'GitHub.copilot';                           Name = 'GitHub Copilot' }
    @{ Id = 'ms-sentinel.azure-sentinel-tools';         Name = 'Microsoft Sentinel KQL' }
)

foreach ($editor in @('code', 'code-insiders')) {
    if (-not (Get-Command $editor -ErrorAction SilentlyContinue)) {
        Write-Host "Skipping $editor extensions ($editor not found on PATH)." -ForegroundColor Yellow
        continue
    }

    Write-Host "Installing VS Code extensions ($editor)..." -ForegroundColor Cyan
    $installedExts = & $editor --list-extensions 2>$null

    foreach ($ext in $vsCodeExtensions) {
        if ($installedExts -contains $ext.Id) {
            Write-Host "  Skipped: $($ext.Name) already installed." -ForegroundColor Yellow
        } else {
            Write-Host "  Installing $($ext.Name)..." -ForegroundColor Cyan
            & $editor --install-extension $ext.Id --force 2>&1 | Out-Null
            Write-Host "  Done: $($ext.Name)" -ForegroundColor Green
        }
    }
}

# ── Configuration ─────────────────────────────────────────────────────────────

# Migrate from the deprecated oh-my-posh PowerShell module (if still present).
# Per the oh-my-posh migration guide: https://ohmyposh.dev/docs/migrating
Write-Host 'Checking for deprecated oh-my-posh PowerShell module...' -ForegroundColor Cyan
if (Get-Module -ListAvailable -Name 'oh-my-posh' -ErrorAction SilentlyContinue) {
    Write-Host '  Removing deprecated oh-my-posh PowerShell module...' -ForegroundColor Cyan
    try {
        if ($env:POSH_PATH -and (Test-Path $env:POSH_PATH)) {
            try {
                Remove-Item $env:POSH_PATH -Force -Recurse -ErrorAction Stop
                Write-Host "  Done: removed cached module files from `$env:POSH_PATH." -ForegroundColor Green
            } catch {
                Write-Warning "  Could not remove `$env:POSH_PATH: $_"
            }
        }
        Uninstall-Module oh-my-posh -AllVersions -Force -ErrorAction Stop
        Write-Host '  Done: oh-my-posh PowerShell module uninstalled.' -ForegroundColor Green
    } catch {
        Write-Warning "  Could not fully remove oh-my-posh module: $_"
    }
} else {
    Write-Host '  Skipped: deprecated module not found.' -ForegroundColor Yellow
}

# 1. oh-my-posh theme — PowerShell 7 / Preview profile
#    The real profile lives in $env:USERPROFILE\.psprofile\profile.ps1 to
#    avoid OneDrive syncing. A stub at the default $PROFILE dot-sources it.
Write-Host "Configuring oh-my-posh $OmpTheme theme..." -ForegroundColor Cyan

# winget installs oh-my-posh as a standalone executable and sets POSH_THEMES_PATH.
# The profile block resolves the themes directory at runtime in case the
# environment variable isn't populated yet in the current session.
$ompBlock = ('
# ── oh-my-posh (managed by altered-carbon) ───────────────────────────────────
if (-not $env:POSH_THEMES_PATH) {
    $_themeCandidates = @(
        (Join-Path $env:LOCALAPPDATA ''Programs\oh-my-posh\themes'')
    )
    # Derive themes dir from the oh-my-posh binary location as final fallback.
    $_ompCmd = Get-Command oh-my-posh -ErrorAction SilentlyContinue
    if ($_ompCmd) {
        $_themeCandidates += Join-Path (Split-Path (Split-Path $_ompCmd.Source)) ''themes''
    }
    foreach ($_dir in $_themeCandidates) {
        if ($_dir -and (Test-Path $_dir)) { $env:POSH_THEMES_PATH = $_dir; break }
    }
}
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    $_customTheme = Join-Path $env:USERPROFILE ''.psprofile\__OMP_THEME__.omp.json''
    if (Test-Path $_customTheme) {
        $_ompConfig = $_customTheme
    } elseif ($env:POSH_THEMES_PATH) {
        $_ompConfig = Join-Path $env:POSH_THEMES_PATH ''__OMP_THEME__.omp.json''
    }
    if ($_ompConfig -and (Test-Path $_ompConfig)) {
        oh-my-posh init pwsh --config $_ompConfig | Invoke-Expression
    } else {
        Write-Warning "oh-my-posh theme ''__OMP_THEME__'' not found - using default theme."
        oh-my-posh init pwsh | Invoke-Expression
    }
}
# ── end oh-my-posh ───────────────────────────────────────────────────────────').Replace('__OMP_THEME__', $OmpTheme)

# ── Write to the real profile in .psprofile ──────────────────────────────────
# Shared patterns for stripping legacy oh-my-posh config from any profile file.
$ompBlockPattern  = '(?s)\r?\n?# ── oh-my-posh \(managed by altered-carbon\).*?# ── end oh-my-posh[^\r\n]*'
$ompInitPattern   = '(?m)^[^\r\n]*oh-my-posh\s+init\s+(pwsh|powershell)[^\r\n]*\r?\n?'
$ompModulePattern = '(?m)^[^\r\n]*Import-Module\s+oh-my-posh[^\r\n]*\r?\n?'

if (Test-Path $psProfileFile) {
    $profileContent = Get-Content $psProfileFile -Raw

    # Remove any previous managed block (between sentinel comments).
    $cleaned = $profileContent -replace $ompBlockPattern, ''

    # Also strip legacy bare oh-my-posh init lines and module imports from older installs.
    $cleaned = $cleaned -replace $ompInitPattern, ''
    $cleaned = $cleaned -replace $ompModulePattern, ''
    $cleaned = $cleaned.TrimEnd()

    Set-Content -Path $psProfileFile -Value ($cleaned + $ompBlock) -Encoding UTF8
    Write-Host "  Done: oh-my-posh config written to $psProfileFile" -ForegroundColor Green
}
else {
    Set-Content -Path $psProfileFile -Value $ompBlock.TrimStart() -Encoding UTF8
    Write-Host "  Done: profile created at $psProfileFile with oh-my-posh config." -ForegroundColor Green
}

# ── Create stub at default $PROFILE that dot-sources the real profile ────────
# Determine the default $PROFILE path for PowerShell 7 / Preview
$ps7ProfilePath = $null
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $ps7ProfilePath = & pwsh -NoProfile -Command '$PROFILE' 2>$null
}
if (-not $ps7ProfilePath) {
    # Fallback: build the path manually when pwsh is not yet on PATH.
    $documentsPath  = [Environment]::GetFolderPath('MyDocuments')
    $ps7ProfilePath = Join-Path $documentsPath 'PowerShell\Microsoft.PowerShell_profile.ps1'
}
$ps7ProfileDir = Split-Path $ps7ProfilePath -Parent

if (-not (Test-Path $ps7ProfileDir)) {
    New-Item -ItemType Directory -Path $ps7ProfileDir -Force | Out-Null
}

# The stub dot-sources the real profile from .psprofile.
$stubContent = '# Stub profile — managed by altered-carbon.
# The real profile lives outside OneDrive in ~\.psprofile\profile.ps1.
$_realProfile = Join-Path $env:USERPROFILE ''.psprofile\profile.ps1''
if (Test-Path $_realProfile) { . $_realProfile }'

# Only overwrite the stub if it is missing or already a stub we manage.
$writeStub = $true
if (Test-Path $ps7ProfilePath) {
    $existing = Get-Content $ps7ProfilePath -Raw
    if ($existing -notmatch 'managed by altered-carbon') {
        # The user has a custom profile we don't own — migrate its content first.
        Write-Host "  Migrating existing profile content to $psProfileFile" -ForegroundColor Cyan

        # Strip any oh-my-posh blocks/lines already handled above, then prepend.
        $migrated = $existing -replace $ompBlockPattern, ''
        $migrated = $migrated -replace $ompInitPattern, ''
        $migrated = $migrated -replace $ompModulePattern, ''
        $migrated = $migrated.Trim()

        if ($migrated) {
            $current = if (Test-Path $psProfileFile) { Get-Content $psProfileFile -Raw } else { '' }
            Set-Content -Path $psProfileFile -Value ($migrated + "`n" + $current) -Encoding UTF8
        }
    }
}

if ($writeStub) {
    Set-Content -Path $ps7ProfilePath -Value $stubContent -Encoding UTF8
    Write-Host "  Done: stub profile written to $ps7ProfilePath" -ForegroundColor Green
}

# Also create the stub for Windows PowerShell 5.1 so opening any PS edition
# picks up oh-my-posh.  The oh-my-posh block already uses "pwsh" init which
# still works under 5.1; it just skips PS 7-only features gracefully.
$ps51ProfilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
$ps51ProfileDir  = Split-Path $ps51ProfilePath -Parent
if (-not (Test-Path $ps51ProfileDir)) {
    New-Item -ItemType Directory -Path $ps51ProfileDir -Force | Out-Null
}
$writePs51Stub = $true
if (Test-Path $ps51ProfilePath) {
    $existingPs51 = Get-Content $ps51ProfilePath -Raw
    if ($existingPs51 -notmatch 'managed by altered-carbon') {
        # Migrate existing PS 5.1 profile content into .psprofile
        Write-Host "  Migrating existing PS 5.1 profile content to $psProfileFile" -ForegroundColor Cyan
        $migratedPs51 = $existingPs51 -replace $ompBlockPattern, ''
        $migratedPs51 = $migratedPs51 -replace $ompInitPattern, ''
        $migratedPs51 = $migratedPs51 -replace $ompModulePattern, ''
        $migratedPs51 = $migratedPs51.Trim()
        if ($migratedPs51) {
            $currentContent = if (Test-Path $psProfileFile) { Get-Content $psProfileFile -Raw } else { '' }
            if ($currentContent -notmatch [regex]::Escape($migratedPs51)) {
                Set-Content -Path $psProfileFile -Value ($migratedPs51 + "`n" + $currentContent) -Encoding UTF8
            }
        }
    }
}
if ($writePs51Stub) {
    Set-Content -Path $ps51ProfilePath -Value $stubContent -Encoding UTF8
    Write-Host "  Done: stub profile written to $ps51ProfilePath" -ForegroundColor Green
}

# ── Validate oh-my-posh theme file ──────────────────────────────────────────
# The customized theme (with battery widget) ships alongside this script in the
# repo.  Copy it to .psprofile so the profile block can find it at runtime.
$repoThemePath  = Join-Path $PSScriptRoot "$OmpTheme.omp.json"
$customThemePath = Join-Path $psProfileDir "$OmpTheme.omp.json"

if (Test-Path $repoThemePath) {
    Copy-Item -Path $repoThemePath -Destination $customThemePath -Force
    Write-Host "  Done: $OmpTheme theme copied to $customThemePath" -ForegroundColor Green
} elseif ($env:POSH_THEMES_PATH -and (Test-Path (Join-Path $env:POSH_THEMES_PATH "$OmpTheme.omp.json"))) {
    Copy-Item -Path (Join-Path $env:POSH_THEMES_PATH "$OmpTheme.omp.json") -Destination $customThemePath -Force
    Write-Host "  Fallback: copied stock $OmpTheme theme from POSH_THEMES_PATH to $customThemePath" -ForegroundColor Yellow
} elseif (-not (Test-Path $customThemePath)) {
    $themeUrl = "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/$OmpTheme.omp.json"
    Write-Host "  Theme not found locally. Downloading $OmpTheme from GitHub..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $themeUrl -OutFile $customThemePath -UseBasicParsing -ErrorAction Stop
        Write-Host "  Done: theme saved to $customThemePath" -ForegroundColor Green
    } catch {
        Write-Warning "  Failed to download theme: $_"
        Write-Host '  oh-my-posh will fall back to the default theme.' -ForegroundColor Yellow
    }
}

# 2. Windows Terminal — default profile + font
#    Handles both Windows Terminal Preview and the stable release.
Write-Host 'Configuring Windows Terminal...' -ForegroundColor Cyan

$wtPackageDirs = @(
    (Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter 'Microsoft.WindowsTerminalPreview_*' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
    (Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter 'Microsoft.WindowsTerminal_*' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
) | Where-Object { $_ }

if ($wtPackageDirs.Count -eq 0) {
    Write-Warning '  No Windows Terminal package folder found. Launch it once, then re-run this script.'
}

foreach ($wtPackageDir in $wtPackageDirs) {
    $wtLabel = if ($wtPackageDir -match 'Preview') { 'Windows Terminal Preview' } else { 'Windows Terminal' }
    Write-Host "  Configuring $wtLabel..." -ForegroundColor Cyan

    $wtLocalState   = Join-Path $wtPackageDir 'LocalState'
    $wtSettingsPath = Join-Path $wtLocalState 'settings.json'

    if (-not (Test-Path $wtLocalState)) {
        New-Item -ItemType Directory -Path $wtLocalState -Force | Out-Null
    }

    if (Test-Path $wtSettingsPath) {
        $wt = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json
    }
    else {
        $wt = [PSCustomObject]@{
            '$help'   = 'https://aka.ms/terminal-documentation'
            '$schema' = 'https://aka.ms/terminal-profiles-schema'
            profiles  = [PSCustomObject]@{
                defaults = [PSCustomObject]@{}
            }
        }
    }

    # Default profile → PowerShell Preview (GUID is auto-generated by WT, so
    # we discover it from the profiles list rather than hardcoding).
    $pwshPreviewGuid = $null
    if ($wt.profiles -and $wt.profiles.list) {
        $pwshPreviewGuid = $wt.profiles.list |
            Where-Object { $_.name -match 'Preview' -and $_.source -eq 'Windows.Terminal.PowershellCore' } |
            Select-Object -First 1 -ExpandProperty guid
    }
    if (-not $pwshPreviewGuid) {
        # Fallback: look for any PowerShell Core profile (pwsh 7 stable).
        if ($wt.profiles -and $wt.profiles.list) {
            $pwshPreviewGuid = $wt.profiles.list |
                Where-Object { $_.source -eq 'Windows.Terminal.PowershellCore' } |
                Select-Object -First 1 -ExpandProperty guid
        }
    }
    if ($pwshPreviewGuid) {
        if ($wt.PSObject.Properties['defaultProfile']) {
            $wt.defaultProfile = $pwshPreviewGuid
        }
        else {
            $wt | Add-Member -NotePropertyName 'defaultProfile' -NotePropertyValue $pwshPreviewGuid -Force
        }
        Write-Host "    Default profile set to $pwshPreviewGuid" -ForegroundColor Green
    }
    else {
        Write-Warning "    Could not find PowerShell Preview/Core profile in $wtLabel — defaultProfile unchanged."
    }

    # Font → selected Nerd Font for all profiles
    if (-not $wt.profiles) {
        $wt | Add-Member -NotePropertyName 'profiles' -NotePropertyValue ([PSCustomObject]@{ defaults = [PSCustomObject]@{} }) -Force
    }
    if (-not $wt.profiles.defaults) {
        $wt.profiles | Add-Member -NotePropertyName 'defaults' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $fontObj = [PSCustomObject]@{ face = $fontFace }
    if ($wt.profiles.defaults.PSObject.Properties['font']) {
        $wt.profiles.defaults.font = $fontObj
    }
    else {
        $wt.profiles.defaults | Add-Member -NotePropertyName 'font' -NotePropertyValue $fontObj -Force
    }

    $wt | ConvertTo-Json -Depth 10 | Set-Content $wtSettingsPath -Encoding UTF8
    Write-Host "    Done: $wtSettingsPath" -ForegroundColor Green
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

# 4. VS Code & VS Code Insiders — Nerd Font Mono for editor
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

    $fontValue = "'$fontFaceMono', Consolas, 'Courier New', monospace"
    if ($settings.PSObject.Properties['editor.fontFamily']) {
        $settings.'editor.fontFamily' = $fontValue
    }
    else {
        $settings | Add-Member -NotePropertyName 'editor.fontFamily' -NotePropertyValue $fontValue -Force
    }

    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
    Write-Host "  Done: $label font configured." -ForegroundColor Green
}

Write-Host "`nSetup complete." -ForegroundColor Green

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
