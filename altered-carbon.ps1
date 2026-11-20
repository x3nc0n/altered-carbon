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
    # Auto (default): start installation; Phase2 is explicitly scheduled after reboot.
    # Phase1: admin installs + register Phase2 task + reboot.
    # Phase2: user-space config + cleanup.
    [ValidateSet('Auto','Phase1','Phase2')]
    [string] $Phase = 'Auto',

    # Skip automatic reboot at end of Phase 1.
    [switch] $SkipReboot,

    # Internal one-shot identifier used by the scheduled Phase 2 action.
    [guid] $ResumeToken = [guid]::Empty
)

$ErrorActionPreference = 'Stop'
if (-not ($Work.IsPresent -or $Personal.IsPresent)) {
    throw 'Specify either -Work or -Personal.'
}

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
    $Phase = 'Phase1'
}
Write-Host "Running in $Phase mode (admin=$isAdmin)" -ForegroundColor Cyan

# ── Helper Functions ───────────────────────────────────────────────────────────

function Remove-Phase2Task {
    param([string] $TaskName)

    try {
        $task = Get-ScheduledTask -TaskPath '\' -ErrorAction Stop |
            Where-Object TaskName -EQ $TaskName
        if (-not $task) { return }

        Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
        $remaining = Get-ScheduledTask -TaskPath '\' -ErrorAction Stop |
            Where-Object TaskName -EQ $TaskName
        if ($remaining) { throw 'The task still exists after removal.' }
        Write-Host "  Scheduled task '$TaskName' cleaned up." -ForegroundColor Green
    } catch {
        throw "Could not remove scheduled task '$TaskName'. No configuration will run. Remove it from Task Scheduler as administrator, then retry with -Phase Phase2. Details: $_"
    }
}

function Enter-Phase2Resume {
    param([guid] $Token)

    $stateDir = Join-Path $env:LOCALAPPDATA 'altered-carbon'
    $null = New-Item -Path $stateDir -ItemType Directory -Force -ErrorAction Stop
    $markerPath = Join-Path $stateDir "phase2-$Token.attempted"
    try {
        # CreateNew makes the claim durable and prevents concurrent/repeated logons
        # from executing configuration for the same scheduled attempt.
        $stream = [System.IO.File]::Open($markerPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    } catch [System.IO.IOException] {
        if (Test-Path -LiteralPath $markerPath) { return $false }
        throw
    }
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-Date).ToString('o'))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    return $true
}

function Grant-Phase2TaskAccess {
    param(
        [string] $TaskName,
        [string] $UserSid
    )

    # An elevated registration must allow its limited user to delete this task.
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $task = $scheduler.GetFolder('\').GetTask($TaskName)
    $descriptor = [System.Security.AccessControl.RawSecurityDescriptor]::new($task.GetSecurityDescriptor(4))
    $sid = [System.Security.Principal.SecurityIdentifier]::new($UserSid)
    $ace = [System.Security.AccessControl.CommonAce]::new(
        [System.Security.AccessControl.AceFlags]::None,
        [System.Security.AccessControl.AceQualifier]::AccessAllowed,
        0x10000000, $sid, $false, $null
    )
    $descriptor.DiscretionaryAcl.InsertAce($descriptor.DiscretionaryAcl.Count, $ace)
    $task.SetSecurityDescriptor($descriptor.GetSddlForm([System.Security.AccessControl.AccessControlSections]::Access), 0)
}

function Get-Phase2TaskArguments {
    param(
        [string] $ScriptPath,
        [bool] $Personal,
        [string] $ThemeName,
        [string] $FontName,
        [string[]] $SkipPackages,
        [guid] $Token
    )

    $modeSwitch = if ($Personal) { '-Personal' } else { '-Work' }
    $command = "& '$($ScriptPath.Replace("'", "''"))' $modeSwitch -Phase Phase2 -ResumeToken '$Token'" +
        " -OmpTheme '$($ThemeName.Replace("'", "''"))' -NerdFont '$($FontName.Replace("'", "''"))'"
    if ($SkipPackages.Count) {
        $quotedSkips = $SkipPackages | ForEach-Object { "'$($_.Replace("'", "''"))'" }
        $command += " -SkipPackages @($($quotedSkips -join ','))"
    }
    # EncodedCommand preserves spaces, quotes, and array arguments across logon.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

function Test-LegacyOhMyPoshPath {
    param(
        [string] $Path,
        [string[]] $ModuleBase
    )

    try {
        $target = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $target.PSIsContainer -or $target.PSProvider.Name -ne 'FileSystem') { return $false }
        $fullPath = $target.FullName.TrimEnd('\')
        if ($fullPath -eq [System.IO.Path]::GetPathRoot($target.FullName).TrimEnd('\')) { return $false }
        $homePath = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
        if ($fullPath -eq $homePath -or $homePath.StartsWith($fullPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $knownPaths = @($ModuleBase | Where-Object { $_ } | ForEach-Object {
            [System.IO.Path]::GetFullPath($_).TrimEnd('\')
        })
        if ($fullPath -notin $knownPaths) { return $false }
        $ancestor = $target
        while ($ancestor) {
            if ($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
            $ancestor = $ancestor.Parent
        }
        if (Get-ChildItem -LiteralPath $fullPath -Force -Recurse -ErrorAction Stop |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
            Select-Object -First 1) { return $false }
        return $true
    } catch {
        return $false
    }
}

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
    $packagePattern = '(?<!\S)' + [regex]::Escape($PackageId) + '(?!\S)'
    $dataLine = $Lines | Where-Object { $_ -match $packagePattern } | Select-Object -First 1
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

# ── Installations ─────────────────────────────────────────────────────────────

# Core packages — installed in both Work and Personal modes.
# Keep one package manager so skip requests and upgrades use the same path.
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
    @{ Id = 'GitHub.Copilot';                      Name = 'GitHub Copilot CLI';       Source = 'winget' }
    @{ Id = 'XPDCK2L0R6V76J';                      Name = 'GitHub Copilot App';       Source = 'msstore'; ExactMatchOnly = $true }
    @{ Id = 'bradygaster.Squad';                   Name = 'Squad CLI';               Source = 'winget'; ExactMatchOnly = $true }
    @{ Id = 'RedHat.Podman';                       Name = 'Podman';                  Source = 'winget'; ExactMatchOnly = $true }
    @{ Id = 'RedHat.Podman-Desktop';               Name = 'Podman Desktop';          Source = 'winget'; ExactMatchOnly = $true }
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
    @{ Id = 'Blizzard.BattleNet';                           Name = 'Battle.net';             Source = 'winget'; Location = (Join-Path ${env:ProgramFiles(x86)} 'Battle.net') }
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

        # Some packages install as MSIX with a different ID; identity-sensitive packages must not match by name.
        if (-not $installedVersion -and -not $pkg.ExactMatchOnly) {
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
        foreach ($feature in @('Microsoft-Hyper-V-All', 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
            try {
                $state = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction Stop
                if ($state.State -in @('Enabled', 'EnablePending')) {
                    Write-Host "  Skipped: $feature already enabled or pending reboot." -ForegroundColor Yellow
                    continue
                }
                Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop | Out-Null
                Write-Host "  Done: $feature enabled (reboot required)." -ForegroundColor Green
            } catch {
                # Hyper-V is unavailable on Home editions; WSL must still run.
                Write-Warning "  Windows optional feature management is unavailable for ${feature}: $_"
            }
        }
        Write-Host '  Run "wsl --install" after reboot to install WSL and a Linux distribution.' -ForegroundColor Cyan
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

function Get-CudaInstallPlan {
    param([object[]] $Gpu)

    $legacy = @('5.0', '5.2', '5.3', '6.0', '6.1', '6.2', '7.0', '7.2')
    $modern = @('7.5', '8.0', '8.6', '8.7', '8.9', '9.0', '10.0', '10.3', '11.0', '12.0', '12.1')
    if (-not $Gpu.Count) { return @{ Reason = 'No GPU capability/driver data.' } }
    foreach ($device in $Gpu) {
        if ($device.Capability -notin ($legacy + $modern) -or $device.Driver -notmatch '^\d+\.\d+$') {
            return @{ Reason = "Unknown NVIDIA capability or driver for $($device.Name); no installation attempted." }
        }
    }
    $version = '13.5'
    $minimumDriver = [version]'620.0'
    if (@($Gpu | Where-Object Capability -In $legacy).Count) {
        $version = '12.9'
        $minimumDriver = [version]'576.57'
        if (@($Gpu | Where-Object Capability -In @('10.3', '11.0', '12.1')).Count) {
            return @{ Reason = 'Mixed GPUs need different toolkit generations; select side-by-side toolkits manually.' }
        }
    }
    return @{ Version = $version; MinimumDriver = $minimumDriver; Architectures = @($Gpu.Capability | ForEach-Object { 'compute_' + $_.Replace('.', '') } | Select-Object -Unique) }
}

function Get-CudaCompiler {
    $candidates = @()
    $command = Get-Command nvcc -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    foreach ($variable in Get-ChildItem Env: | Where-Object Name -Match '^CUDA_PATH(_V\d+_\d+)?$') {
        $candidates += Join-Path $variable.Value 'bin\nvcc.exe'
    }
    if ($env:ProgramFiles) {
        $root = Join-Path $env:ProgramFiles 'NVIDIA GPU Computing Toolkit\CUDA'
        if (Test-Path -LiteralPath $root) {
            $candidates += Get-ChildItem -LiteralPath $root -Directory | ForEach-Object { Join-Path $_.FullName 'bin\nvcc.exe' }
        }
    }
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $versionOutput = & $candidate --version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch 'release (\d+\.\d+)') { continue }
        $version = [version]$Matches[1]
        $architectures = @(& $candidate --list-gpu-arch 2>$null)
        if ($LASTEXITCODE -ne 0) { continue }
        [pscustomobject]@{ Path = $candidate; Version = $version; Architectures = $architectures }
    }
}

function Get-WindowsNativeArchitecture {
    # Win32_Processor reports native hardware even when the shell is emulated.
    $architectures = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
        Select-Object -ExpandProperty Architecture -Unique)
    if ($architectures.Count -ne 1 -or $null -eq $architectures[0]) { return 'Unknown' }
    switch ($architectures[0]) {
        0 { return 'X86' }
        9 { return 'X64' }
        12 { return 'Arm64' }
        default { return 'Unknown' }
    }
}

function Install-CudaToolkit {
    param([string[]] $SkipPackages = @())

    if ('Nvidia.CUDA' -in $SkipPackages) {
        Write-Host '  Skipped: CUDA Toolkit (-SkipPackages Nvidia.CUDA).' -ForegroundColor Yellow
        return
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $architecture = Get-WindowsNativeArchitecture
        $build = [int]$os.BuildNumber
        $supportedBuilds = if ($os.ProductType -eq 1) { @(19045, 22621, 22631, 26100, 26200) } else { @(20348, 26100) }
        if ($architecture -ne 'X64' -or -not [Environment]::Is64BitProcess -or $build -notin $supportedBuilds) {
            Write-Warning 'CUDA Toolkit skipped: requires native Windows x64 on a documented Windows 10 22H2, Windows 11, or Server 2022/2025 build.'
            return
        }
        $present = @(Get-PnpDevice -PresentOnly -Class Display -Status OK -ErrorAction Stop |
            Where-Object InstanceId -Match '^PCI\\VEN_10DE&')
        if (-not $present.Count) {
            Write-Host '  Skipped: CUDA Toolkit; no present healthy PCI NVIDIA GPU (AMD/Intel are not CUDA devices).' -ForegroundColor Yellow
            return
        }
        $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if (-not $smi) {
            $smiPath = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
            if (Test-Path -LiteralPath $smiPath) { $smi = Get-Item -LiteralPath $smiPath }
        }
        if (-not $smi) { Write-Warning 'CUDA Toolkit skipped: nvidia-smi/working NVIDIA driver is missing.'; return }
        $smiPath = if ($smi.Source) { $smi.Source } else { $smi.FullName }
        $rows = @(& $smiPath --query-gpu=pci.bus_id,name,compute_cap,driver_version --format=csv,noheader,nounits 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $rows.Count) { Write-Warning 'CUDA Toolkit skipped: NVIDIA capability query failed.'; return }
        $gpus = @($rows | ConvertFrom-Csv -Header Bus, Name, Capability, Driver | ForEach-Object {
            [pscustomobject]@{ Bus = ([string]$_.Bus).Trim(); Name = ([string]$_.Name).Trim(); Capability = ([string]$_.Capability).Trim(); Driver = ([string]$_.Driver).Trim() }
        })
        if (@($gpus | Where-Object Bus -NotMatch '^[0-9A-Fa-f]{4,8}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$').Count) {
            Write-Warning 'CUDA Toolkit skipped: NVIDIA query did not identify known PCI GPU bus addresses.'
            return
        }
        $plan = Get-CudaInstallPlan -Gpu $gpus
        if (-not $plan.Version) { Write-Warning "CUDA Toolkit skipped: $($plan.Reason)"; return }
        if ($plan.Version -eq '12.9' -and $build -eq 26200) {
            Write-Warning 'CUDA 12.9 skipped: Windows 11 25H2 is not in its documented OS support matrix.'
            return
        }
        $compilers = @(Get-CudaCompiler)
        foreach ($compiler in $compilers) {
            $driverMinimum = if ($compiler.Version -ge [version]'13.0') { [version]'620.0' } else { [version]'576.57' }
            if ($compiler.Version -ge [version]'11.0' -and $compiler.Version -le [version]'13.5' -and
                -not @($gpus | Where-Object { [version]$_.Driver -lt $driverMinimum }).Count -and
                -not @($plan.Architectures | Where-Object { $_ -notin $compiler.Architectures }).Count) {
                Write-Host "  Skipped: compatible CUDA Toolkit $($compiler.Version) preserved at $($compiler.Path)." -ForegroundColor Yellow
                return
            }
        }
        foreach ($device in $gpus) {
            if ([version]$device.Driver -lt $plan.MinimumDriver) {
                Write-Warning "CUDA Toolkit skipped: $($device.Name) needs NVIDIA driver $($plan.MinimumDriver)+ for CUDA $($plan.Version); update the driver manually first."
                return
            }
        }
        if (@($compilers | Where-Object Version -GT ([version]$plan.Version)).Count) {
            Write-Warning "CUDA Toolkit skipped: newer toolkit exists; no downgrade or PATH replacement. Install CUDA $($plan.Version) side by side manually if needed."
            return
        }
        $arguments = @('install', '--id', 'Nvidia.CUDA', '--exact', '--source', 'winget', '--version', $plan.Version,
            '--scope', 'machine', '--silent', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
        if ($plan.Version -eq '12.9') {
            # NVIDIA 12.9.1 Windows guide: explicit subpackages replace the defaults; exclude Display.Driver.
            $components = @('nvcc', 'cudart', 'cublas', 'cublas_dev', 'cufft', 'cufft_dev', 'curand', 'curand_dev',
                'cusolver', 'cusolver_dev', 'cusparse', 'cusparse_dev', 'npp', 'npp_dev', 'nvrtc', 'nvrtc_dev',
                'nvjitlink', 'nvfatbin', 'nvjpeg', 'nvjpeg_dev', 'nvml_dev', 'thrust', 'cuobjdump', 'nvdisasm',
                'nvprune', 'cuxxfilt', 'sanitizer', 'visual_studio_integration')
            $arguments += @('--override', ('-s -n ' + (($components | ForEach-Object { "${_}_12.9" }) -join ' ')))
        }
        Write-Host "Installing CUDA Toolkit $($plan.Version) only; existing display driver is not replaced..." -ForegroundColor Cyan
        & winget @arguments
        if ($LASTEXITCODE -ne 0) { throw "winget CUDA installation failed (exit $LASTEXITCODE)." }
        $verified = @(Get-CudaCompiler | Where-Object {
            $compiler = $_
            $compiler.Version -eq [version]$plan.Version -and
                -not @($plan.Architectures | Where-Object { $_ -notin $compiler.Architectures }).Count
        })
        if (-not $verified.Count) { throw 'CUDA installer returned success, but a compiler supporting all detected GPUs was not found. Review the installer log/reboot requirements.' }
        Write-Host "  Done: CUDA Toolkit $($plan.Version) compiler and GPU targets verified; compiling applications also requires supported Visual Studio C++ tools." -ForegroundColor Green
    } catch {
        throw "CUDA Toolkit setup failed: $_"
    }
}

function Test-FoundryReady {
    try {
        $status = Invoke-RestMethod -Uri 'http://127.0.0.1:39839/openai/status' -TimeoutSec 2 -NoProxy -ErrorAction Stop
        return [bool]($status.ModelDirPath -and $status.PipeName -and @($status.Endpoints | Where-Object {
            $uri = [uri]$_
            $uri.IsLoopback -and $uri.Port -eq 39839
        }).Count)
    } catch { return $false }
}

function Install-FoundryLocal {
    param([string[]] $SkipPackages = @())

    if ('Microsoft.FoundryLocal' -in $SkipPackages) {
        Write-Host '  Skipped: Foundry Local install/autostart (-SkipPackages Microsoft.FoundryLocal).' -ForegroundColor Yellow
        return
    }
    $os = Get-CimInstance Win32_OperatingSystem
    $architecture = Get-WindowsNativeArchitecture
    if ($architecture -notin @('X64', 'Arm64') -or $os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 26100) {
        Write-Warning 'Foundry Local skipped: automation targets the tested Windows 11 24H2+ x64/ARM64 baseline. Other Windows versions are not validated here.'
        return
    }
    $foundry = Get-Command foundry -ErrorAction SilentlyContinue
    if (-not $foundry) {
        & winget install --id Microsoft.FoundryLocal --exact --source winget --scope user --silent --accept-source-agreements --accept-package-agreements --disable-interactivity
        if ($LASTEXITCODE -notin @(0, -1978335135, -1978335189)) { throw "Foundry Local user installation failed (exit $LASTEXITCODE)." }
        Update-PathFromRegistry
        $foundry = Get-Command foundry -ErrorAction SilentlyContinue
    }
    if (-not $foundry) { throw 'Foundry Local installed but foundry is not on PATH. Reopen a non-elevated terminal and retry Phase 2.' }
    & $foundry.Source --version
    if ($LASTEXITCODE -ne 0) { throw 'Foundry Local version verification failed.' }
    $helpText = & $foundry.Source server start --help 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $helpText -notmatch '--port\b' -or $helpText -notmatch '--idle-timeout\b') {
        throw 'Foundry Local CLI lacks documented server start --port/--idle-timeout support. Upgrade Microsoft.FoundryLocal as this user, then retry; no existing server was stopped.'
    }
    $directory = Join-Path $env:LOCALAPPDATA 'altered-carbon\foundry-local'
    $null = New-Item -ItemType Directory -Path $directory -Force
    $wrapper = Join-Path $directory 'start-foundry.ps1'
    $owner = '# altered-carbon: Foundry Local login supervisor v1'
    if ((Test-Path -LiteralPath $wrapper) -and (Get-Content -LiteralPath $wrapper -First 1) -ne $owner) {
        throw "Refusing to overwrite an unowned Foundry wrapper: $wrapper"
    }
    $runtime = @'
# altered-carbon: Foundry Local login supervisor v1
$ErrorActionPreference = 'Stop'
$directory = Split-Path -Parent $PSCommandPath
try {
    Start-Transcript -Path (Join-Path $directory 'startup.log') -Append | Out-Null
    __READY_FUNCTION__
    while ($true) {
        if (-not (Test-FoundryReady)) {
            $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
            if (@($listeners | Where-Object Port -EQ 39839).Count) {
                throw 'Port 39839 is occupied but does not report a healthy Foundry Local server. Nothing was stopped; resolve the conflict manually.'
            }
            $process = Start-Process -FilePath '__FOUNDRY__' -ArgumentList @('server', 'start', '--port', '39839', '--idle-timeout', '0') -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $directory 'server-start.log') -RedirectStandardError (Join-Path $directory 'server-start-error.log')
            if (-not $process.WaitForExit(45000)) {
                Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
                throw 'Foundry server start timed out after 45 seconds. Only the launched CLI was stopped; inspect server-start logs.'
            }
            if ($process.ExitCode -ne 0) { throw "Foundry server start failed (exit $($process.ExitCode)); see server-start logs." }
            $ready = $false
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                if (Test-FoundryReady) { $ready = $true; break }
                Start-Sleep -Seconds 1
            }
            if (-not $ready) { throw 'Foundry readiness timed out. An existing daemon on another port is left untouched; inspect foundry server status and resolve manually.' }
            Write-Host "$(Get-Date -Format o) Foundry Local ready at http://127.0.0.1:39839/v1 (no model downloaded)."
        }
        Start-Sleep -Seconds 30
    }
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
'@
    $runtime = $runtime.Replace('__READY_FUNCTION__', "function Test-FoundryReady {`n$(${function:Test-FoundryReady}.ToString())`n}").
        Replace('__FOUNDRY__', $foundry.Source.Replace("'", "''"))
    $runtimeChanged = -not (Test-Path -LiteralPath $wrapper) -or (Get-Content -LiteralPath $wrapper -Raw) -cne $runtime
    if ($runtimeChanged) {
        Set-Content -LiteralPath $wrapper -Value $runtime -NoNewline -Encoding utf8
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $name = "altered-carbon-foundry-local-$sid"
    $description = 'altered-carbon owned Foundry Local login supervisor v1'
    $existing = Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -EQ $name
    if ($existing -and $existing.Description -ne $description) { throw "Refusing to replace unowned scheduled task '$name'." }
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$wrapper`""
    $matchesTask = $existing -and $existing.Actions.Count -eq 1 -and $existing.Actions[0].Execute -eq $pwsh -and
        $existing.Actions[0].Arguments -eq $arguments -and $existing.Principal.UserId -eq $sid -and
        $existing.Principal.LogonType -eq 'Interactive' -and $existing.Principal.RunLevel -eq 'Limited' -and
        $existing.Triggers.Count -eq 1 -and @($existing.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and $_.UserId -eq $sid -and $_.Enabled }).Count -eq 1 -and
        $existing.Settings.Enabled -and $existing.Settings.MultipleInstances -eq 'IgnoreNew' -and
        -not $existing.Settings.DisallowStartIfOnBatteries -and -not $existing.Settings.StopIfGoingOnBatteries -and
        $existing.Settings.ExecutionTimeLimit -eq 'PT0S'
    if (-not $matchesTask) {
        if ($existing.State -eq 'Running') { Stop-ScheduledTask -TaskName $name }
        $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogon -User $sid
        $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero) -StartWhenAvailable
        Register-ScheduledTask -TaskName $name -Description $description -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    } elseif ($runtimeChanged -and $existing.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $name
    }
    $task = Get-ScheduledTask -TaskName $name
    if ($task.State -ne 'Running') { Start-ScheduledTask -TaskName $name }
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if ((Test-FoundryReady) -and (Get-ScheduledTask -TaskName $name).State -eq 'Running') { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw "Foundry Local not ready at http://127.0.0.1:39839/v1; inspect $directory\startup.log and server-start logs. No unrelated process/server was stopped." }
    Write-Host "  Done: Foundry Local endpoint ready; login autostart task '$name' registered (not a pre-login service). Logs: $directory" -ForegroundColor Green
    Write-Host '  MANUAL: GitHub Copilot desktop > Settings > Model providers > Add provider > Foundry Local; endpoint http://127.0.0.1:39839/v1. Explicitly choose/download a model and use its actual discovered ID. No provider, model, or credentials were configured.' -ForegroundColor Yellow
}

# Refresh PATH so newly installed tools (oh-my-posh, git, etc.) are available
# in this session without restarting the terminal.
# (now handled via Update-PathFromRegistry call in orchestration block)

function Set-WorkNpmRegistry {
    $registry = 'https://packagefeedproxy.microsoft.io/npm/'
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw 'npm is required to configure the Work-only 1ES package feed.'
    }
    $currentRegistry = & npm config get registry --location=user 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the npm registry configuration.' }
    if (($currentRegistry | Out-String).Trim().TrimEnd('/') -eq $registry.TrimEnd('/')) {
        Write-Host '  Skipped: 1ES npm feed registry already configured.' -ForegroundColor Yellow
        return
    }
    $null = & npm config set registry $registry --location=user 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not configure the 1ES npm feed (npm exit code $LASTEXITCODE)." }
    Write-Host '  Done: 1ES npm feed registry configured for the current user.' -ForegroundColor Green
}

function Install-Agency {
    $agencyPath = Join-Path $env:APPDATA 'agency\CurrentVersion\agency.exe'
    if ((Get-Command agency -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $agencyPath -PathType Leaf)) {
        Write-Host '  Skipped: Agency already installed.' -ForegroundColor Yellow
        return
    }
    Write-Host 'Installing Agency with the documented Microsoft InstallTool...' -ForegroundColor Cyan
    # Isolate the vendor script so its exit statement cannot terminate Phase 2.
    & pwsh -NoProfile -Command '$ErrorActionPreference = "Stop"; & ([scriptblock]::Create((Invoke-RestMethod -Uri "https://aka.ms/InstallTool.ps1"))) agency; if ($LASTEXITCODE) { exit $LASTEXITCODE }'
    if ($LASTEXITCODE -ne 0) { throw "Agency installation failed (exit code $LASTEXITCODE). Check corporate access/authentication and retry Phase 2." }
    Update-PathFromRegistry
    if (-not ((Get-Command agency -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $agencyPath -PathType Leaf))) {
        throw 'Agency installer completed, but agency was not found. Check installer output and corporate access/authentication.'
    }
    Write-Host '  Done: Agency installed.' -ForegroundColor Green
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
    param([string] $FontName)

    Write-Host "Installing Nerd Font '$FontName'..." -ForegroundColor Cyan

    $fontFace     = $null
    $fontFaceMono = $null

    if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
        # Windows Terminal supports both system-wide and per-user fonts.
        $nfPattern = '(' + [regex]::Escape($FontName) + '|' + ($FontName -creplace '([a-z])([A-Z])', '$1\s*$2') + ')'
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

        if ($fontInstalledScope) {
            Write-Host "  Skipped: $FontName Nerd Font already installed ($fontInstalledScope)." -ForegroundColor Yellow
        } else {
            & oh-my-posh font install $FontName
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Done: $FontName Nerd Font installed." -ForegroundColor Green
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
    Write-Host 'Ensuring PSGallery is registered (preserving repository trust)...' -ForegroundColor Cyan
    $psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $psGallery) {
        Register-PSRepository -Default -ErrorAction Stop
        Write-Host '  Done: PSGallery registered with default trust.' -ForegroundColor Green
    } else {
        Write-Host '  Skipped: PSGallery settings and trust preserved.' -ForegroundColor Yellow
    }
}

# ── PowerShell Modules ─────────────────────────────────────────────────────────
function Get-AzArtifactsCredentialProviderPath {
    foreach ($target in @('User', 'Machine')) {
        $configuredPath = [Environment]::GetEnvironmentVariable('NUGET_PLUGIN_PATHS', $target)
        if ($configuredPath) { return $configuredPath }
    }
    $pluginRoot = Join-Path $env:USERPROFILE '.nuget\plugins'
    $netcorePath = Join-Path $pluginRoot 'netcore\CredentialProvider.Microsoft'
    $netfxPath = Join-Path $pluginRoot 'netfx\CredentialProvider.Microsoft'
    if (-not (Test-Path -LiteralPath $netcorePath) -and (Test-Path -LiteralPath $netfxPath -PathType Container)) {
        return (Join-Path $netfxPath 'CredentialProvider.Microsoft.exe')
    }
    $visualStudioPath = Join-Path $env:ProgramFiles 'Microsoft Visual Studio'
    if (-not (Test-Path -LiteralPath $netcorePath) -and (Test-Path -LiteralPath $visualStudioPath -PathType Container)) {
        $visualStudioProvider = [IO.Directory]::GetFiles($visualStudioPath, 'CredentialProvider.Microsoft.exe', [IO.SearchOption]::AllDirectories) |
            Select-Object -First 1
        if ($visualStudioProvider) { return $visualStudioProvider }
    }
    return (Join-Path $netcorePath 'CredentialProvider.Microsoft.exe')
}

function Test-AzArtifactsCredentialProvider {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        if ([IO.Path]::GetExtension($Path) -eq '.dll') {
            & dotnet $Path -h *> $null
        } else {
            & $Path -h *> $null
        }
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Install-AzArtifactsCredentialProvider {
    param([string] $Architecture = (Get-WindowsNativeArchitecture))

    $candidate = Get-AzArtifactsCredentialProviderPath
    if (Test-AzArtifactsCredentialProvider -Path $candidate) { return }

    $pluginRoot = Join-Path $env:USERPROFILE '.nuget\plugins\netcore'
    $destination = Join-Path $pluginRoot 'CredentialProvider.Microsoft'
    $apphost = Join-Path $destination 'CredentialProvider.Microsoft.exe'
    if ($candidate -ne $apphost -or (Test-Path -LiteralPath $destination)) {
        throw 'The existing or configured Azure Artifacts Credential Provider is unusable. Its files and settings were preserved.'
    }

    switch ($Architecture) {
        'X64' {
            $rid = 'win-x64'
            $sha256 = 'f7d3cef19621fb3a87e4b38f5fbaba429917a4ca6881422764a474667dd0c038'
        }
        'Arm64' {
            $rid = 'win-arm64'
            $sha256 = '9aff3b5064ca47e37ddcabd95a85c87c92f1753f62014a7250045acc3943ef0a'
        }
        default { throw 'No supported self-contained Azure Artifacts Credential Provider exists for this Windows architecture.' }
    }

    $stage = Join-Path $pluginRoot ".altered-carbon-credprovider-$([guid]::NewGuid().ToString('N'))"
    $stageCreated = $false
    try {
        $null = New-Item -Path $stage -ItemType Directory -ErrorAction Stop
        $stageCreated = $true
        $archive = Join-Path $stage 'provider.zip'
        Invoke-WebRequest -Uri "https://github.com/microsoft/artifacts-credprovider/releases/download/v2.0.6/Microsoft.$rid.NuGet.CredentialProvider.zip" -OutFile $archive -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256 -ErrorAction Stop).Hash -ne $sha256) {
            throw 'Azure Artifacts Credential Provider archive checksum verification failed.'
        }
        $extracted = Join-Path $stage 'extracted'
        Expand-Archive -LiteralPath $archive -DestinationPath $extracted -ErrorAction Stop
        $provider = Join-Path $extracted 'plugins\netcore\CredentialProvider.Microsoft'
        foreach ($file in @('CredentialProvider.Microsoft.exe', 'CredentialProvider.Microsoft.dll',
            'CredentialProvider.Microsoft.deps.json', 'CredentialProvider.Microsoft.runtimeconfig.json', 'hostfxr.dll', 'coreclr.dll')) {
            if (-not (Test-Path -LiteralPath (Join-Path $provider $file) -PathType Leaf)) {
                throw 'The Azure Artifacts Credential Provider archive is incomplete.'
            }
        }
        if (-not (Test-AzArtifactsCredentialProvider -Path (Join-Path $provider 'CredentialProvider.Microsoft.exe'))) {
            throw 'The staged Azure Artifacts Credential Provider could not run.'
        }
        [IO.Directory]::Move($provider, $destination)
        if (-not (Test-AzArtifactsCredentialProvider -Path (Get-AzArtifactsCredentialProviderPath))) {
            throw 'The installed Azure Artifacts Credential Provider is not discoverable or usable.'
        }
    } finally {
        if ($stageCreated) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop }
    }
}

function Initialize-PSModuleRepository {
    param([switch] $Work)

    if (-not $Work) { return 'PSGallery' }

    $repositoryName = 'azure-powershell'
    $sourceLocation = 'https://packagefeedproxy.microsoft.io/powershell/v2'
    $resourceLocation = 'https://packagefeedproxy.microsoft.io/powershell/v3/index.json'
    $repositories = @(Get-PSRepository -ErrorAction Stop -WarningAction SilentlyContinue | Where-Object Name -EQ $repositoryName)
    if ($repositories.Count -gt 1 -or ($repositories.Count -eq 1 -and
        ([string]$repositories[0].SourceLocation).TrimEnd('/') -ne $sourceLocation)) {
        throw 'The existing azure-powershell PowerShellGet registration has a different source. No settings were overwritten.'
    }

    $hasResourceGet = [bool](Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue)
    if ($hasResourceGet) {
        $resourceRepositories = @(Get-PSResourceRepository -ErrorAction Stop -WarningAction SilentlyContinue | Where-Object Name -EQ $repositoryName)
        if ($resourceRepositories.Count -gt 1 -or ($resourceRepositories.Count -eq 1 -and
            ([string]$resourceRepositories[0].Uri).TrimEnd('/') -ne $resourceLocation)) {
            throw 'The existing azure-powershell PSResourceGet registration has a different source. No settings were overwritten.'
        }
        if ($resourceRepositories.Count -eq 1 -and [string]$resourceRepositories[0].CredentialProvider -notin @('', 'None', '0', 'AzArtifacts', '1')) {
            throw 'The existing azure-powershell credential provider is unsupported. Its settings were preserved.'
        }
    }

    if ($repositories.Count -eq 0) {
        Register-PSRepository -Name $repositoryName -SourceLocation $sourceLocation -ErrorAction Stop | Out-Null
    }
    if ($hasResourceGet) {
        if ($resourceRepositories.Count -eq 0) {
            Register-PSResourceRepository -Name $repositoryName -Uri $resourceLocation -CredentialProvider AzArtifacts -ErrorAction Stop | Out-Null
        } elseif ([string]$resourceRepositories[0].CredentialProvider -notin @('AzArtifacts', '1')) {
            Set-PSResourceRepository -Name $repositoryName -CredentialProvider AzArtifacts -ErrorAction Stop | Out-Null
        }
    } else {
        Write-Warning 'PSResourceGet is unavailable; its repository registration is unsupported in this shell.'
    }

    return $repositoryName
}

# Install commonly used modules into CurrentUser scope (no admin required).
function Install-PSModules {
    param(
        [string] $ModuleDir,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Repository
    )

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
    )

    foreach ($mod in $psModules) {
        Write-Host "Installing or updating module $($mod.Description) ($($mod.Name))..." -ForegroundColor Cyan

        switch ($mod.Source) {
            'PSGallery' {
                try {
                    $installedModule = Get-Module -ListAvailable -Name $mod.Name -ErrorAction SilentlyContinue |
                        Sort-Object Version -Descending |
                        Select-Object -First 1
                    $latestModule = Find-Module -Name $mod.Name -Repository $Repository -ErrorAction Stop

                    if ($installedModule -and $installedModule.Version -ge $latestModule.Version) {
                        Write-Host "  Skipped: $($mod.Name) is already up to date ($($installedModule.Version))." -ForegroundColor Yellow
                        continue
                    }

                    Save-Module -Name $mod.Name -Repository $Repository -Path $ModuleDir -Force -AcceptLicense -ErrorAction Stop
                    Write-Host "  Done: $($mod.Name) $($latestModule.Version)" -ForegroundColor Green
                }
                catch {
                    Write-Warning "  Failed to install or update $($mod.Name): $_"
                }
            }
            default {
                Write-Host "  Skipped: $($mod.Message)" -ForegroundColor Yellow
            }
        }
    }
}

# ── VS Code Extensions ─────────────────────────────────────────────────────────
function Get-VSCodeCopilotDetails {
    param([string] $Editor)

    # Built-in extensions are omitted by --list-extensions. Resolve through the
    # selected editor so portable and versioned installations work as well.
    try {
        $extensionPaths = @(& $Editor --locate-extension github.copilot-chat 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
        foreach ($extensionPath in $extensionPaths) {
            if (-not [System.IO.Path]::IsPathRooted([string]$extensionPath)) { continue }
            $manifestPath = Join-Path ([string]$extensionPath) 'package.json'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ("$($manifest.publisher).$($manifest.name)" -ieq 'github.copilot-chat' -and $manifest.version) {
                return "github.copilot-chat (included with editor, version $($manifest.version); presence only)"
            }
        }
    } catch {
        Write-Verbose "Could not locate GitHub Copilot Chat extension for ${Editor}: $_"
    }
    return $null
}

# Install useful extensions into both VS Code and VS Code Insiders.
function Install-VSCodeExtensions {
    $vsCodeExtensions = @(
        @{ Id = 'ms-azuretools.vscode-azureresourcegroups'; Name = 'Azure Resources' }
        @{ Id = 'ms-azuretools.vscode-bicep';               Name = 'Bicep' }
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
        $editorLabel = if ($editor -eq 'code') { 'VS Code' } else { 'VS Code Insiders' }
        try {
            $installedExts = @(& $editor --list-extensions 2>$null)
            if ($LASTEXITCODE -ne 0) { throw "extension listing exited with code $LASTEXITCODE" }
        } catch {
            Write-Warning "Could not check extensions for ${editorLabel}: $_"
            continue
        }

        foreach ($ext in $vsCodeExtensions) {
            $extensionLabel = "$($ext.Name) extension for $editorLabel ($($ext.Id))"
            if ($ext.Id -eq 'github.copilot-chat' -and $installedExts -notcontains $ext.Id) {
                $copilotDetails = Get-VSCodeCopilotDetails -Editor $editor
                if ($copilotDetails) {
                    Write-Host "  Skipped: $extensionLabel - $copilotDetails." -ForegroundColor Yellow
                    continue
                }
            }
            if ($installedExts -contains $ext.Id) {
                Write-Host "  Skipped: $extensionLabel already installed." -ForegroundColor Yellow
            } else {
                Write-Host "  Installing $extensionLabel..." -ForegroundColor Cyan
                try {
                    $installOutput = @(& $editor --install-extension $ext.Id --force 2>&1)
                    if ($LASTEXITCODE -ne 0) { throw "exit code ${LASTEXITCODE}: $($installOutput -join ' ')" }
                    Write-Host "  Done: $extensionLabel" -ForegroundColor Green
                } catch {
                    Write-Warning "Could not install ${extensionLabel}: $_"
                }
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
                    if (Test-LegacyOhMyPoshPath -Path $env:POSH_PATH -ModuleBase @($availableOhMyPoshModule | ForEach-Object ModuleBase)) {
                        Remove-Item -LiteralPath $env:POSH_PATH -Force -Recurse -ErrorAction Stop
                        Write-Host "  Done: removed cached module files from `$env:POSH_PATH." -ForegroundColor Green
                    } else {
                        Write-Warning '  Skipped unsafe or unrecognized POSH_PATH; only a discovered legacy oh-my-posh module directory can be removed.'
                    }
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
        if ($pwshPreviewGuid) {
            if ($wt.PSObject.Properties['defaultProfile']) {
                $wt.defaultProfile = $pwshPreviewGuid
            }
            else {
                $wt | Add-Member -NotePropertyName 'defaultProfile' -NotePropertyValue $pwshPreviewGuid -Force
            }
            Write-Host "    Default profile set to $pwshPreviewGuid" -ForegroundColor Green
        }

        if (-not $wt.profiles) {
            $wt | Add-Member -NotePropertyName 'profiles' -NotePropertyValue ([PSCustomObject]@{ defaults = [PSCustomObject]@{} }) -Force
        }
        if (-not $wt.profiles.defaults) {
            $wt.profiles | Add-Member -NotePropertyName 'defaults' -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        $previewPath = Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe'
        if (Test-Path -LiteralPath $previewPath -PathType Leaf) {
            if (-not $wt.profiles) {
                $wt | Add-Member -NotePropertyName 'profiles' -NotePropertyValue ([PSCustomObject]@{}) -Force
            }
            if (-not $wt.profiles.PSObject.Properties['list']) {
                $wt.profiles | Add-Member -NotePropertyName 'list' -NotePropertyValue @() -Force
            }
            $previewProfile = $wt.profiles.list | Where-Object {
                $_.name -match 'Preview' -and $_.source -eq 'Windows.Terminal.PowershellCore'
            } | Select-Object -First 1
            if (-not $previewProfile) {
                $previewProfile = $wt.profiles.list | Where-Object {
                    $_.guid -eq '{0b446d97-a5ad-4b6d-8a01-d7b609521269}'
                } | Select-Object -First 1
            }
            if (-not $previewProfile) {
                $previewProfile = [PSCustomObject]@{
                    guid = '{0b446d97-a5ad-4b6d-8a01-d7b609521269}'
                    name = 'PowerShell Preview (altered-carbon)'
                    commandline = "`"$previewPath`""
                }
                $wt.profiles.list = @($wt.profiles.list) + $previewProfile
            }
            $wt | Add-Member -NotePropertyName 'defaultProfile' -NotePropertyValue $previewProfile.guid -Force
            Write-Host "    Default profile set to PowerShell Preview ($($previewProfile.guid))." -ForegroundColor Green
        } elseif (-not $pwshPreviewGuid) {
            Write-Warning "    PowerShell Preview was not found in $wtLabel or on disk; defaultProfile unchanged."
        }

        $fontObj = $wt.profiles.defaults.font
        if (-not $fontObj) { $fontObj = [PSCustomObject]@{} }
        $fontObj | Add-Member -NotePropertyName 'face' -NotePropertyValue $FontFaceName -Force
        if ($wt.profiles.defaults.PSObject.Properties['font']) {
            $wt.profiles.defaults.font = $fontObj
        }
        else {
            $wt.profiles.defaults | Add-Member -NotePropertyName 'font' -NotePropertyValue $fontObj -Force
        }

        $wt | ConvertTo-Json -Depth 100 | Set-Content $wtSettingsPath -Encoding UTF8
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
        Set-ItemProperty -Path $regPath -Name 'DelegationConsole'  -Value '{06EC847C-C0A5-46B8-92CB-7C92F6E35CD5}'
        Set-ItemProperty -Path $regPath -Name 'DelegationTerminal' -Value '{86633F1F-6454-40EC-89CE-DA4EBA977EE2}'
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

        $settings | ConvertTo-Json -Depth 100 | Set-Content $settingsPath -Encoding UTF8
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

function Get-DesktopAppVersion {
    param(
        [string] $Name,
        [string[]] $Publisher
    )

    $uninstallPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $app = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $Name -and $_.Publisher -in $Publisher } |
        Select-Object -First 1
    if ($app) {
        if ($app.DisplayVersion) { return $app.DisplayVersion }
        return 'installed (uninstall registration)'
    }
    return $null
}

function Write-VerificationLine {
    param(
        [string] $Label,
        [bool] $Installed,
        [string] $Details
    )

    if ($null -ne $script:verificationResults) {
        $script:verificationResults.Add([pscustomobject]@{
            Check = $Label.Trim()
            Status = if ($Installed) { 'OK' } else { 'MISSING / NOT VERIFIED' }
            Details = $Details
        })
    }

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

    $copilotVersion = Get-CommandVersion -Command 'copilot'
    Write-VerificationLine -Label 'GitHub Copilot CLI' -Installed ([bool]$copilotVersion) -Details $copilotVersion

    $copilotAppVersion = Get-DesktopAppVersion -Name 'GitHub Copilot' -Publisher @('GitHub Inc.', 'GitHub, Inc.')
    Write-VerificationLine -Label 'GitHub Copilot App (desktop)' -Installed ([bool]$copilotAppVersion) -Details $copilotAppVersion

    $squadVersion = Get-CommandVersion -Command 'squad'
    Write-VerificationLine -Label 'Squad CLI' -Installed ([bool]$squadVersion) -Details $squadVersion

    $podmanVersion = Get-CommandVersion -Command 'podman'
    Write-VerificationLine -Label 'Podman CLI' -Installed ([bool]$podmanVersion) -Details $podmanVersion

    $podmanDesktopVersion = Get-DesktopAppVersion -Name 'Podman Desktop' -Publisher @('Red Hat, Inc.', 'Red Hat')
    Write-VerificationLine -Label 'Podman Desktop' -Installed ([bool]$podmanDesktopVersion) -Details $podmanDesktopVersion

    $workIqVersion = Get-CommandVersion -Command 'workiq' -VersionArgs @('version')
    Write-VerificationLine -Label 'Microsoft Work IQ CLI' -Installed ([bool]$workIqVersion) -Details $workIqVersion

    $ompVersion = Get-CommandVersion -Command 'oh-my-posh'
    Write-VerificationLine -Label 'oh-my-posh' -Installed ([bool]$ompVersion) -Details $ompVersion

    $vsCodeVerification = @(
        @{ Editor = 'code'; Label = 'VS Code'; Extensions = @(
            @{ Id = 'github.copilot-chat'; Name = 'GitHub Copilot Chat' }
            @{ Id = 'ms-azuretools.vscode-azure-github-copilot'; Name = 'GitHub Copilot for Azure' }
            @{ Id = 'ms-windows-ai-studio.windows-ai-studio'; Name = 'AI Toolkit for Visual Studio Code' }
            @{ Id = 'ms-security.ms-sentinel'; Name = 'Microsoft Sentinel' }
        ) }
        @{ Editor = 'code-insiders'; Label = 'VS Code Insiders'; Extensions = @(
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

        Write-VerificationLine -Label $editorInfo.Label -Installed $true -Details 'CLI available'
        try {
            $installedExtensions = @(& $editorInfo.Editor --list-extensions 2>$null)
            if ($LASTEXITCODE -ne 0) { throw "extension listing exited with code $LASTEXITCODE" }
        } catch {
            Write-Warning "Could not verify extensions for $($editorInfo.Label): $_"
            Write-VerificationLine -Label "$($editorInfo.Label) extensions" -Installed $false -Details 'Extension listing failed; see transcript'
            continue
        }

        foreach ($extension in $editorInfo.Extensions) {
            $isInstalled = $installedExtensions -contains $extension.Id
            $details = $extension.Id
            if ($extension.Id -eq 'github.copilot-chat' -and -not $isInstalled) {
                $copilotDetails = Get-VSCodeCopilotDetails -Editor $editorInfo.Editor
                if ($copilotDetails) {
                    $isInstalled = $true
                    $details = $copilotDetails
                } else {
                    $details += "; not found or could not be verified. Check Extensions in $($editorInfo.Label); this is not Copilot CLI"
                }
            }
            Write-VerificationLine -Label ("  " + $extension.Name + " extension for " + $editorInfo.Label) -Installed $isInstalled -Details $details
        }
    }
}

function Write-SetupReport {
    param(
        [string] $Phase,
        [string] $TranscriptPath,
        [string] $FailureMessage,
        [object[]] $Results = @()
    )

    $reportDir = Join-Path $env:LOCALAPPDATA 'altered-carbon\reports'
    $null = New-Item -Path $reportDir -ItemType Directory -Force -ErrorAction Stop
    $reportPath = Join-Path $reportDir ("{0}-{1}.html" -f [System.IO.Path]::GetFileNameWithoutExtension($TranscriptPath), $Phase)
    $status = if ($FailureMessage) { 'Failed / incomplete' } else { 'Completed' }
    $encodedPhase = [System.Net.WebUtility]::HtmlEncode($Phase)
    $encodedLog = [System.Net.WebUtility]::HtmlEncode($TranscriptPath)
    $encodedFailure = [System.Net.WebUtility]::HtmlEncode($FailureMessage)
    $checks = if ($Results.Count) {
        ($Results | Select-Object Check, Status, Details | ConvertTo-Html -Fragment) -join "`n"
    } else {
        '<p>No verification results were collected. Configuration may not have started or completed.</p>'
    }
    $failure = if ($FailureMessage) {
        "<h2>Failure</h2><pre>$encodedFailure</pre><p>Resolve the error, then retry manually in a non-elevated shell with -Work or -Personal and -Phase Phase2, without -ResumeToken. For Phase1 failures, retry Phase1 as administrator instead.</p>"
    } else { '' }
    $html = @"
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>altered-carbon $encodedPhase — $status</title>
        <script>
        (() => {
          const param = new URLSearchParams(window.location.search).get("scoutTheme");
          const theme = param || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
          document.documentElement.setAttribute("data-theme", theme);
        })();
        </script>
        <style>
        :root {
          color-scheme: light;
          --cp-bg: #f7f4ef;
          --cp-bg-elevated: #fcfbf8;
          --cp-surface: #ffffff;
          --cp-surface-soft: #f5f5f5;
          --cp-border: #dedede;
          --cp-border-strong: #919191;
          --cp-text: #242424;
          --cp-text-muted: #5c5c5c;
          --cp-text-soft: #6f6f6f;
          --cp-accent: #b11f4b;
          --cp-accent-hover: #9a1a41;
          --cp-accent-soft: rgba(177, 31, 75, 0.08);
          --cp-accent-fg: #ffffff;
          --cp-success: #16a34a;
          --cp-danger: #dc2626;
          --cp-warning: #f59e0b;
          --cp-link: #0078d4;
          --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.12);
          --cp-overlay: rgba(255, 255, 255, 0.8);
          --cp-panel: rgba(255, 255, 255, 0.86);
          --cp-panel-strong: rgba(255, 255, 255, 0.96);
          --cp-sheen: rgba(255, 255, 255, 0.55);
          --cp-highlight: rgba(177, 31, 75, 0.12);
        }
        html[data-theme="dark"] {
          color-scheme: dark;
          --cp-bg: #3d3b3a;
          --cp-bg-elevated: #343231;
          --cp-surface: #292929;
          --cp-surface-soft: #2e2e2e;
          --cp-border: #474747;
          --cp-border-strong: #5f5f5f;
          --cp-text: #dedede;
          --cp-text-muted: #919191;
          --cp-text-soft: #b0b0b0;
          --cp-accent: #fd8ea1;
          --cp-accent-hover: #fb7b91;
          --cp-accent-soft: rgba(253, 142, 161, 0.14);
          --cp-accent-fg: #1a1a1a;
          --cp-success: #4ade80;
          --cp-danger: #f87171;
          --cp-warning: #fbbf24;
          --cp-link: #4da6ff;
          --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.32);
          --cp-overlay: rgba(41, 41, 41, 0.88);
          --cp-panel: rgba(41, 41, 41, 0.72);
          --cp-panel-strong: rgba(41, 41, 41, 0.96);
          --cp-sheen: rgba(255, 255, 255, 0.04);
          --cp-highlight: rgba(253, 142, 161, 0.12);
        }
        body { margin: 0; padding: 32px; background: var(--cp-bg); color: var(--cp-text); font-family: "Segoe UI", Aptos, Calibri, -apple-system, BlinkMacSystemFont, sans-serif; }
        main { max-width: 1080px; margin: auto; padding: 24px; border: 1px solid var(--cp-border); border-radius: 16px; background: var(--cp-surface); }
        h1, h2 { color: var(--cp-accent); }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid var(--cp-border); padding: 8px; text-align: left; overflow-wrap: anywhere; }
        pre, code { font-family: Consolas, "Courier New", Courier, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
        </style></head><body><main>
        <h1>altered-carbon: $encodedPhase</h1><h2>$status</h2>
        <p>Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'). Completed means orchestration reached the end, not that every optional installation succeeded. Review missing checks and transcript warnings.</p>
        $failure
        <h2>Verification (presence only)</h2>$checks
        <h2>Transcript</h2><p><code>$encodedLog</code></p>
        <p>The transcript contains installation output and warnings. If transcript startup failed, this path may not exist. This local report may contain personal paths; review before sharing.</p>
        </main></body></html>
"@
    Set-Content -LiteralPath $reportPath -Value $html -Encoding UTF8 -ErrorAction Stop
    return $reportPath
}

function Open-SetupReport {
    param([string] $Path)

    Write-Host "Setup report saved: $Path" -ForegroundColor Cyan
    try {
        Start-Process -FilePath $Path -ErrorAction Stop | Out-Null
        Write-Host 'Report open requested in your default browser; if no page appears, open the saved path manually.' -ForegroundColor Cyan
    } catch {
        Write-Warning "Could not open the setup report. Open '$Path' manually. Details: $_"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# ── Main Orchestration ────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

$script:verificationResults = [System.Collections.Generic.List[object]]::new()
$runFailure = $null
try {
if ($Phase -eq 'Phase1' -and -not $isAdmin) {
    throw 'Phase1 requires an elevated shell. Run this script as Administrator with -Work or -Personal.'
}
# Retire the logon trigger before any initialization/configuration can fail.
if ($Phase -eq 'Phase2') {
    $resumeAllowed = $true
    try {
        if ($ResumeToken -ne [guid]::Empty) {
            $resumeAllowed = Enter-Phase2Resume -Token $ResumeToken
        }
    } finally {
        Remove-Phase2Task -TaskName $taskName
    }
    if (-not $resumeAllowed) {
        throw 'This scheduled Phase 2 attempt has already been consumed. Retry manually with -Work or -Personal and -Phase Phase2 (without -ResumeToken).'
    }
}

if ($Phase -eq 'Phase2' -and $isAdmin) {
    throw 'Phase2 must run in a non-elevated shell for user-space installers and configuration.'
}
if ($Phase -eq 'Phase2' -and $PSVersionTable.PSVersion -lt [version]'7.6') {
    throw 'Phase2 requires PowerShell 7.6 or newer for current Microsoft365DSC and PnP.PowerShell modules. Update Microsoft.PowerShell, then retry Phase2 from pwsh.'
}

# Shared init (idempotent, both phases)
$psModuleDir = Initialize-PSModulePath
$profileInfo = Initialize-PSProfileDir
$psProfileDir  = $profileInfo.Dir
$psProfileFile = $profileInfo.File

Test-WingetAvailable

if ($Phase -eq 'Phase1') {
    # ── Phase 1: Admin installs + Windows features + schedule Phase 2 ────────

    # Clean up any leftover Phase 2 scheduled task from a previous run
    Remove-Phase2Task -TaskName $taskName

    $phase2Skips = @($SkipPackages)
    # Spotify requires non-admin install — skip in Phase 1
    $SkipPackages += 'Spotify.Spotify'
    Install-WingetPackages -Personal $Personal.IsPresent -SkipPackages $SkipPackages -ExtraPackages $ExtraPackages -AppInUseExitCode $WINGET_APP_IN_USE -NoApplicableUpgradeExitCode $WINGET_NO_APPLICABLE_UPGRADE -PackageNotFoundExitCode $WINGET_PACKAGE_NOT_FOUND -UpgradeVersionNotNewerExitCode $WINGET_UPGRADE_VERSION_NOT_NEWER
    Enable-WindowsFeatures -IsAdmin $isAdmin
    Install-NvidiaApp -AppInUseExitCode $WINGET_APP_IN_USE
    Install-CudaToolkit -SkipPackages $SkipPackages
    Update-PathFromRegistry

    # Register Phase 2 scheduled task (runs at logon as current user, non-elevated)
    $scriptPath = $MyInvocation.MyCommand.Path
    if ($scriptPath -and ($Work.IsPresent -or $Personal.IsPresent)) {
        $pwshPath   = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if (-not $pwshPath) { throw 'PowerShell 7 is required to resume Phase2. Install Microsoft.PowerShell, then rerun Phase1.' }
        $resumeId  = [guid]::NewGuid()
        $resumeArguments = Get-Phase2TaskArguments -ScriptPath $scriptPath -Personal $Personal.IsPresent -ThemeName $OmpTheme -FontName $NerdFont -SkipPackages $phase2Skips -Token $resumeId
        $action    = New-ScheduledTaskAction -Execute $pwshPath -Argument $resumeArguments
        $userSid   = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $trigger   = New-ScheduledTaskTrigger -AtLogon -User $userSid
        $principal = New-ScheduledTaskPrincipal -UserId $userSid -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        try {
            Grant-Phase2TaskAccess -TaskName $taskName -UserSid $userSid
        } catch {
            $accessError = $_
            Remove-Phase2Task -TaskName $taskName
            throw "Could not grant the Phase 2 user permission to retire its scheduled task: $accessError"
        }
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
    if ($Work.IsPresent) {
        Set-WorkNpmRegistry
        Install-Agency
    }
    Update-PathFromRegistry
    Install-FoundryLocal -SkipPackages $SkipPackages
    Install-WorkIqCli

    # Install Spotify (requires non-admin)
    if ('Spotify.Spotify' -notin $SkipPackages) {
    Write-Host 'Installing Spotify (user-space)...' -ForegroundColor Cyan
    $spotifyOutput = winget install --id 'Spotify.Spotify' --source winget --accept-source-agreements --accept-package-agreements --silent 2>&1 | ForEach-Object { $_.ToString() }
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  Done: Spotify installed.' -ForegroundColor Green
    } elseif ($LASTEXITCODE -eq $WINGET_APP_IN_USE) {
        Write-Host '  Skipped: Spotify already running.' -ForegroundColor Yellow
    } elseif ($LASTEXITCODE -eq $WINGET_PACKAGE_ALREADY_INSTALLED) {
        Write-Host '  Skipped: Spotify is already installed.' -ForegroundColor Yellow
    } elseif ($LASTEXITCODE -eq $WINGET_NO_APPLICABLE_UPGRADE) {
        Write-Host '  Skipped: Spotify is already up to date.' -ForegroundColor Yellow
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
    }

    $fontInfo = Install-NerdFont -FontName $NerdFont
    $fontFace     = $fontInfo.Face
    $fontFaceMono = $fontInfo.Mono

    if ($Work.IsPresent) {
        Install-AzArtifactsCredentialProvider
    }
    $psRepository = Initialize-PSModuleRepository -Work:$Work.IsPresent
    if ($Personal.IsPresent) {
        Set-PSGalleryTrust
    }
    Install-PSModules -ModuleDir $psModuleDir -Repository $psRepository
    Install-VSCodeExtensions
    Set-OhMyPoshProfile -ThemeName $OmpTheme -ProfileDir $psProfileDir -ProfileFile $psProfileFile
    Set-WindowsTerminalConfig -FontFaceName $fontFace
    Set-DefaultTerminal
    Set-VSCodeFont -FontFaceMonoName $fontFaceMono
    Set-FileExplorerOptions
    Show-VerificationSummary

}

} catch {
    $runFailure = $_
    Write-Warning "$Phase failed: $($_.Exception.Message)"
    Write-Warning "See transcript: $logFile"
} finally {
    try {
        if ($Phase -eq 'Phase2' -or $runFailure) {
            try {
                $failureMessage = if ($runFailure) { $runFailure.Exception.Message } else { '' }
                $reportPath = Write-SetupReport -Phase $Phase -TranscriptPath $logFile -FailureMessage $failureMessage -Results @($script:verificationResults.ToArray())
                Open-SetupReport -Path $reportPath
                if (-not $runFailure) {
                    Write-Host "`nSetup complete. Review the report and transcript for warnings." -ForegroundColor Green
                }
            } catch {
                Write-Warning "Could not save the setup report: $_. See transcript: $logFile"
                if (-not $runFailure) { $runFailure = $_ }
            }
        }
    } finally {
        try { Stop-Transcript } catch { Write-Verbose "Transcript was not active: $($_.Exception.Message)" }
    }
}

if ($runFailure) { throw $runFailure }
