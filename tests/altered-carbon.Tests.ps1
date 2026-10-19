# altered-carbon.Tests.ps1 — Pester 5 tests for altered-carbon.ps1
# These tests validate logic without executing any actual installs.

BeforeAll {
    # Parse the script's AST to extract functions without executing side effects.
    $scriptPath = Join-Path $PSScriptRoot '..' 'altered-carbon.ps1'
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errors)

    # Dot-source only the function definitions by extracting them from the AST.
    $functionDefs = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($fn in $functionDefs) {
        Invoke-Expression $fn.Extent.Text
    }

    if (-not (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue)) {
        function global:Get-WindowsOptionalFeature { param([string] $FeatureName) }
    }
    if (-not (Get-Command Enable-WindowsOptionalFeature -ErrorAction SilentlyContinue)) {
        function global:Enable-WindowsOptionalFeature { param([string] $FeatureName) }
    }
    if (-not (Get-Command Get-InstalledModule -ErrorAction SilentlyContinue)) {
        function global:Get-InstalledModule { param([string] $Name) }
    }

    # Also extract key data structures (package arrays) by evaluating variable assignments.
    # We'll parse them manually from the script content for test assertions.
    $scriptContent = Get-Content $scriptPath -Raw
    $wingetConstants = @{}
    [regex]::Matches($scriptContent, '(?m)^\$(WINGET_[A-Z_]+)\s*=\s*(-?\d+)') | ForEach-Object {
        $wingetConstants[$_.Groups[1].Value] = [int64]$_.Groups[2].Value
    }
}

Describe 'Script Parse Validation' {
    It 'parses without syntax errors' {
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot '..' 'altered-carbon.ps1'),
            [ref]$null,
            [ref]$parseErrors
        )
        $parseErrors.Count | Should -Be 0
    }

    It 'has a param block with CmdletBinding' {
        $ast.ParamBlock | Should -Not -BeNullOrEmpty
        $cmdletBinding = $ast.ParamBlock.Attributes | Where-Object {
            $_ -is [System.Management.Automation.Language.AttributeAst] -and
            $_.TypeName.Name -eq 'CmdletBinding'
        }
        $cmdletBinding | Should -Not -BeNullOrEmpty
    }

    It 'defines Work and Personal parameter sets' {
        $paramSets = $ast.ParamBlock.Parameters | ForEach-Object {
            $_.Attributes | Where-Object {
                $_ -is [System.Management.Automation.Language.AttributeAst] -and
                $_.TypeName.Name -eq 'Parameter'
            }
        } | ForEach-Object {
            $_.NamedArguments | Where-Object { $_.ArgumentName -eq 'ParameterSetName' }
        } | ForEach-Object { $_.Argument.Value }

        $paramSets | Should -Contain 'Work'
        $paramSets | Should -Contain 'Personal'
    }

    It 'sets ErrorActionPreference to Stop' {
        $scriptContent | Should -Match '\$ErrorActionPreference\s*=\s*[''"]Stop[''"]'
    }
}

Describe 'Get-WingetVersionInfo' {
    Context 'with valid winget list output' {
        It 'extracts installed version from standard output' {
            $lines = @(
                'Name                   Id                  Version    Available  Source'
                '----------------------------------------------------------------------'
                'PowerShell 7           Microsoft.PowerShell 7.4.1     7.4.2      winget'
            )

            $result = Get-WingetVersionInfo -Lines $lines -PackageId 'Microsoft.PowerShell'
            $result | Should -Not -BeNullOrEmpty
            $result.Version | Should -Be '7.4.1'
            $result.Available | Should -Be '7.4.2'
        }

        It 'returns null when package not found' {
            $lines = @(
                'Name                   Id                  Version    Source'
                '------------------------------------------------------------'
                'PowerShell 7           Microsoft.PowerShell 7.4.1     winget'
            )

            $result = Get-WingetVersionInfo -Lines $lines -PackageId 'Nonexistent.Package'
            $result | Should -BeNullOrEmpty
        }

        It 'returns null when no header line present' {
            $lines = @(
                'No installed package found matching input criteria.'
            )

            $result = Get-WingetVersionInfo -Lines $lines -PackageId 'Microsoft.PowerShell'
            $result | Should -BeNullOrEmpty
        }

        It 'handles output without Available column' {
            $lines = @(
                'Name                   Id                  Version    Source'
                '------------------------------------------------------------'
                'PowerShell 7           Microsoft.PowerShell 7.4.2     winget'
            )

            $result = Get-WingetVersionInfo -Lines $lines -PackageId 'Microsoft.PowerShell'
            $result | Should -Not -BeNullOrEmpty
            $result.Version | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-CommandVersion' {
    It 'returns null when command does not exist' {
        $result = Get-CommandVersion -Command 'nonexistent-command-xyz-12345'
        $result | Should -BeNullOrEmpty
    }

    It 'returns a version string for pwsh' {
        $result = Get-CommandVersion -Command 'pwsh'
        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match '\d'
    }
}

Describe 'Winget constants' {
    It 'defines the expected exit code constants' {
        $wingetConstants.Keys | Should -Contain 'WINGET_NO_APPLICABLE_UPGRADE'
        $wingetConstants.Keys | Should -Contain 'WINGET_PACKAGE_NOT_FOUND'
        $wingetConstants.Keys | Should -Contain 'WINGET_APP_IN_USE'
        $wingetConstants.Keys | Should -Contain 'WINGET_UPGRADE_VERSION_NOT_NEWER'
        $wingetConstants.Keys | Should -Contain 'WINGET_SHELLEXEC_INSTALL_FAILED'
    }

    It 'assigns the correct exit code values' {
        $wingetConstants.WINGET_NO_APPLICABLE_UPGRADE | Should -Be -1978335189
        $wingetConstants.WINGET_PACKAGE_NOT_FOUND | Should -Be -1978335212
        $wingetConstants.WINGET_APP_IN_USE | Should -Be -1978335113
        $wingetConstants.WINGET_UPGRADE_VERSION_NOT_NEWER | Should -Be -1978335153
        $wingetConstants.WINGET_SHELLEXEC_INSTALL_FAILED | Should -Be -1978335226
    }
}

Describe 'Test-WingetKnownVersion' {
    It 'returns true for real version strings' -TestCases @(
        @{ Version = '1.2.3' }
        @{ Version = '7.4.2' }
        @{ Version = '2026.5.1-preview' }
    ) {
        param($Version)

        Test-WingetKnownVersion -Version $Version | Should -BeTrue
    }

    It 'returns false for null, blank, whitespace, and Unknown values' -TestCases @(
        @{ Version = $null; Label = 'null' }
        @{ Version = ''; Label = 'empty string' }
        @{ Version = '   '; Label = 'whitespace' }
        @{ Version = 'Unknown'; Label = 'Unknown' }
    ) {
        param($Version, $Label)

        Test-WingetKnownVersion -Version $Version | Should -BeFalse -Because "$Label should not count as a known version"
    }
}

Describe 'Compare-WingetVersions' {
    It 'returns -1 when the available version is newer' {
        Compare-WingetVersions -InstalledVersion '1.2.3' -AvailableVersion '1.2.4' | Should -Be -1
    }

    It 'returns 0 for equivalent numeric versions with different segment lengths' {
        Compare-WingetVersions -InstalledVersion '1.2' -AvailableVersion '1.2.0' | Should -Be 0
    }

    It 'returns 1 when the installed version is newer than the available version' {
        Compare-WingetVersions -InstalledVersion '2.0.0' -AvailableVersion '1.9.9' | Should -Be 1
    }

    It 'returns null when either version is unknown' {
        Compare-WingetVersions -InstalledVersion 'Unknown' -AvailableVersion '1.0.0' | Should -BeNullOrEmpty
    }
}

Describe 'Write-VerificationLine' {
    It 'runs without error for installed=true' {
        { Write-VerificationLine -Label 'test' -Installed $true -Details 'v1.0' } | Should -Not -Throw
    }

    It 'runs without error for installed=false' {
        { Write-VerificationLine -Label 'test' -Installed $false -Details '' } | Should -Not -Throw
    }
}

Describe 'Package Data Integrity' {
    BeforeAll {
        # Extract all package IDs from the script using regex (skip comment-only lines)
        $codeLines = (Get-Content (Join-Path $PSScriptRoot '..' 'altered-carbon.ps1')) |
            Where-Object { $_ -notmatch '^\s*#' }
        $codeContent = $codeLines -join "`n"
        $allIds = [regex]::Matches($codeContent, "Id\s*=\s*'([^']+)'") |
            ForEach-Object { $_.Groups[1].Value }
    }

    It 'has at least 15 core package IDs' {
        # corePackages should have a substantial number of entries
        $allIds.Count | Should -BeGreaterThan 15
    }

    It 'includes expected critical packages' {
        $allIds | Should -Contain 'Microsoft.VisualStudioCode'
        $allIds | Should -Contain 'Microsoft.WindowsTerminal.Preview'
        $allIds | Should -Contain 'Microsoft.PowerShell'
        $allIds | Should -Contain 'GitHub.cli'
        $allIds | Should -Contain 'JanDeDobbeleer.OhMyPosh'
        $allIds | Should -Contain 'Git.Git'
    }

    It 'includes the updated personal package IDs and excludes delisted apps from package IDs' {
        $allIds | Should -Contain 'PrivateInternetAccess.PrivateInternetAccess'
        $allIds | Should -Contain 'ElementLabs.LMStudio'
        $scriptContent | Should -Match 'Adobe Lightroom is installed through Creative Cloud'
        $scriptContent | Should -Match 'Xbox app is not currently discoverable'
    }

    It 'defines a custom install location for Blizzard Battle.net' {
        $scriptContent | Should -Match "Id\s*=\s*'Blizzard\.BattleNet'.*Location\s*=\s*'C:\\Program Files \(x86\)\\Battle\.net'"
    }

    It 'has no duplicate package IDs within the same list' {
        # Count occurrences — some IDs appear in multiple contexts (choco fallback, etc.)
        # but within corePackages/personalPackages each should be unique.
        # We check for exact triple+ duplicates as a signal of copy-paste errors.
        $grouped = $allIds | Group-Object | Where-Object { $_.Count -gt 3 }
        $grouped | Should -BeNullOrEmpty -Because "No package ID should appear more than 3 times (core + personal + skip logic)"
    }

    It 'all IDs follow expected identifier formats' {
        foreach ($id in $allIds) {
            # winget: Publisher.Package (e.g. Microsoft.PowerShell)
            # MS Store: alphanumeric 9-14 chars (e.g. 9N1F85V9T8BN)
            # Chocolatey: lowercase with hyphens (e.g. nodejs-lts)
            # VS Code extensions: publisher.extension-name (e.g. github.copilot-chat)
            $valid = ($id -match '^[A-Za-z0-9][\w\-]*(\.[A-Za-z0-9][\w\.\-]*)+$') -or
                     ($id -match '^[A-Za-z0-9]{9,14}$') -or
                     ($id -match '^[a-z0-9][\w\-]*$')
            $valid | Should -BeTrue -Because "ID '$id' should be a valid package or extension identifier"
        }
    }
}

Describe 'Script Structure' {
    It 'defines expected helper functions' {
        $fnNames = $functionDefs | ForEach-Object { $_.Name }
        $fnNames | Should -Contain 'Get-WingetVersionInfo'
        $fnNames | Should -Contain 'Compare-WingetVersions'
        $fnNames | Should -Contain 'Stop-WingetUpgradeProcess'
        $fnNames | Should -Contain 'Invoke-ElevatedFontPromotion'
        $fnNames | Should -Contain 'Enter-Phase2Resume'
        $fnNames | Should -Contain 'Remove-Phase2Task'
        $fnNames | Should -Contain 'Grant-Phase2TaskAccess'
        $fnNames | Should -Contain 'Test-LegacyOhMyPoshPath'
        $fnNames | Should -Contain 'Get-CommandVersion'
        $fnNames | Should -Contain 'Set-OhMyPoshProfile'
        $fnNames | Should -Contain 'Write-VerificationLine'
    }

    It 'checks for admin status early in the script' {
        $scriptContent | Should -Match 'WindowsPrincipal.*WindowsIdentity.*GetCurrent'
    }

    It 'checks for winget availability' {
        $scriptContent | Should -Match 'Get-Command\s+winget'
    }

    It 'handles non-admin Chocolatey gracefully' {
        $scriptContent | Should -Match 'Chocolatey requires admin'
    }

    It 'marks Active Directory as an RSAT-provided module' {
        $scriptContent | Should -Match "(?s)Name = 'ActiveDirectory'.*?Source = 'RSAT'"
    }

    It 'does not include retired PowerShell modules or the retired gh-copilot extension' {
        $scriptContent | Should -Not -Match "Name = 'Microsoft\.Graph\.Intune'"
        $scriptContent | Should -Not -Match "Name = 'AzSentinel'"
        $scriptContent | Should -Not -Match "Name = 'MSAL\.PS'"
        $scriptContent | Should -Not -Match "Name = 'PSKusto'"
        $scriptContent | Should -Not -Match 'github/gh-copilot'
    }

    It 'uses the current oh-my-posh font install syntax' {
        $scriptContent | Should -Not -Match 'oh-my-posh font install[^\r\n]*--user'
    }

    It 'handles Spotify ShellExecute install failures explicitly' {
        $scriptContent | Should -Match '\$LASTEXITCODE -eq \$WINGET_SHELLEXEC_INSTALL_FAILED'
        $scriptContent | Should -Match 'ShellExecute failed'
    }

    It 'defines a pre-upgrade process stop map for LM Studio' {
        $scriptContent | Should -Match "'ElementLabs\.LMStudio'\s*=\s*@\('LM Studio'\)"
        $scriptContent | Should -Match 'Stop-WingetUpgradeProcess\s+-Package\s+\$pkg\s+-PackageProcessMap\s+\$upgradeProcessMap'
    }
}

Describe 'Package List Logic' {
    # These tests validate the skip/extra logic by examining the script patterns
    It 'filters packages using SkipPackages parameter' {
        $scriptContent | Should -Match '\$SkipPackages'
        $scriptContent | Should -Match '-notin\s+\$SkipPackages'
    }

    It 'appends ExtraPackages to the install list' {
        $scriptContent | Should -Match '\$ExtraPackages'
        $scriptContent | Should -Match '\$wingetPackages\s*\+=\s*\$ExtraPackages'
    }

    It 'adds personal packages only in Personal mode' {
        $scriptContent | Should -Match 'if\s*\(\$Personal\)\s*\{[^}]*\$wingetPackages\s*\+=\s*\$personalPackages'
    }
}

Describe 'Install-WingetPackages' {
    BeforeEach {
        $script:corePackages = @()
        $script:personalPackages = @()
        $script:wingetCalls = [System.Collections.Generic.List[object[]]]::new()
        $script:wingetResponses = [System.Collections.Generic.Queue[hashtable]]::new()

        function global:winget {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]] $Args)

            $script:wingetCalls.Add(@($Args))
            if ($script:wingetResponses.Count -eq 0) {
                throw "Unexpected winget invocation: $($Args -join ' ')"
            }

            $response = $script:wingetResponses.Dequeue()
            $global:LASTEXITCODE = $response.ExitCode

            foreach ($line in $response.Output) {
                $line
            }
        }
    }

    AfterEach {
        Remove-Item function:\global:winget -ErrorAction SilentlyContinue
    }

    It 'treats no-applicable-upgrade as success without falling back to install' {
        $script:corePackages = @(
            @{ Id = 'Contoso.App'; Name = 'Contoso App'; Source = 'winget' }
        )

        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @(
                    'Name                   Id           Version    Available  Source'
                    '----------------------------------------------------------------'
                    'Contoso App            Contoso.App  1.0.0      1.0.0      winget'
                )
            })
        $script:wingetResponses.Enqueue(@{
                ExitCode = -1978335189
                Output   = @()
            })

        Install-WingetPackages -Personal $false -AppInUseExitCode -1978335113 -NoApplicableUpgradeExitCode -1978335189 -PackageNotFoundExitCode -1978335212

        @($script:wingetCalls | Where-Object { $_[0] -eq 'upgrade' }).Count | Should -Be 1
        @($script:wingetCalls | Where-Object { $_[0] -eq 'install' }).Count | Should -Be 0
    }

    It 'falls back from upgrade to install when winget cannot map a package for upgrade' {
        $script:corePackages = @(
            @{ Id = 'Contoso.App'; Name = 'Contoso App'; Source = 'winget' }
        )

        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @(
                    'Name                   Id           Version    Available  Source'
                    '----------------------------------------------------------------'
                    'Contoso App            Contoso.App  1.0.0      2.0.0      winget'
                )
            })
        $script:wingetResponses.Enqueue(@{
                ExitCode = -1978335212
                Output   = @()
            })
        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @()
            })

        Install-WingetPackages -Personal $false -AppInUseExitCode -1978335113 -NoApplicableUpgradeExitCode -1978335189 -PackageNotFoundExitCode -1978335212

        @($script:wingetCalls | Where-Object { $_[0] -eq 'upgrade' }).Count | Should -Be 1
        @($script:wingetCalls | Where-Object { $_[0] -eq 'install' }).Count | Should -Be 1
    }

    It 'warns clearly when install also returns package-not-found' {
        Mock Write-Warning {}
        $script:corePackages = @(
            @{ Id = 'Contoso.App'; Name = 'Contoso App'; Source = 'winget' }
        )

        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @(
                    'Name                   Id           Version    Available  Source'
                    '----------------------------------------------------------------'
                    'Contoso App            Contoso.App  1.0.0      2.0.0      winget'
                )
            })
        $script:wingetResponses.Enqueue(@{
                ExitCode = -1978335212
                Output   = @()
            })
        $script:wingetResponses.Enqueue(@{
                ExitCode = -1978335212
                Output   = @()
            })

        Install-WingetPackages -Personal $false -AppInUseExitCode -1978335113 -NoApplicableUpgradeExitCode -1978335189 -PackageNotFoundExitCode -1978335212

        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -like '*not available from the configured sources*'
        }
    }

    It 'passes package location through to winget install arguments' {
        Mock Test-Path { $false } -ParameterFilter { $Path -eq 'C:\Program Files (x86)\Battle.net' }

        $script:corePackages = @(
            @{ Id = 'Blizzard.BattleNet'; Name = 'Battle.net'; Source = 'winget'; Location = 'C:\Program Files (x86)\Battle.net' }
        )

        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @('No installed package found matching input criteria.')
            })
        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @('No installed package found matching input criteria.')
            })
        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @('No package found matching input criteria.')
            })
        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @()
            })

        Install-WingetPackages -Personal $false -AppInUseExitCode -1978335113 -NoApplicableUpgradeExitCode -1978335189 -PackageNotFoundExitCode -1978335212

        $installArgs = $script:wingetCalls | Where-Object { $_[0] -eq 'install' } | Select-Object -First 1
        $installArgs | Should -Contain '--location'
        $installArgs | Should -Contain 'C:\Program Files (x86)\Battle.net'
    }

    It 'detects installed package via Location path when winget cannot find it' {
        Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\Program Files (x86)\Battle.net' }

        $script:corePackages = @(
            @{ Id = 'Blizzard.BattleNet'; Name = 'Battle.net'; Source = 'winget'; Location = 'C:\Program Files (x86)\Battle.net' }
        )

        # winget list --id returns nothing
        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @('No installed package found matching input criteria.')
            })
        # winget list --name returns nothing
        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @('No installed package found matching input criteria.')
            })
        # winget search (for latest version) returns nothing
        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @('No package found matching input criteria.')
            })
        # winget upgrade (since detected as installed)
        $script:wingetResponses.Enqueue(@{
                ExitCode = -1978335189
                Output   = @()
            })

        Install-WingetPackages -Personal $false -AppInUseExitCode -1978335113 -NoApplicableUpgradeExitCode -1978335189 -PackageNotFoundExitCode -1978335212

        # Should attempt upgrade (not install) since it was detected via filesystem
        @($script:wingetCalls | Where-Object { $_[0] -eq 'upgrade' }).Count | Should -Be 1
        @($script:wingetCalls | Where-Object { $_[0] -eq 'install' }).Count | Should -Be 0
    }

    It 'skips upgrade attempts when the installed version is newer than the catalog version' {
        Mock Write-Host {}
        $script:corePackages = @(
            @{ Id = 'Contoso.App'; Name = 'Contoso App'; Source = 'winget' }
        )

        $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output   = @(
                    'Name                   Id           Version    Available  Source'
                    '----------------------------------------------------------------'
                    'Contoso App            Contoso.App  2.0.0      1.5.0      winget'
                )
            })

        Install-WingetPackages -Personal $false -AppInUseExitCode -1978335113 -NoApplicableUpgradeExitCode -1978335189 -PackageNotFoundExitCode -1978335212

        $script:wingetCalls.Count | Should -Be 1
        @($script:wingetCalls | Where-Object { $_[0] -eq 'upgrade' }).Count | Should -Be 0
        @($script:wingetCalls | Where-Object { $_[0] -eq 'install' }).Count | Should -Be 0
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -like '*installed version (2.0.0) is newer than available (1.5.0)*'
        }
    }
}

Describe 'Stop-WingetUpgradeProcess' {
    It 'stops mapped running processes and waits before upgrade' {
        Mock Get-Process { [pscustomobject]@{ Id = 4242; ProcessName = 'LM Studio' } } -ParameterFilter { $Name -eq 'LM Studio' }
        Mock Stop-Process {}
        Mock Start-Sleep {}
        Mock Write-Host {}

        Stop-WingetUpgradeProcess -Package @{ Id = 'ElementLabs.LMStudio'; Name = 'LM Studio' } -PackageProcessMap @{
            'ElementLabs.LMStudio' = @('LM Studio')
        }

        Should -Invoke Get-Process -Times 1 -Exactly -ParameterFilter { $Name -eq 'LM Studio' }
        Should -Invoke Stop-Process -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 3 }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -like '*Stopping running process(es) before upgrade: LM Studio.*'
        }
    }

    It 'does nothing when the package is not in the stop map' {
        Mock Get-Process {}
        Mock Stop-Process {}
        Mock Start-Sleep {}

        Stop-WingetUpgradeProcess -Package @{ Id = 'Contoso.App'; Name = 'Contoso App' } -PackageProcessMap @{
            'ElementLabs.LMStudio' = @('LM Studio')
        }

        Should -Invoke Get-Process -Times 0 -Exactly
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}

Describe 'Enable-WindowsFeatures' {
    It 'skips gracefully when optional feature management is unavailable' {
        Mock Get-WindowsOptionalFeature {
            throw [System.InvalidOperationException]::new('Class not registered')
        }
        Mock Enable-WindowsOptionalFeature {}
        Mock Write-Warning {}

        Enable-WindowsFeatures -IsAdmin $true

        Should -Invoke Get-WindowsOptionalFeature -Times 1 -Exactly
        Should -Invoke Enable-WindowsOptionalFeature -Times 0 -Exactly
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -like '*feature management is unavailable*'
        }
    }
}

Describe 'Work-only npm registry and Agency' -Tag 'WorkTools' {
    BeforeAll {
        function npm { param([Parameter(ValueFromRemainingArguments)] [string[]]$Arguments) throw 'Unmocked npm invocation' }
        function pwsh { param([Parameter(ValueFromRemainingArguments)] [string[]]$Arguments) throw 'Unmocked installer invocation' }
        $agencyPath = Join-Path $env:APPDATA 'agency\CurrentVersion\agency.exe'
        $workGuard = $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$Work.IsPresent' -and
            $node.Extent.Text -match '\bSet-WorkNpmRegistry\b'
        }, $true)
        $workGuard.Count | Should -Be 1
        $runWorkGuard = [scriptblock]::Create($workGuard.Extent.Text)
    }

    BeforeEach {
        $script:npmRegistry = 'https://registry.npmjs.org/'
        $script:npmReadStatus = 0
        $script:npmWriteStatus = 0
        $script:agencyInstalled = $false
        Mock Write-Host {}
        Mock Get-Command { [pscustomobject]@{ Name = 'npm' } } -ParameterFilter { $Name -eq 'npm' }
        Mock Get-Command {
            if ($script:agencyInstalled) { [pscustomobject]@{ Name = 'agency' } }
        } -ParameterFilter { $Name -eq 'agency' }
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq $agencyPath }
        Mock Update-PathFromRegistry {}
        Mock Invoke-RestMethod { throw 'Network access must remain inside the mocked installer process' }
        Mock npm {
            if ($Arguments[1] -eq 'get') {
                $global:LASTEXITCODE = $script:npmReadStatus
                $script:npmRegistry
            } elseif ($Arguments[1] -eq 'set') {
                $global:LASTEXITCODE = $script:npmWriteStatus
                if ($script:npmWriteStatus -eq 0) { $script:npmRegistry = $Arguments[3] }
            } else {
                throw "Unexpected npm invocation: $Arguments"
            }
        }
        Mock pwsh { $global:LASTEXITCODE = 0; $script:agencyInstalled = $true }
    }

    It 'gates both operations to Work in Phase 2, not Personal' {
        $phaseBranch = $workGuard.Parent.Parent
        $phaseBranch | Should -BeOfType ([System.Management.Automation.Language.IfStatementAst])
        $phase2Clause = $phaseBranch.Clauses.Where({ $_.Item1.Extent.Text -eq '$Phase -eq ''Phase2''' })
        $phase2Clause.Count | Should -Be 1
        $workGuard.Extent.StartOffset | Should -BeGreaterThan $phase2Clause[0].Item2.Extent.StartOffset
        $workGuard.Extent.EndOffset | Should -BeLessThan $phase2Clause[0].Item2.Extent.EndOffset
        $calls = $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -in @('Set-WorkNpmRegistry', 'Install-Agency')
        }, $true)
        $calls.Count | Should -Be 2
        foreach ($call in $calls) {
            $call.Extent.StartOffset | Should -BeGreaterThan $workGuard.Extent.StartOffset
            $call.Extent.EndOffset | Should -BeLessThan $workGuard.Extent.EndOffset
        }
        Mock Set-WorkNpmRegistry {}
        Mock Install-Agency {}
        $Work = [switch]$false
        & $runWorkGuard
        Should -Invoke Set-WorkNpmRegistry -Times 0 -Exactly
        Should -Invoke Install-Agency -Times 0 -Exactly
        $Work = [switch]$true
        & $runWorkGuard
        Should -Invoke Set-WorkNpmRegistry -Times 1 -Exactly
        Should -Invoke Install-Agency -Times 1 -Exactly
    }

    It 'does not start Agency after registry configuration fails' {
        Mock Set-WorkNpmRegistry { throw 'Registry unavailable' }
        Mock Install-Agency {}
        $Work = [switch]$true
        { & $runWorkGuard } | Should -Throw '*Registry unavailable*'
        Should -Invoke Install-Agency -Times 0 -Exactly
    }

    It 'propagates Agency failure from the Work orchestration' {
        Mock Set-WorkNpmRegistry {}
        Mock Install-Agency { throw 'Installer denied' }
        $Work = [switch]$true
        { & $runWorkGuard } | Should -Throw '*Installer denied*'
    }

    It 'sets only the current-user npm registry and is idempotent on a second run' {
        Set-WorkNpmRegistry
        Set-WorkNpmRegistry
        Should -Invoke npm -Times 2 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -eq 'config get registry --location=user'
        }
        Should -Invoke npm -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -eq 'config set registry https://packagefeedproxy.microsoft.io/npm/ --location=user'
        }
        Should -Invoke npm -Times 3 -Exactly
    }

    It 'accepts an existing registry without a trailing slash' {
        $script:npmRegistry = " https://packagefeedproxy.microsoft.io/npm `n"
        Set-WorkNpmRegistry
        Should -Invoke npm -Times 1 -Exactly
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like '*already configured*' }
    }

    It 'fails before invoking npm when it is missing' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'npm' }
        { Set-WorkNpmRegistry } | Should -Throw '*npm is required*'
        Should -Invoke npm -Times 0 -Exactly
    }

    It 'fails a nonzero registry read without attempting a write' {
        $script:npmReadStatus = 17
        { Set-WorkNpmRegistry } | Should -Throw '*Could not read the npm registry*'
        Should -Invoke npm -Times 1 -Exactly
        Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*Done:*' }
    }

    It 'does not accept an apparently matching registry from a failed read' {
        $script:npmRegistry = 'https://packagefeedproxy.microsoft.io/npm/'
        $script:npmReadStatus = 17
        { Set-WorkNpmRegistry } | Should -Throw '*Could not read the npm registry*'
        Should -Invoke Write-Host -Times 0
    }

    It 'fails a nonzero registry write without reporting success' {
        $script:npmWriteStatus = 23
        { Set-WorkNpmRegistry } | Should -Throw '*Could not configure the 1ES npm feed*npm exit code 23*'
        Should -Invoke npm -Times 2 -Exactly
        Should -Invoke Write-Host -Times 0
    }

    It 'skips Agency when its command already exists' {
        $script:agencyInstalled = $true
        Install-Agency
        Should -Invoke pwsh -Times 0 -Exactly
        Should -Invoke Update-PathFromRegistry -Times 0 -Exactly
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like '*Skipped: Agency already installed*' }
    }

    It 'skips Agency at its per-user executable even when PATH is stale' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $agencyPath -and $PathType -eq 'Leaf' }
        Install-Agency
        Should -Invoke pwsh -Times 0 -Exactly
        Should -Invoke Update-PathFromRegistry -Times 0 -Exactly
    }

    It 'isolates the documented vendor installer and refreshes PATH before detection' {
        Mock Update-PathFromRegistry { $script:agencyInstalled = $true }
        Mock pwsh { $global:LASTEXITCODE = 0 }
        Install-Agency
        Should -Invoke pwsh -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq '-NoProfile' -and $Arguments[1] -eq '-Command' -and
            $Arguments[2] -match 'https://aka\.ms/InstallTool\.ps1' -and
            $Arguments[2] -match '\)\) agency;' -and $Arguments[2] -match 'exit \$LASTEXITCODE'
        }
        Should -Invoke Update-PathFromRegistry -Times 1 -Exactly
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like '*Done: Agency installed*' }
    }

    It 'accepts the installed executable when the new command is not yet on PATH' {
        $script:installerCompleted = $false
        Mock pwsh { $global:LASTEXITCODE = 0; $script:installerCompleted = $true }
        Mock Test-Path { $script:installerCompleted } -ParameterFilter { $LiteralPath -eq $agencyPath }
        Install-Agency
        Should -Invoke Update-PathFromRegistry -Times 1 -Exactly
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like '*Done: Agency installed*' }
    }

    It 'fails a nonzero installer without refreshing PATH or reporting success' {
        Mock pwsh { $global:LASTEXITCODE = 31 }
        { Install-Agency } | Should -Throw '*Agency installation failed*exit code 31*corporate access/authentication*'
        Should -Invoke Update-PathFromRegistry -Times 0 -Exactly
        Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*Done:*' }
    }

    It 'rejects installer success if neither the command nor executable can be found' {
        Mock pwsh { $global:LASTEXITCODE = 0 }
        { Install-Agency } | Should -Throw '*installer completed, but agency was not found*'
        Should -Invoke Update-PathFromRegistry -Times 1 -Exactly
        Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*Done:*' }
    }
}

Describe 'Standalone Copilot CLI removal' -Tag 'BootstrapSafety' {
    BeforeAll {
        function gh { throw 'Verification must not invoke gh subcommands' }
        function copilot { throw 'Verification must not invoke standalone Copilot' }
        function code { 'github.copilot-chat' }
        function code-insiders { 'github.copilot-chat' }
    }
    BeforeEach {
        Mock Get-CommandVersion { '1.2.3' }
        Mock Get-Command { $null } -ParameterFilter { $Name -in @('code', 'code-insiders') }
        Mock Write-VerificationLine {}
        Mock Write-Host {}
    }

    It 'has no standalone installer, package, presence probe or command invocation' {
        $functionDefs.Name | Should -Not -Contain 'Install-GitHubCopilotCli'
        $scriptContent | Should -Not -Match '(?i)GitHub Copilot CLI|@github/copilot|gh-copilot|Install-GitHubCopilotCli'
        $packageDefinition = $ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -eq '$corePackages'
        }
        $packages = & ([scriptblock]::Create($packageDefinition.Right.Extent.Text))
        $packages.Id | Should -Contain 'GitHub.cli'
        $packages.Id | Should -Not -Contain 'GitHub.Copilot'
        $commands = $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)
        foreach ($command in $commands) {
            $command.GetCommandName() | Should -Not -Be 'copilot'
            $command.Extent.Text | Should -Not -Match '(?i)\bgh\s+(copilot|extension)\b|(?:Get-Command|Get-CommandVersion).*-Command\s+[''"]?copilot\b'
            if ($command.GetCommandName() -in @('Get-Command', 'Get-CommandVersion')) {
                $arguments = $command.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.StringConstantExpressionAst]
                }
                $arguments.Value | Should -Not -Contain 'copilot'
            }
        }
    }

    It 'verifies GitHub CLI without probing or reporting standalone Copilot' {
        Show-VerificationSummary
        Should -Invoke Get-CommandVersion -Times 1 -Exactly -ParameterFilter { $Command -eq 'gh' }
        Should -Invoke Get-CommandVersion -Times 0 -Exactly -ParameterFilter { $Command -match 'copilot' }
        Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'GitHub CLI' -and $Installed -and $Details -eq '1.2.3'
        }
        Should -Invoke Write-VerificationLine -Times 0 -Exactly -ParameterFilter { $Label -match 'Copilot.*CLI' }
        $scriptContent | Should -Match "Id\s*=\s*'GitHub\.cli'"
        $scriptContent | Should -Match "Id\s*=\s*'github\.copilot-chat'"
    }

    It 'still verifies the current Copilot Chat extension in both editors without retired or synthetic results' {
        Mock Get-Command { [pscustomobject]@{ Name = $Name } } -ParameterFilter { $Name -in @('code', 'code-insiders') }
        Show-VerificationSummary
        Should -Invoke Write-VerificationLine -Times 0 -Exactly -ParameterFilter {
            $Label -eq '  GitHub Copilot'
        }
        Should -Invoke Write-VerificationLine -Times 2 -Exactly -ParameterFilter {
            $Label -eq '  GitHub Copilot Chat' -and $Installed
        }
        Should -Invoke Write-VerificationLine -Times 2 -Exactly -ParameterFilter {
            $Details -eq 'github.copilot-chat' -and $Installed
        }
    }
}

Describe 'Phase 2 one-shot resume safety' -Tag 'BootstrapSafety' {
    BeforeAll {
        $resumeGuard = $ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Clauses[0].Item1.Extent.Text -eq '$Phase -eq ''Phase2'''
        } | Select-Object -First 1
        $resumeGuard | Should -Not -BeNullOrEmpty
        $runGuard = [scriptblock]::Create($resumeGuard.Extent.Text + "`nInitialize-PSModulePath")
        $sandbox = Join-Path $PSScriptRoot ".sandbox\resume-$([guid]::NewGuid())"
        $oldLocalAppData = $env:LOCALAPPDATA
        $null = New-Item -Path $sandbox -ItemType Directory -Force
    }

    BeforeEach {
        $env:LOCALAPPDATA = $sandbox
        $script:Phase = 'Phase2'
        $script:ResumeToken = [guid]::NewGuid()
        $script:taskName = 'altered-carbon-test-only'
        Mock Write-Host {}
        Mock Initialize-PSModulePath { 'configuration reached' }
        Mock Get-ScheduledTask { }
        Mock Unregister-ScheduledTask {}
    }

    AfterAll {
        $env:LOCALAPPDATA = $oldLocalAppData
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }

    It 'durably claims an attempt and refuses it after functions are reloaded' {
        Enter-Phase2Resume -Token $ResumeToken | Should -BeTrue
        $marker = Join-Path $sandbox "altered-carbon\phase2-$ResumeToken.attempted"
        $timestamp = Get-Content -LiteralPath $marker -Raw
        { [datetime]::Parse($timestamp) } | Should -Not -Throw
        Invoke-Expression ($functionDefs | Where-Object Name -EQ 'Enter-Phase2Resume').Extent.Text
        Enter-Phase2Resume -Token $ResumeToken | Should -BeFalse
        Get-Content -LiteralPath $marker -Raw | Should -Be $timestamp
        Enter-Phase2Resume -Token ([guid]::NewGuid()) | Should -BeTrue
    }

    It 'removes and verifies the task before allowing initialization' {
        $script:taskReads = 0
        Mock Get-ScheduledTask {
            $script:taskReads++
            if ($script:taskReads -eq 1) { [pscustomobject]@{ TaskName = 'altered-carbon-test-only' } }
        }
        Mock Initialize-PSModulePath {
            $script:taskReads | Should -Be 2
            Test-Path (Join-Path $sandbox "altered-carbon\phase2-$ResumeToken.attempted") | Should -BeTrue
        }
        & $runGuard
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'altered-carbon-test-only' -and $TaskPath -eq '\' -and -not $Confirm -and $ErrorAction -eq 'Stop'
        }
        Should -Invoke Initialize-PSModulePath -Times 1 -Exactly
    }

    It 'fails loudly and blocks initialization if deletion is denied' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'altered-carbon-test-only' } }
        Mock Unregister-ScheduledTask { throw 'Access denied' }
        { & $runGuard } | Should -Throw '*Could not remove scheduled task*Access denied*'
        Should -Invoke Initialize-PSModulePath -Times 0
        Enter-Phase2Resume -Token $ResumeToken | Should -BeFalse
    }

    It 'blocks initialization when unregister returns but the task remains' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'altered-carbon-test-only' } }
        { & $runGuard } | Should -Throw '*task still exists after removal*'
        Should -Invoke Initialize-PSModulePath -Times 0
    }

    It 'fails closed if task enumeration fails' {
        Mock Get-ScheduledTask { throw 'Scheduler unavailable' }
        { & $runGuard } | Should -Throw '*Could not remove scheduled task*Scheduler unavailable*'
        Should -Invoke Initialize-PSModulePath -Times 0
    }

    It 'still retires the task on duplicate attempts without configuring again' {
        $null = Enter-Phase2Resume -Token $ResumeToken
        Mock Remove-Phase2Task {}
        { & $runGuard } | Should -Throw '*already been consumed*'
        Should -Invoke Remove-Phase2Task -Times 1 -Exactly
        Should -Invoke Initialize-PSModulePath -Times 0
    }

    It 'still retires the task if durable claim creation fails' {
        Mock Enter-Phase2Resume { throw 'Disk unavailable' }
        Mock Remove-Phase2Task {}
        { & $runGuard } | Should -Throw '*Disk unavailable*'
        Should -Invoke Remove-Phase2Task -Times 1 -Exactly
        Should -Invoke Initialize-PSModulePath -Times 0
    }

    It 'does not retry configuration on the next logon after initialization fails' {
        Mock Initialize-PSModulePath { throw 'Initialization failed' }
        { & $runGuard } | Should -Throw '*Initialization failed*'
        { & $runGuard } | Should -Throw '*already been consumed*'
        Should -Invoke Initialize-PSModulePath -Times 1 -Exactly
    }

    It 'allows manual Phase 2 without claiming a scheduled token' {
        $script:ResumeToken = [guid]::Empty
        Mock Enter-Phase2Resume { throw 'Must not claim manual runs' }
        & $runGuard | Should -Be 'configuration reached'
        Should -Invoke Enter-Phase2Resume -Times 0
    }
}

Describe 'Phase 2 scheduled task ACL preservation' -Tag 'BootstrapSafety' {
    It 'preserves existing ACEs and grants the limited user generic-all including deletion' {
        $script:originalSddl = 'O:SYG:SYD:P(A;;FA;;;SY)(A;;FR;;;BA)'
        $script:writtenSddl = $null
        $script:taskStub = [pscustomobject]@{}
        $taskStub | Add-Member ScriptMethod GetSecurityDescriptor {
            param($sections)
            $sections | Should -Be 4
            return $script:originalSddl
        }
        $taskStub | Add-Member ScriptMethod SetSecurityDescriptor {
            param($sddl, $flags)
            $flags | Should -Be 0
            $script:writtenSddl = $sddl
        }
        $folder = [pscustomobject]@{} | Add-Member ScriptMethod GetTask {
            param($name)
            $name | Should -Be 'altered-carbon-test-only'
            return $script:taskStub
        } -PassThru
        $scheduler = [pscustomobject]@{ Folder = $folder }
        $scheduler | Add-Member ScriptMethod Connect {}
        $scheduler | Add-Member ScriptMethod GetFolder {
            param($path)
            $path | Should -Be '\'
            return $this.Folder
        }
        Mock New-Object { $scheduler } -ParameterFilter { $ComObject -eq 'Schedule.Service' }

        $userSid = 'S-1-5-21-111-222-333-1001'
        Grant-Phase2TaskAccess -TaskName 'altered-carbon-test-only' -UserSid $userSid

        $before = [System.Security.AccessControl.RawSecurityDescriptor]::new($originalSddl)
        $after = [System.Security.AccessControl.RawSecurityDescriptor]::new($writtenSddl)
        $after.DiscretionaryAcl.Count | Should -Be ($before.DiscretionaryAcl.Count + 1)
        $after.ControlFlags | Should -Be $before.ControlFlags
        for ($i = 0; $i -lt $before.DiscretionaryAcl.Count; $i++) {
            $beforeBytes = [byte[]]::new($before.DiscretionaryAcl[$i].BinaryLength)
            $afterBytes = [byte[]]::new($after.DiscretionaryAcl[$i].BinaryLength)
            $before.DiscretionaryAcl[$i].GetBinaryForm($beforeBytes, 0)
            $after.DiscretionaryAcl[$i].GetBinaryForm($afterBytes, 0)
            [Convert]::ToBase64String($afterBytes) | Should -Be ([Convert]::ToBase64String($beforeBytes))
            $after.DiscretionaryAcl[$i].AccessMask | Should -Be $before.DiscretionaryAcl[$i].AccessMask
            $after.DiscretionaryAcl[$i].SecurityIdentifier.Value | Should -Be $before.DiscretionaryAcl[$i].SecurityIdentifier.Value
        }
        $grant = $after.DiscretionaryAcl[$after.DiscretionaryAcl.Count - 1]
        $grant.SecurityIdentifier.Value | Should -Be $userSid
        $grant.AccessMask | Should -Be 0x10000000
        $grant.AceQualifier | Should -Be ([System.Security.AccessControl.AceQualifier]::AccessAllowed)
    }
}

Describe 'Legacy POSH_PATH deletion safety' -Tag 'BootstrapSafety' {
    BeforeAll {
        function Get-InstalledModule {
            param($Name, $ErrorAction)
            throw 'Get-InstalledModule must be mocked'
        }
        $sandbox = Join-Path $PSScriptRoot ".sandbox\posh-$([guid]::NewGuid())"
        $modulePath = Join-Path $sandbox 'home\Documents\PowerShell\Modules\oh-my-posh\7.0.0'
        $oldHome = $env:USERPROFILE
        $oldPoshPath = $env:POSH_PATH
        $null = New-Item -Path $modulePath -ItemType Directory -Force
        Set-Content (Join-Path $modulePath 'oh-my-posh.psd1') '@{}'
    }
    BeforeEach {
        $env:USERPROFILE = Join-Path $sandbox 'home'
    }
    AfterAll {
        $env:USERPROFILE = $oldHome
        $env:POSH_PATH = $oldPoshPath
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }

    It 'rejects roots, home, ancestors, unrecognized directories, files and missing paths' {
        $unsafePaths = @(
            [System.IO.Path]::GetPathRoot($sandbox),
            $env:USERPROFILE,
            $sandbox,
            (Split-Path $modulePath -Parent),
            (Join-Path $modulePath 'oh-my-posh.psd1'),
            (Join-Path $sandbox 'missing'),
            '',
            'HKCU:\Software'
        )
        foreach ($unsafe in $unsafePaths) {
            Test-LegacyOhMyPoshPath -Path $unsafe -ModuleBase @($modulePath) | Should -BeFalse -Because "'$unsafe' is not safe to delete"
        }
        foreach ($unsafe in @([System.IO.Path]::GetPathRoot($sandbox), $env:USERPROFILE, $sandbox)) {
            Test-LegacyOhMyPoshPath -Path $unsafe -ModuleBase @($unsafe) | Should -BeFalse
        }
        Test-LegacyOhMyPoshPath -Path $modulePath -ModuleBase @() | Should -BeFalse
    }

    It 'allows only an exact discovered module directory including normalized trailing separators' {
        Test-LegacyOhMyPoshPath -Path $modulePath -ModuleBase @($modulePath) | Should -BeTrue
        Test-LegacyOhMyPoshPath -Path "$modulePath\" -ModuleBase @("$modulePath\") | Should -BeTrue
        $unversioned = Split-Path $modulePath -Parent
        Test-LegacyOhMyPoshPath -Path $unversioned -ModuleBase @($unversioned) | Should -BeTrue
        Test-LegacyOhMyPoshPath -Path $modulePath -ModuleBase @((Split-Path $modulePath -Parent)) | Should -BeFalse
    }

    It 'rejects a reparse point on the target, an ancestor or any descendant' {
        foreach ($location in @('target', 'parent', 'child')) {
            $parent = [pscustomobject]@{ Attributes = [System.IO.FileAttributes]::Directory; Parent = $null }
            $target = [pscustomobject]@{
                PSIsContainer = $true; PSProvider = @{ Name = 'FileSystem' }
                FullName = $modulePath; Attributes = [System.IO.FileAttributes]::Directory; Parent = $parent
            }
            if ($location -eq 'target') { $target.Attributes = [System.IO.FileAttributes]::ReparsePoint }
            if ($location -eq 'parent') { $parent.Attributes = [System.IO.FileAttributes]::ReparsePoint }
            Mock Get-Item { $target }
            Mock Get-ChildItem {
                if ($location -eq 'child') { [pscustomobject]@{ Attributes = [System.IO.FileAttributes]::ReparsePoint } }
            }
            Test-LegacyOhMyPoshPath -Path $modulePath -ModuleBase @($modulePath) | Should -BeFalse -Because "$location reparse points must block deletion"
        }
    }

    It 'fails closed when descendant enumeration is denied' {
        Mock Get-ChildItem { throw 'Access denied' }
        Test-LegacyOhMyPoshPath -Path $modulePath -ModuleBase @($modulePath) | Should -BeFalse
    }

    It 'uses the guard before recursive literal-path deletion and leaves unsafe paths alone' {
        Mock Get-Module { [pscustomobject]@{ ModuleBase = $modulePath } } -ParameterFilter {
            $ListAvailable -and $Name -eq 'oh-my-posh'
        }
        Mock Get-InstalledModule { $null }
        Mock Test-Path { $true }
        Mock Remove-Item {}
        Mock Write-Host {}
        Mock Write-Warning {}
        # Stop immediately after the migration block, before any profile configuration.
        Mock Set-Content { throw 'test stop before profile writes' }
        Mock Get-Content { '' }
        foreach ($path in @($env:USERPROFILE, $sandbox, (Split-Path $modulePath -Parent), $modulePath)) {
            $env:POSH_PATH = $path
            { Set-OhMyPoshProfile -ThemeName 'night-owl' -ProfileDir $sandbox -ProfileFile (Join-Path $sandbox 'profile.ps1') } |
                Should -Throw '*test stop before profile writes*'
        }
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq $modulePath -and $Recurse -and $Force -and $ErrorAction -eq 'Stop'
        }
        Should -Invoke Remove-Item -Times 1 -Exactly
        Should -Invoke Write-Warning -Times 3 -Exactly -ParameterFilter { $Message -like '*Skipped unsafe*' }
    }
}

Describe 'Set-OhMyPoshProfile' {
    BeforeEach {
        Mock Get-Module { @{ Name = 'oh-my-posh' } } -ParameterFilter {
            $ListAvailable -and $Name -eq 'oh-my-posh'
        }
        Mock Get-InstalledModule { $null } -ParameterFilter { $Name -eq 'oh-my-posh' }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'pwsh' }
        Mock Join-Path { "C:\Mock\$ChildPath" } -ParameterFilter { [string]::IsNullOrEmpty($Path) }
        Mock Test-Path { $false }
        Mock Get-Content { '' }
        Mock Set-Content {}
        Mock New-Item {}
        Mock Copy-Item {}
        Mock Invoke-WebRequest {}
        Mock Uninstall-Module {}
    }

    It 'does not uninstall the deprecated oh-my-posh module unless PowerShellGet reports it installed' {
        try {
            Set-OhMyPoshProfile -ThemeName 'night-owl' -ProfileDir 'C:\Profiles' -ProfileFile 'C:\Profiles\profile.ps1'
        } catch {
            $null = $_
        }

        Should -Invoke Uninstall-Module -Times 0 -Exactly
    }
}

Describe 'Set-FileExplorerOptions' {
    It 'creates the Run as different user registry path before setting the policy value' {
        Mock Test-Path { $false } -ParameterFilter { $Path -eq 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' }
        Mock New-Item {}
        Mock Set-ItemProperty {}
        Mock Write-Warning {}

        Set-FileExplorerOptions

        Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -eq 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -and
            $Name -eq 'ShowRunAsDifferentUserInStart' -and
            $Value -eq 1
        }
    }
}

Describe 'Shared oh-my-posh theme' {
    BeforeAll {
        $themePath = Join-Path $PSScriptRoot '..' 'night-owl.omp.json'
        $theme = Get-Content $themePath -Raw | ConvertFrom-Json
        $themeSegments = $theme.blocks | ForEach-Object { $_.segments }
        $batterySegment = $themeSegments | Where-Object type -eq 'battery' | Select-Object -First 1
        $macScriptContent = Get-Content (Join-Path $PSScriptRoot '..' 'altered-carbon-mac.sh') -Raw
    }

    It 'includes the customized battery segment for both platforms' {
        $batterySegment | Should -Not -BeNullOrEmpty
        $batterySegment.options.charging_icon | Should -Not -BeNullOrEmpty
        $batterySegment.options.discharging_icon | Should -Not -BeNullOrEmpty
        $batterySegment.options.charged_icon | Should -Not -BeNullOrEmpty
        $batterySegment.options.not_charging_icon | Should -Not -BeNullOrEmpty
    }

    It 'copies the repository theme into the macOS managed theme directory' {
        $macScriptContent | Should -Match 'REPO_THEME="\$SCRIPT_DIR/\$\{OMP_THEME\}\.omp\.json"'
        $macScriptContent | Should -Match 'cp "\$REPO_THEME" "\$DEST_THEME"'
    }
}
