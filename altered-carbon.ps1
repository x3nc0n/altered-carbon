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
    [hashtable[]] $ExtraPackages = @(),

    # Execution phase for run-once workflow.
    # Auto (default): detect based on admin status and scheduled-task marker.
    # Phase1: admin installs + register Phase2 task + reboot.
    # Phase2: user-space config + cleanup.
    [ValidateSet('Auto','Phase1','Phase2')]
    [string] $Phase = 'Auto',

    # Skip automatic reboot at end of Phase 1.
    [switch] $SkipReboot
)

$ErrorActionPreference = 'Stop'

# winget exit codes that require explicit handling for idempotent installs.
$WINGET_NO_APPLICABLE_UPGRADE = -1978335189  # 0x8A15002B
$WINGET_PACKAGE_NOT_FOUND     = -1978335212  # 0x8A150014
$WINGET_APP_IN_USE            = -1978335113  # 0x8A150077
$WINGET_UPGRADE_VERSION_NOT_NEWER = -1978335153  # 0x8A15004F
$WINGET_SHELLEXEC_INSTALL_FAILED  = -1978335226  # 0x8A150006
$WINGET_PACKAGE_ALREADY_INSTALLED = -1978335135  # 0x8A150061

# ── Transcript Logging ────────────────────────────────────────────────────────
$logFile = Join-Path $env:USERPROFILE ".altered-carbon-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
try { Start-Transcript -Path $logFile -Append } catch { Write-Warning "Could not start transcript: $_" }

# ── Admin Check ────────────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

# ── Phase Detection ────────────────────────────────────────────────────────────
$taskName = 'altered-carbon-phase2'

if ($Phase -eq 'Auto') {
    if ($isAdmin) {
        $Phase = 'Phase1'
    } else {
        $Phase = 'Phase2'
    }
}
Write-Host "Running in $Phase mode (admin=$isAdmin)" -ForegroundColor Cyan

# ── Helper Functions ───────────────────────────────────────────────────────────

function Update-PathFromRegistry {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
}

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

function Test-WingetKnownVersion {
    param([string] $Version)

    return -not [string]::IsNullOrWhiteSpace($Version) -and $Version -ne 'Unknown'
}

function Compare-WingetVersions {
    param(
        [string] $InstalledVersion,
        [string] $AvailableVersion
    )

    if (-not (Test-WingetKnownVersion -Version $InstalledVersion) -or -not (Test-WingetKnownVersion -Version $AvailableVersion)) {
        return $null
    }

    $installedParts = [regex]::Matches($InstalledVersion, '\d+') | ForEach-Object { [int64]$_.Value }
    $availableParts = [regex]::Matches($AvailableVersion, '\d+') | ForEach-Object { [int64]$_.Value }
    if ($installedParts.Count -eq 0 -or $availableParts.Count -eq 0) {
        return $null
    }

    $maxCount = [Math]::Max($installedParts.Count, $availableParts.Count)
    for ($i = 0; $i -lt $maxCount; $i++) {
        $installedPart = if ($i -lt $installedParts.Count) { $installedParts[$i] } else { 0 }
        $availablePart = if ($i -lt $availableParts.Count) { $availableParts[$i] } else { 0 }

        if ($installedPart -lt $availablePart) { return -1 }
        if ($installedPart -gt $availablePart) { return 1 }
    }

    return 0
}

function Stop-WingetUpgradeProcess {
    [CmdletBinding()]
    param(
        [hashtable] $Package,
        [hashtable] $PackageProcessMap,
        [int] $WaitSeconds = 3
    )

    if (-not $PackageProcessMap.ContainsKey($Package.Id)) {
        return
    }

    $processNames = @($PackageProcessMap[$Package.Id]) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($processNames.Count -eq 0) {
        return
    }

    $runningProcesses = foreach ($processName in $processNames) {
        Get-Process -Name $processName -ErrorAction SilentlyContinue
    }
    $runningProcesses = @($runningProcesses | Sort-Object Id -Unique)
    if ($runningProcesses.Count -eq 0) {
        return
    }

    $stoppedProcessNames = $runningProcesses | Select-Object -ExpandProperty ProcessName -Unique
    Write-Host "  Stopping running process(es) before upgrade: $($stoppedProcessNames -join ', ')." -ForegroundColor Yellow
    $runningProcesses | Stop-Process -ErrorAction Stop
    Start-Sleep -Seconds $WaitSeconds
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
function Initialize-PSModulePath {
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
    return $psModuleDir
}

# ── Custom PowerShell Profile Directory ─────────────────────────────────────
function Initialize-PSProfileDir {
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
    return @{ Dir = $psProfileDir; File = $psProfileFile }
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
function Test-WingetAvailable {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Error 'winget is not available. Install "App Installer" from the Microsoft Store first.'
    }
}

# ── Chocolatey ────────────────────────────────────────────────────────────────
# Chocolatey provides more reliable PATH handling and version management for
# developer tools like git. Used alongside winget, not as a full replacement.
function Install-Chocolatey {
    param([bool] $IsAdmin)

    Write-Host 'Bootstrapping Chocolatey...' -ForegroundColor Cyan

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host '  Skipped: Chocolatey already installed.' -ForegroundColor Yellow
    } elseif ($IsAdmin) {
        try {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
            Update-PathFromRegistry
            Write-Host '  Done: Chocolatey installed.' -ForegroundColor Green
        }
        catch {
            Write-Warning "  Failed to install Chocolatey: $_"
        }
    } else {
        Write-Warning '  Chocolatey requires admin privileges. Re-run script as Administrator to install.'
    }
}

# ── Chocolatey Packages ──────────────────────────────────────────────────────
# Git and Node.js benefit most from Chocolatey: they're immediately on PATH
# and available to downstream tools without a session restart.
function Install-ChocolateyPackages {
    param([bool] $IsAdmin, [string[]] $CurrentSkipPackages)

    # Command is the expected binary name — used to verify the install is healthy.
    $chocoPackages = @(
        @{ Id = 'git';        Name = 'git';           Command = 'git' }
        @{ Id = 'nodejs-lts'; Name = 'Node.js (LTS)'; Command = 'node' }
    )

    $newSkips = @()

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
                if ($isHealthy -and $IsAdmin) {
                    Write-Host "  Upgrading $($pkg.Name) via Chocolatey (no-op if already latest)..." -ForegroundColor Cyan
                    choco upgrade $pkg.Id -y --no-progress
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  Done: $($pkg.Name) is up to date." -ForegroundColor Green
                    } else {
                        Write-Warning "  choco exited with code $LASTEXITCODE upgrading $($pkg.Name)"
                    }
                } elseif ($isHealthy) {
                    Write-Host "  Skipped: $($pkg.Name) already installed via Chocolatey (run as admin to upgrade)." -ForegroundColor Yellow
                } elseif ($IsAdmin) {
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

        Update-PathFromRegistry

        # Skip packages already handled by Chocolatey.
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $newSkips += 'Git.Git'
        }
        if (Get-Command node -ErrorAction SilentlyContinue) {
            $newSkips += 'OpenJS.NodeJS.LTS'
        }
    } else {
        Write-Host 'Chocolatey not available — git and Node.js will be installed via winget as fallback.' -ForegroundColor Yellow
    }

    return $newSkips
}

# ── Installations ─────────────────────────────────────────────────────────────

# Core packages — installed in both Work and Personal modes.
# git and Node.js are installed via Chocolatey above when available; they
# remain here as winget fallbacks and are auto-skipped when choco handled them.
$corePackages = @(
    @{ Id = 'Microsoft.VisualStudioCode';          Name = 'Visual Studio Code';      Source = 'winget' }
    @{ Id = 'Microsoft.VisualStudioCode.Insiders'; Name = 'Visual Studio Code Insiders'; Source = 'winget' }
    @{ Id = 'Microsoft.WindowsTerminal.Preview';   Name = 'Windows Terminal Preview'; Source = 'winget' }
    @{ Id = 'Microsoft.PowerShell';                Name = 'PowerShell 7';            Source = 'winget' }
    @{ Id = 'Microsoft.PowerShell.Preview';        Name = 'PowerShell Preview';      Source = 'winget' }
    @{ Id = 'Git.Git';                             Name = 'git';                     Source = 'winget' }
    @{ Id = 'OpenJS.NodeJS.LTS';                   Name = 'Node.js (LTS)';           Source = 'winget' }
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
    @{ Id = 'Blizzard.BattleNet';                           Name = 'Battle.net';             Source = 'winget'; Location = 'C:\Program Files (x86)\Battle.net' }
    @{ Id = 'OpenWhisperSystems.Signal';                    Name = 'Signal';                 Source = 'winget' }
    @{ Id = 'Google.Chrome';                                Name = 'Google Chrome';          Source = 'winget' }
    @{ Id = 'Brave.Brave';                                  Name = 'Brave Browser';          Source = 'winget' }
    @{ Id = 'PrivateInternetAccess.PrivateInternetAccess';    Name = 'PIA VPN Client';         Source = 'winget' }
    @{ Id = 'Anysphere.Cursor';                             Name = 'Cursor IDE';             Source = 'winget' }
    @{ Id = 'ElementLabs.LMStudio';                         Name = 'LM Studio';              Source = 'winget' }
    @{ Id = 'Adobe.CreativeCloud';                          Name = 'Adobe Creative Cloud';   Source = 'winget' }
    @{ Id = 'Cloudflare.cloudflared';                        Name = 'cloudflared';            Source = 'winget' }
    # Adobe Lightroom is installed through Creative Cloud; a direct winget package is not currently available.
    # Xbox app is not currently discoverable from the configured winget or Store sources.
)

function Install-WingetPackages {
    param(
        [bool] $Personal,
        [string[]] $SkipPackages = @(),
        [hashtable[]] $ExtraPackages = @(),
        [int] $AppInUseExitCode,
        [int] $NoApplicableUpgradeExitCode,
        [int] $PackageNotFoundExitCode,
        [int] $UpgradeVersionNotNewerExitCode = -1978335153
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

    $upgradeProcessMap = @{
        'ElementLabs.LMStudio' = @('LM Studio')
    }

    foreach ($pkg in $wingetPackages) {
        Write-Host "Checking $($pkg.Name) ($($pkg.Id))..." -ForegroundColor Cyan

        # Determine source (default to 'winget' if not specified)
        $source = if ($pkg.Source) { $pkg.Source } else { 'winget' }
        $wingetArgs = @('--id', $pkg.Id, '--exact', '--source', $source, '--accept-source-agreements', '--accept-package-agreements', '--silent')
        if ($pkg.Location) {
            $wingetArgs += @('--location', $pkg.Location)
        }

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
        if (-not $installedVersion) {
            $nameLines = winget list --name $pkg.Name --accept-source-agreements 2>&1 | ForEach-Object { $_.ToString() }
            $nameHeader = $nameLines | Where-Object { $_ -match '^\s*Name\s+' -and $_ -match 'Version' } | Select-Object -First 1
            if ($nameHeader) {
                $installedVersion = 'detected'
            }
        }

        # Fallback: if a Location is specified and that path exists, treat as installed.
        # Some installers (e.g. Battle.net) don't register with winget in a detectable way.
        if (-not $installedVersion -and $pkg.Location -and (Test-Path $pkg.Location)) {
            $installedVersion = 'detected'
            Write-Host "  $($pkg.Name) detected at $($pkg.Location)." -ForegroundColor Green
        }

        # If no available version in list output, check search output
        $latestVersion = $availableVersion
        if (-not (Test-WingetKnownVersion -Version $latestVersion)) {
            $searchLines = winget search --id $pkg.Id --exact --source $source --accept-source-agreements 2>&1 | ForEach-Object { $_.ToString() }
            $searchInfo = Get-WingetVersionInfo -Lines $searchLines -PackageId $pkg.Id
            if ($searchInfo -and (Test-WingetKnownVersion -Version $searchInfo.Version)) {
                $latestVersion = $searchInfo.Version
            }
        }

        if ($installedVersion) {
            $versionComparison = Compare-WingetVersions -InstalledVersion $installedVersion -AvailableVersion $latestVersion
            if ((Test-WingetKnownVersion -Version $latestVersion) -and $versionComparison -lt 0) {
                Write-Host "  Updating $($pkg.Name) from $installedVersion to $latestVersion..." -ForegroundColor Cyan
            } elseif ((Test-WingetKnownVersion -Version $latestVersion) -and $versionComparison -gt 0) {
                Write-Host "  Skipped: installed version ($installedVersion) is newer than available ($latestVersion)." -ForegroundColor Yellow
                continue
            } else {
                Write-Host "  Checking for upgrades for $($pkg.Name) via winget..." -ForegroundColor Cyan
            }

            Stop-WingetUpgradeProcess -Package $pkg -PackageProcessMap $upgradeProcessMap
            & winget upgrade @wingetArgs --include-unknown
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Done: $($pkg.Name) is up to date." -ForegroundColor Green
                continue
            } elseif ($LASTEXITCODE -eq $NoApplicableUpgradeExitCode) {
                Write-Host "  Done: $($pkg.Name) is already up to date." -ForegroundColor Green
                continue
            } elseif ($LASTEXITCODE -eq $UpgradeVersionNotNewerExitCode) {
                if (Test-WingetKnownVersion -Version $latestVersion) {
                    Write-Host "  Skipped: installed version ($installedVersion) is newer than available ($latestVersion)." -ForegroundColor Yellow
                } else {
                    Write-Host "  Done: $($pkg.Name) is already up to date." -ForegroundColor Green
                }
                continue
            } elseif ($LASTEXITCODE -eq $AppInUseExitCode) {
                Write-Warning "  $($pkg.Name) is currently in use. Close it and re-run the script to update."
                continue
            } elseif ($LASTEXITCODE -ne $PackageNotFoundExitCode) {
                Write-Warning "  winget exited with code $LASTEXITCODE while checking/upgrading $($pkg.Name)"
                continue
            }

            Write-Warning "  winget could not map the installed package to $($pkg.Id) for upgrade. Trying install to reconcile package metadata."
        }

        Write-Host "  Installing $($pkg.Name)..." -ForegroundColor Cyan
        & winget install @wingetArgs
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Done: $($pkg.Name) installed." -ForegroundColor Green
        } elseif ($LASTEXITCODE -eq $AppInUseExitCode) {
            Write-Warning "  $($pkg.Name) installer reports the app is in use. Close it and re-run to complete installation."
        } elseif ($LASTEXITCODE -eq $PackageNotFoundExitCode) {
            Write-Warning "  $($pkg.Name) is not available from the configured sources. Verify the package ID and source."
        } else {
            Write-Warning "  winget exited with code $LASTEXITCODE for $($pkg.Name)"
        }
    }
}

# ── Windows Features ──────────────────────────────────────────────────────────
# Enable Hyper-V and WSL 2 (both modes). Requires admin privileges.
function Enable-WindowsFeatures {
    param([bool] $IsAdmin)

    Write-Host 'Enabling Windows features (Hyper-V and WSL 2)...' -ForegroundColor Cyan

    if ($IsAdmin) {
        try {
            $hypervState = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
            $wslState = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction Stop
            $vmPlatformState = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
        } catch {
            Write-Warning "  Windows optional feature management is unavailable on this system ($($_.Exception.Message)). Skipping Hyper-V and WSL 2 configuration."
            return
        }

        # Enable Hyper-V
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
}

# ── Nvidia App (if Nvidia GPU present) ────────────────────────────────────────
function Install-NvidiaApp {
    param([int] $AppInUseExitCode)

    Write-Host 'Checking for Nvidia GPU...' -ForegroundColor Cyan

    $nvidiaGpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'NVIDIA' }

    if ($nvidiaGpu) {
        Write-Host "  Detected: $($nvidiaGpu.Name)" -ForegroundColor Green
        Write-Warning '  NVIDIA App is not currently published in the configured winget sources. Skipping automatic install; install it manually from NVIDIA if needed.'
    } else {
        Write-Host '  Skipped: No Nvidia GPU detected.' -ForegroundColor Yellow
    }
}

# Refresh PATH so newly installed tools (oh-my-posh, git, etc.) are available
# in this session without restarting the terminal.
# (now handled via Update-PathFromRegistry call in orchestration block)

# ── GitHub Copilot CLI ───────────────────────────────────────────────────────
# Copilot CLI is distributed as a GitHub CLI extension.
function Install-GitHubCopilotCli {
    Write-Host 'Ensuring GitHub Copilot CLI extension is installed...' -ForegroundColor Cyan
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        try {
            & gh copilot --help 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host '  Skipped: GitHub Copilot CLI is built into gh.' -ForegroundColor Yellow
                return
            }
        } catch {
            $null = $_
        }

        # Verify gh is authenticated before attempting extension operations.
        # gh extension install/upgrade call the GitHub API; unauthenticated requests
        # are rate-limited and some corporate networks block them entirely.
        & gh auth status 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning '  GitHub CLI is not authenticated. Run "gh auth login" first, then re-run this script to install the Copilot CLI extension.'
            return
        }

        $ghExtensions = & gh extension list 2>$null
        $hasCopilotCli = $false
        if ($ghExtensions) {
            $hasCopilotCli = ($ghExtensions | Select-String -Pattern '(^|\s)(github/)?gh-copilot(\s|$)' -Quiet)
        }

        if ($hasCopilotCli) {
            Write-Host '  Updating GitHub Copilot CLI extension...' -ForegroundColor Cyan
            $ghOutput = & gh extension upgrade github/gh-copilot 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host '  Done: GitHub Copilot CLI extension is up to date.' -ForegroundColor Green
            } else {
                Write-Warning "  gh exited with code $LASTEXITCODE while upgrading GitHub Copilot CLI extension"
                if ($ghOutput) { $ghOutput | ForEach-Object { Write-Warning "    $_" } }
                Write-Host '  Tip: Run "gh auth login" if your GitHub CLI session has expired.' -ForegroundColor Yellow
            }
        } else {
            Write-Host '  Installing GitHub Copilot CLI extension...' -ForegroundColor Cyan
            $ghOutput = & gh extension install github/gh-copilot 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host '  Done: GitHub Copilot CLI extension installed.' -ForegroundColor Green
            } else {
                Write-Warning "  gh exited with code $LASTEXITCODE while installing GitHub Copilot CLI extension"
                if ($ghOutput) { $ghOutput | ForEach-Object { Write-Warning "    $_" } }
                Write-Host '  Tip: Run "gh auth login" if GitHub CLI is not authenticated yet.' -ForegroundColor Yellow
            }
        }
    } else {
        Write-Warning '  GitHub CLI (gh) not found on PATH. Copilot CLI extension setup skipped.'
    }
}

# ── Microsoft Work IQ CLI ────────────────────────────────────────────────────
# Work IQ is distributed as a global npm package and requires Node.js.
function Install-WorkIqCli {
    Write-Host 'Ensuring Microsoft Work IQ CLI is installed...' -ForegroundColor Cyan
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        $workIqInstalled = & npm list --global @microsoft/workiq --depth=0 2>$null | Select-String '@microsoft/workiq@'

        if ($workIqInstalled) {
            Write-Host '  Updating Microsoft Work IQ CLI...' -ForegroundColor Cyan
            & npm update --global @microsoft/workiq 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host '  Done: Microsoft Work IQ CLI is up to date.' -ForegroundColor Green
            } else {
                Write-Warning "  npm exited with code $LASTEXITCODE while updating Microsoft Work IQ CLI"
            }
        } else {
            Write-Host '  Installing Microsoft Work IQ CLI...' -ForegroundColor Cyan
            & npm install --global @microsoft/workiq 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host '  Done: Microsoft Work IQ CLI installed.' -ForegroundColor Green
            } else {
                Write-Warning "  npm exited with code $LASTEXITCODE while installing Microsoft Work IQ CLI"
            }
        }
    } else {
        Write-Warning '  npm not found on PATH. Microsoft Work IQ CLI setup skipped.'
    }
}

# ── Nerd Font ────────────────────────────────────────────────────────────────
# oh-my-posh ships a CLI to install Nerd Fonts from the official nerd-fonts releases.
function Install-NerdFont {
    param(
        [string] $FontName,
        [bool] $IsAdmin
    )

    Write-Host "Installing Nerd Font '$FontName'..." -ForegroundColor Cyan

    $fontFace     = $null
    $fontFaceMono = $null

    if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
        # Check font registry to see if already installed (prefer HKLM for WT compat).
        $nfPattern = '(' + [regex]::Escape($FontName) + '|' + ($FontName -creplace '([a-z])([A-Z])', '$1\s*$2') + ')'
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
            Write-Host "  Skipped: $FontName Nerd Font already installed system-wide." -ForegroundColor Yellow
        } elseif ($fontInstalledScope -eq 'User') {
            Write-Host "  $FontName Nerd Font installed per-user — promoting to system-wide for Windows Terminal compatibility..." -ForegroundColor Cyan
            Invoke-ElevatedFontPromotion -NfPattern $nfPatternEscaped
        } else {
            if ($IsAdmin) {
                & oh-my-posh font install $FontName
            } else {
                & oh-my-posh font install $FontName --user
            }
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Done: $FontName Nerd Font installed." -ForegroundColor Green

                if (-not $IsAdmin) {
                    Write-Host "  Promoting per-user fonts to system-wide for Windows Terminal..." -ForegroundColor Cyan
                    Invoke-ElevatedFontPromotion -NfPattern $nfPatternEscaped
                }
            } else {
                Write-Warning "  oh-my-posh font install exited with code $LASTEXITCODE for $FontName"
            }
        }

        # Resolve the actual font face name from the registry.
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
    if (-not $fontFace)     { $fontFace     = "$FontName Nerd Font" }
    if (-not $fontFaceMono) { $fontFaceMono = "$fontFace Mono" }
    Write-Host "  Resolved font face: $fontFace | Mono: $fontFaceMono" -ForegroundColor Cyan

    return @{ Face = $fontFace; Mono = $fontFaceMono }
}

# ── PSGallery Trust ────────────────────────────────────────────────────────────
function Set-PSGalleryTrust {
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
}

# ── PowerShell Modules ─────────────────────────────────────────────────────────
# Install commonly used modules into CurrentUser scope (no admin required).
function Install-PSModules {
    param([string] $ModuleDir)

    $psModules = @(
        # Core
        @{ Name = 'Microsoft.Graph';           Description = 'Microsoft Graph';                         Source = 'PSGallery' }
        @{ Name = 'Az';                        Description = 'Azure PowerShell';                        Source = 'PSGallery' }
        @{ Name = 'ExchangeOnlineManagement';  Description = 'Exchange Online Management';              Source = 'PSGallery' }
        @{ Name = 'MicrosoftTeams';            Description = 'Microsoft Teams';                         Source = 'PSGallery' }
        @{ Name = 'PnP.PowerShell';            Description = 'PnP PowerShell (SharePoint / M365)';     Source = 'PSGallery' }
        @{ Name = 'MicrosoftPowerBIMgmt';      Description = 'Power BI Management';                     Source = 'PSGallery' }
        @{ Name = 'Microsoft365DSC';           Description = 'Microsoft 365 DSC';                       Source = 'PSGallery' }
        @{ Name = 'ActiveDirectory';           Description = 'Active Directory';                        Source = 'RSAT';        Message = 'ActiveDirectory comes from RSAT, not PSGallery. Install "RSAT: Active Directory Domain Services and Lightweight Directory Services Tools" from Optional Features or with Add-WindowsCapability as admin.' }
        @{ Name = 'Microsoft.Graph.Intune';    Description = 'Microsoft Graph Intune';                  Source = 'PSGallery' }
        # Sentinel / Security
        @{ Name = 'AzSentinel';                Description = 'Azure Sentinel (community)';              Source = 'PSGallery' }
        @{ Name = 'MSAL.PS';                   Description = 'MSAL.PS (token acquisition)';             Source = 'PSGallery' }
        @{ Name = 'PSKusto';                   Description = 'PSKusto (KQL from PowerShell)';           Source = 'Unavailable'; Message = 'PSKusto is not currently available in PSGallery. Skipping automatic install.' }
    )

    foreach ($mod in $psModules) {
        Write-Host "Installing module $($mod.Description) ($($mod.Name))..." -ForegroundColor Cyan
        if (Get-Module -ListAvailable -Name $mod.Name -ErrorAction SilentlyContinue) {
            Write-Host "  Skipped: $($mod.Name) already installed." -ForegroundColor Yellow
            continue
        }

        switch ($mod.Source) {
            'PSGallery' {
                try {
                    Save-Module -Name $mod.Name -Path $ModuleDir -Force -AcceptLicense -ErrorAction Stop
                    Write-Host "  Done: $($mod.Name)" -ForegroundColor Green
                }
                catch {
                    Write-Warning "  Failed to install $($mod.Name): $_"
                }
            }
            default {
                Write-Host "  Skipped: $($mod.Message)" -ForegroundColor Yellow
            }
        }
    }
}

# ── VS Code Extensions ─────────────────────────────────────────────────────────
# Install useful extensions into both VS Code and VS Code Insiders.
function Install-VSCodeExtensions {
    $vsCodeExtensions = @(
        @{ Id = 'ms-azuretools.vscode-azureresourcegroups'; Name = 'Azure Resources' }
        @{ Id = 'ms-azuretools.vscode-bicep';               Name = 'Bicep' }
        @{ Id = 'github.copilot';                           Name = 'GitHub Copilot' }
        @{ Id = 'github.copilot-chat';                      Name = 'GitHub Copilot Chat' }
        @{ Id = 'ms-azuretools.vscode-azure-github-copilot'; Name = 'GitHub Copilot for Azure' }
        @{ Id = 'ms-windows-ai-studio.windows-ai-studio';   Name = 'AI Toolkit for Visual Studio Code' }
        @{ Id = 'ms-security.ms-sentinel';                  Name = 'Microsoft Sentinel' }
    )

    $staleVsCodeExtensions = @(
        'ms-sentinel.azure-sentinel-tools'
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

        foreach ($staleExtId in $staleVsCodeExtensions) {
            if ($installedExts -contains $staleExtId) {
                Write-Host "  Removing stale extension $staleExtId..." -ForegroundColor Cyan
                & $editor --uninstall-extension $staleExtId --force 2>&1 | Out-Null
                Write-Host "  Done: removed $staleExtId" -ForegroundColor Green
            }
        }
    }
}

# ── Configuration ─────────────────────────────────────────────────────────────
function Set-OhMyPoshProfile {
    param(
        [string] $ThemeName,
        [string] $ProfileDir,
        [string] $ProfileFile
    )

    # Migrate from the deprecated oh-my-posh PowerShell module (if still present).
    Write-Host 'Checking for deprecated oh-my-posh PowerShell module...' -ForegroundColor Cyan
    $availableOhMyPoshModule = Get-Module -ListAvailable -Name 'oh-my-posh' -ErrorAction SilentlyContinue
    $installedOhMyPoshModule = Get-InstalledModule -Name 'oh-my-posh' -ErrorAction SilentlyContinue
    if ($availableOhMyPoshModule -or ($env:POSH_PATH -and (Test-Path $env:POSH_PATH))) {
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

            if ($installedOhMyPoshModule) {
                Uninstall-Module oh-my-posh -AllVersions -Force -ErrorAction Stop
                Write-Host '  Done: oh-my-posh PowerShell module uninstalled.' -ForegroundColor Green
            } else {
                Write-Host '  Skipped: deprecated module is not registered with PowerShellGet.' -ForegroundColor Yellow
            }
        } catch {
            Write-Warning "  Could not fully remove oh-my-posh module: $_"
        }
    } else {
        Write-Host '  Skipped: deprecated module not found.' -ForegroundColor Yellow
    }

    Write-Host "Configuring oh-my-posh $ThemeName theme..." -ForegroundColor Cyan

    $ompBlock = ('
# ── oh-my-posh (managed by altered-carbon) ───────────────────────────────────
if (-not $env:POSH_THEMES_PATH) {
    $_themeCandidates = @(
        (Join-Path $env:LOCALAPPDATA ''Programs\oh-my-posh\themes'')
    )
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
# ── end oh-my-posh ───────────────────────────────────────────────────────────').Replace('__OMP_THEME__', $ThemeName)

    # Shared patterns for stripping legacy oh-my-posh config from any profile file.
    $ompBlockPattern  = '(?s)\r?\n?# ── oh-my-posh \(managed by altered-carbon\).*?# ── end oh-my-posh[^\r\n]*'
    $ompInitPattern   = '(?m)^[^\r\n]*oh-my-posh\s+init\s+(pwsh|powershell)[^\r\n]*\r?\n?'
    $ompModulePattern = '(?m)^[^\r\n]*Import-Module\s+oh-my-posh[^\r\n]*\r?\n?'

    if (Test-Path $ProfileFile) {
        $profileContent = Get-Content $ProfileFile -Raw
        $cleaned = $profileContent -replace $ompBlockPattern, ''
        $cleaned = $cleaned -replace $ompInitPattern, ''
        $cleaned = $cleaned -replace $ompModulePattern, ''
        $cleaned = $cleaned.TrimEnd()
        Set-Content -Path $ProfileFile -Value ($cleaned + $ompBlock) -Encoding UTF8
        Write-Host "  Done: oh-my-posh config written to $ProfileFile" -ForegroundColor Green
    }
    else {
        Set-Content -Path $ProfileFile -Value $ompBlock.TrimStart() -Encoding UTF8
        Write-Host "  Done: profile created at $ProfileFile with oh-my-posh config." -ForegroundColor Green
    }

    # ── Create stub at default $PROFILE that dot-sources the real profile ────
    $ps7ProfilePath = $null
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        $ps7ProfilePath = & pwsh -NoProfile -Command '$PROFILE' 2>$null
    }
    if (-not $ps7ProfilePath) {
        $documentsPath  = [Environment]::GetFolderPath('MyDocuments')
        $ps7ProfilePath = Join-Path $documentsPath 'PowerShell\Microsoft.PowerShell_profile.ps1'
    }
    $ps7ProfileDir = Split-Path $ps7ProfilePath -Parent

    if (-not (Test-Path $ps7ProfileDir)) {
        New-Item -ItemType Directory -Path $ps7ProfileDir -Force | Out-Null
    }

    $stubContent = '# Stub profile — managed by altered-carbon.
# The real profile lives outside OneDrive in ~\.psprofile\profile.ps1.
$_realProfile = Join-Path $env:USERPROFILE ''.psprofile\profile.ps1''
if (Test-Path $_realProfile) { . $_realProfile }'

    if (Test-Path $ps7ProfilePath) {
        $existing = Get-Content $ps7ProfilePath -Raw
        if ($existing -notmatch 'managed by altered-carbon') {
            Write-Host "  Migrating existing profile content to $ProfileFile" -ForegroundColor Cyan
            $migrated = $existing -replace $ompBlockPattern, ''
            $migrated = $migrated -replace $ompInitPattern, ''
            $migrated = $migrated -replace $ompModulePattern, ''
            $migrated = $migrated.Trim()

            if ($migrated) {
                $current = if (Test-Path $ProfileFile) { Get-Content $ProfileFile -Raw } else { '' }
                if ($current -notmatch [regex]::Escape($migrated)) {
                    Set-Content -Path $ProfileFile -Value ($migrated + "`n" + $current) -Encoding UTF8
                }
            }
        }
    }

    if (-not (Test-Path $ps7ProfilePath) -or (Get-Content $ps7ProfilePath -Raw) -match 'managed by altered-carbon') {
        Set-Content -Path $ps7ProfilePath -Value $stubContent -Encoding UTF8
        Write-Host "  Done: stub profile written to $ps7ProfilePath" -ForegroundColor Green
    }

    # PS 5.1 stub
    $ps51ProfilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
    $ps51ProfileDir  = Split-Path $ps51ProfilePath -Parent
    if (-not (Test-Path $ps51ProfileDir)) {
        New-Item -ItemType Directory -Path $ps51ProfileDir -Force | Out-Null
    }
    if (Test-Path $ps51ProfilePath) {
        $existingPs51 = Get-Content $ps51ProfilePath -Raw
        if ($existingPs51 -notmatch 'managed by altered-carbon') {
            Write-Host "  Migrating existing PS 5.1 profile content to $ProfileFile" -ForegroundColor Cyan
            $migratedPs51 = $existingPs51 -replace $ompBlockPattern, ''
            $migratedPs51 = $migratedPs51 -replace $ompInitPattern, ''
            $migratedPs51 = $migratedPs51 -replace $ompModulePattern, ''
            $migratedPs51 = $migratedPs51.Trim()
            if ($migratedPs51) {
                $currentContent = if (Test-Path $ProfileFile) { Get-Content $ProfileFile -Raw } else { '' }
                if ($currentContent -notmatch [regex]::Escape($migratedPs51)) {
                    Set-Content -Path $ProfileFile -Value ($migratedPs51 + "`n" + $currentContent) -Encoding UTF8
                }
            }
        }
    }
    if (-not (Test-Path $ps51ProfilePath) -or (Get-Content $ps51ProfilePath -Raw) -match 'managed by altered-carbon') {
        Set-Content -Path $ps51ProfilePath -Value $stubContent -Encoding UTF8
        Write-Host "  Done: stub profile written to $ps51ProfilePath" -ForegroundColor Green
    }

    # ── Validate oh-my-posh theme file ──────────────────────────────────────
    $repoThemePath   = Join-Path $PSScriptRoot "$ThemeName.omp.json"
    $customThemePath = Join-Path $ProfileDir "$ThemeName.omp.json"

    if (Test-Path $repoThemePath) {
        Copy-Item -Path $repoThemePath -Destination $customThemePath -Force
        Write-Host "  Done: $ThemeName theme copied to $customThemePath" -ForegroundColor Green
    } elseif ($env:POSH_THEMES_PATH -and (Test-Path (Join-Path $env:POSH_THEMES_PATH "$ThemeName.omp.json"))) {
        Copy-Item -Path (Join-Path $env:POSH_THEMES_PATH "$ThemeName.omp.json") -Destination $customThemePath -Force
        Write-Host "  Fallback: copied stock $ThemeName theme from POSH_THEMES_PATH to $customThemePath" -ForegroundColor Yellow
    } elseif (-not (Test-Path $customThemePath)) {
        $themeUrl = "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/$ThemeName.omp.json"
        Write-Host "  Theme not found locally. Downloading $ThemeName from GitHub..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $themeUrl -OutFile $customThemePath -UseBasicParsing -ErrorAction Stop
            Write-Host "  Done: theme saved to $customThemePath" -ForegroundColor Green
        } catch {
            Write-Warning "  Failed to download theme: $_"
            Write-Host '  oh-my-posh will fall back to the default theme.' -ForegroundColor Yellow
        }
    }
}

# 2. Windows Terminal — default profile + font
function Set-WindowsTerminalConfig {
    param([string] $FontFaceName)

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

        $pwshPreviewGuid = $null
        if ($wt.profiles -and $wt.profiles.list) {
            $pwshPreviewGuid = $wt.profiles.list |
                Where-Object { $_.name -match 'Preview' -and $_.source -eq 'Windows.Terminal.PowershellCore' } |
                Select-Object -First 1 -ExpandProperty guid
        }
        if (-not $pwshPreviewGuid) {
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

        if (-not $wt.profiles) {
            $wt | Add-Member -NotePropertyName 'profiles' -NotePropertyValue ([PSCustomObject]@{ defaults = [PSCustomObject]@{} }) -Force
        }
        if (-not $wt.profiles.defaults) {
            $wt.profiles | Add-Member -NotePropertyName 'defaults' -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        $fontObj = [PSCustomObject]@{ face = $FontFaceName }
        if ($wt.profiles.defaults.PSObject.Properties['font']) {
            $wt.profiles.defaults.font = $fontObj
        }
        else {
            $wt.profiles.defaults | Add-Member -NotePropertyName 'font' -NotePropertyValue $fontObj -Force
        }

        $wt | ConvertTo-Json -Depth 10 | Set-Content $wtSettingsPath -Encoding UTF8
        Write-Host "    Done: $wtSettingsPath" -ForegroundColor Green
    }
}

# 3. Set Windows Terminal Preview as the default terminal (Windows 11)
function Set-DefaultTerminal {
    Write-Host 'Setting Windows Terminal Preview as default terminal...' -ForegroundColor Cyan
    $regPath = 'HKCU:\Console\%%Startup'
    try {
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        Set-ItemProperty -Path $regPath -Name 'DelegationConsole'  -Value '{06171993-2EB2-4CB9-8A6E-492235E1EAFC}'
        Set-ItemProperty -Path $regPath -Name 'DelegationTerminal' -Value '{86633F1F-6C40-4FA7-B9A0-E7E6D27C4B72}'
        Write-Host '  Done: default terminal set.' -ForegroundColor Green
    }
    catch {
        Write-Warning "  Failed to set default terminal: $_"
    }
}

# 4. VS Code & VS Code Insiders — Nerd Font Mono for editor
function Set-VSCodeFont {
    param([string] $FontFaceMonoName)

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

        $fontValue = "'$FontFaceMonoName', Consolas, 'Courier New', monospace"
        if ($settings.PSObject.Properties['editor.fontFamily']) {
            $settings.'editor.fontFamily' = $fontValue
        }
        else {
            $settings | Add-Member -NotePropertyName 'editor.fontFamily' -NotePropertyValue $fontValue -Force
        }

        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
        Write-Host "  Done: $label font configured." -ForegroundColor Green
    }
}

# 5. Configure File Explorer options
function Set-FileExplorerOptions {
    Write-Host 'Configuring File Explorer options...' -ForegroundColor Cyan
    try {
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -Value 0
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Hidden' -Value 1
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowSuperHidden' -Value 1
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' -Name 'FullPath' -Value 1
        $runAsKey = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
        $runAsName = 'ShowRunAsDifferentUserInStart'
        try {
            if (-not (Test-Path $runAsKey)) {
                New-Item -Path $runAsKey -Force | Out-Null
            }
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
}

# 6. Post-install verification summary

function Get-CommandVersion {
    param(
        [string] $Command,
        [string[]] $VersionArgs = @('--version')
    )

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $output = & $Command @VersionArgs 2>$null
        if ($output) {
            return (($output | Select-Object -First 1).ToString().Trim())
        }
    } catch {
        return $null
    }

    return 'installed'
}

function Write-VerificationLine {
    param(
        [string] $Label,
        [bool] $Installed,
        [string] $Details
    )

    if ($Installed) {
        $suffix = if ($Details) { " - $Details" } else { '' }
        Write-Host "  [OK] $Label$suffix" -ForegroundColor Green
    } else {
        $suffix = if ($Details) { " - $Details" } else { '' }
        Write-Host "  [MISSING] $Label$suffix" -ForegroundColor Yellow
    }
}

function Show-VerificationSummary {
    Write-Host "`nPost-install verification summary..." -ForegroundColor Cyan

    $gitVersion = Get-CommandVersion -Command 'git'
    Write-VerificationLine -Label 'git' -Installed ([bool]$gitVersion) -Details $gitVersion

    $nodeVersion = Get-CommandVersion -Command 'node'
    Write-VerificationLine -Label 'Node.js' -Installed ([bool]$nodeVersion) -Details $nodeVersion

    $npmVersion = Get-CommandVersion -Command 'npm'
    Write-VerificationLine -Label 'npm' -Installed ([bool]$npmVersion) -Details $npmVersion

    $ghVersion = Get-CommandVersion -Command 'gh'
    Write-VerificationLine -Label 'GitHub CLI' -Installed ([bool]$ghVersion) -Details $ghVersion

    $ghCopilotInstalled = $false
    $ghCopilotDetails = $null
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        # First: check if gh copilot is available as a built-in subcommand
        try {
            $null = & gh copilot --help 2>$null
            if ($LASTEXITCODE -eq 0) {
                $ghCopilotInstalled = $true
                $ghCopilotDetails = 'built-in subcommand'
            }
        } catch {
            $null = $_  # built-in not available; fall through to extension check
        }

        # Fallback: check for the gh-copilot extension
        if (-not $ghCopilotInstalled) {
            try {
                $ghExtensions = & gh extension list 2>$null
                if ($ghExtensions | Select-String -Pattern '(^|\s)(github/)?gh-copilot(\s|$)' -Quiet) {
                    $ghCopilotInstalled = $true
                    $ghCopilotDetails = 'gh extension installed'
                }
            } catch {
                $ghCopilotDetails = 'unable to query gh extensions'
            }
        }
    }
    Write-VerificationLine -Label 'GitHub Copilot CLI' -Installed $ghCopilotInstalled -Details $ghCopilotDetails

    $workIqVersion = Get-CommandVersion -Command 'workiq' -VersionArgs @('version')
    Write-VerificationLine -Label 'Microsoft Work IQ CLI' -Installed ([bool]$workIqVersion) -Details $workIqVersion

    $ompVersion = Get-CommandVersion -Command 'oh-my-posh'
    Write-VerificationLine -Label 'oh-my-posh' -Installed ([bool]$ompVersion) -Details $ompVersion

    $vsCodeVerification = @(
        @{ Editor = 'code'; Label = 'VS Code'; Extensions = @(
            @{ Id = 'github.copilot'; Name = 'GitHub Copilot' }
            @{ Id = 'github.copilot-chat'; Name = 'GitHub Copilot Chat' }
            @{ Id = 'ms-azuretools.vscode-azure-github-copilot'; Name = 'GitHub Copilot for Azure' }
            @{ Id = 'ms-windows-ai-studio.windows-ai-studio'; Name = 'AI Toolkit for Visual Studio Code' }
            @{ Id = 'ms-security.ms-sentinel'; Name = 'Microsoft Sentinel' }
        ) }
        @{ Editor = 'code-insiders'; Label = 'VS Code Insiders'; Extensions = @(
            @{ Id = 'github.copilot'; Name = 'GitHub Copilot' }
            @{ Id = 'github.copilot-chat'; Name = 'GitHub Copilot Chat' }
            @{ Id = 'ms-azuretools.vscode-azure-github-copilot'; Name = 'GitHub Copilot for Azure' }
            @{ Id = 'ms-windows-ai-studio.windows-ai-studio'; Name = 'AI Toolkit for Visual Studio Code' }
            @{ Id = 'ms-security.ms-sentinel'; Name = 'Microsoft Sentinel' }
        ) }
    )

    foreach ($editorInfo in $vsCodeVerification) {
        if (-not (Get-Command $editorInfo.Editor -ErrorAction SilentlyContinue)) {
            Write-VerificationLine -Label $editorInfo.Label -Installed $false -Details 'CLI not found on PATH'
            continue
        }

        $installedExtensions = & $editorInfo.Editor --list-extensions 2>$null
        Write-VerificationLine -Label $editorInfo.Label -Installed $true -Details 'CLI available'

        # github.copilot and github.copilot-chat have been consolidated — either presence satisfies both
        $copilotPairIds = @('github.copilot', 'github.copilot-chat')
        $copilotPairPresent = [bool]($copilotPairIds | Where-Object { $installedExtensions -contains $_ })

        foreach ($extension in $editorInfo.Extensions) {
            $isInstalled = $installedExtensions -contains $extension.Id
            $details = $extension.Id
            if ($extension.Id -in $copilotPairIds -and -not $isInstalled -and $copilotPairPresent) {
                $isInstalled = $true
                $details = "$($extension.Id) (consolidated)"
            }
            Write-VerificationLine -Label ("  " + $extension.Name) -Installed $isInstalled -Details $details
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# ── Main Orchestration ────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

# Shared init (idempotent, both phases)
$psModuleDir = Initialize-PSModulePath
$profileInfo = Initialize-PSProfileDir
$psProfileDir  = $profileInfo.Dir
$psProfileFile = $profileInfo.File

Test-WingetAvailable

if ($Phase -eq 'Phase1') {
    # ── Phase 1: Admin installs + Windows features + schedule Phase 2 ────────

    # Clean up any leftover Phase 2 scheduled task from a previous run
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  Cleaned up leftover '$taskName' scheduled task from previous run." -ForegroundColor Yellow
    }

    Install-Chocolatey -IsAdmin $isAdmin
    $chocoSkips = Install-ChocolateyPackages -IsAdmin $isAdmin -CurrentSkipPackages $SkipPackages
    $SkipPackages += $chocoSkips
    # Spotify requires non-admin install — skip in Phase 1
    $SkipPackages += 'Spotify.Spotify'
    Install-WingetPackages -Personal $Personal.IsPresent -SkipPackages $SkipPackages -ExtraPackages $ExtraPackages -AppInUseExitCode $WINGET_APP_IN_USE -NoApplicableUpgradeExitCode $WINGET_NO_APPLICABLE_UPGRADE -PackageNotFoundExitCode $WINGET_PACKAGE_NOT_FOUND -UpgradeVersionNotNewerExitCode $WINGET_UPGRADE_VERSION_NOT_NEWER
    Enable-WindowsFeatures -IsAdmin $isAdmin
    Install-NvidiaApp -AppInUseExitCode $WINGET_APP_IN_USE
    Update-PathFromRegistry
    Install-GitHubCopilotCli
    Install-WorkIqCli

    # Register Phase 2 scheduled task (runs at logon as current user, non-elevated)
    $scriptPath = $MyInvocation.MyCommand.Path
    if ($scriptPath -and ($Work.IsPresent -or $Personal.IsPresent)) {
        $modeSwitch = if ($Work.IsPresent) { '-Work' } else { '-Personal' }
        $pwshPath   = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if (-not $pwshPath) { $pwshPath = 'pwsh' }
        $action    = New-ScheduledTaskAction -Execute $pwshPath -Argument "-NoProfile -File `"$scriptPath`" $modeSwitch -Phase Phase2"
        $trigger   = New-ScheduledTaskTrigger -AtLogon -User $env:USERNAME
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "  Scheduled task '$taskName' registered for Phase 2 at next logon." -ForegroundColor Green
    }

    if (-not $SkipReboot) {
        Write-Host ''
        Write-Host 'Phase 1 complete. A reboot is required for Phase 2.' -ForegroundColor Yellow
        Read-Host 'Press Enter to reboot now (or Ctrl+C to cancel)'
        shutdown /r /t 0
    } else {
        Write-Host 'Phase 1 complete. Reboot skipped (-SkipReboot). Run Phase 2 manually or reboot to trigger it.' -ForegroundColor Yellow
    }
} elseif ($Phase -eq 'Phase2') {
    # ── Phase 2: User-space config + cleanup ─────────────────────────────────
    # Install Spotify (requires non-admin)
    Write-Host 'Installing Spotify (user-space)...' -ForegroundColor Cyan
    $spotifyOutput = winget install --id 'Spotify.Spotify' --source winget --accept-source-agreements --accept-package-agreements --silent 2>&1 | ForEach-Object { $_.ToString() }
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  Done: Spotify installed.' -ForegroundColor Green
    } elseif ($LASTEXITCODE -eq $WINGET_APP_IN_USE) {
        Write-Host '  Skipped: Spotify already running.' -ForegroundColor Yellow
    } elseif ($LASTEXITCODE -eq $WINGET_PACKAGE_ALREADY_INSTALLED) {
        Write-Host '  Skipped: Spotify is already installed.' -ForegroundColor Yellow
    } elseif ($LASTEXITCODE -eq $WINGET_SHELLEXEC_INSTALL_FAILED) {
        $spotifyInstalled = $false
        $spotifyVersionInfo = Get-WingetVersionInfo -Lines (
            winget list --id 'Spotify.Spotify' --exact --source winget --accept-source-agreements 2>&1 | ForEach-Object { $_.ToString() }
        ) -PackageId 'Spotify.Spotify'
        if ($spotifyVersionInfo) {
            $spotifyInstalled = $true
        } else {
            $spotifyInstalled = [bool](
                winget list --name 'Spotify' --accept-source-agreements 2>&1 |
                    ForEach-Object { $_.ToString() } |
                    Where-Object { $_ -match '^\s*Spotify(\s{2,}|\t)' }
            )
        }

        if ($spotifyInstalled) {
            Write-Host '  Skipped: Spotify is already installed.' -ForegroundColor Yellow
        } else {
            Write-Warning '  winget could not launch the Spotify installer (ShellExecute failed). Open Spotify from the Microsoft Store or rerun winget after refreshing App Installer.'
            if ($spotifyOutput) {
                $spotifyOutput | ForEach-Object { Write-Warning "    $_" }
            }
        }
    } else {
        Write-Warning "  winget exited with code $LASTEXITCODE for Spotify"
    }

    $fontInfo = Install-NerdFont -FontName $NerdFont -IsAdmin $isAdmin
    $fontFace     = $fontInfo.Face
    $fontFaceMono = $fontInfo.Mono

    Set-PSGalleryTrust
    Install-PSModules -ModuleDir $psModuleDir
    Install-VSCodeExtensions
    Set-OhMyPoshProfile -ThemeName $OmpTheme -ProfileDir $psProfileDir -ProfileFile $psProfileFile
    Set-WindowsTerminalConfig -FontFaceName $fontFace
    Set-DefaultTerminal
    Set-VSCodeFont -FontFaceMonoName $fontFaceMono
    Set-FileExplorerOptions
    Show-VerificationSummary

    # Clean up scheduled task
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "  Scheduled task '$taskName' cleaned up." -ForegroundColor Green
}

Write-Host "`nSetup complete." -ForegroundColor Green

if ($Phase -eq 'Phase2') {
    Read-Host 'Press Enter to close this window'
}

try { Stop-Transcript } catch { }
