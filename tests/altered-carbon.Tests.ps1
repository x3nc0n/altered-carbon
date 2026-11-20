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
    function Register-ScheduledTask {
        [CmdletBinding()]
        param($TaskName, $Description, $Action, $Trigger, $Principal, $Settings, [switch]$Force)
        throw 'Tests must mock task registration rather than register a real task.'
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
        $definition = $ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -eq '$personalPackages'
        }
        $packages = & ([scriptblock]::Create($definition.Right.Extent.Text))
        ($packages | Where-Object Id -eq 'Blizzard.BattleNet').Location |
            Should -Be (Join-Path ${env:ProgramFiles(x86)} 'Battle.net')
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

    It 'does not bootstrap an unnecessary second package manager' {
        $functionDefs.Name | Should -Not -Contain 'Install-Chocolatey'
        $functionDefs.Name | Should -Not -Contain 'Install-ChocolateyPackages'
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

Describe 'Bootstrap phase preflight' {
    It 'rejects the wrong elevation before any setup runs' -ForEach @(
        @{ RunPhase = 'Phase1'; Admin = $false; ErrorText = '*Phase1 requires an elevated shell*' }
        @{ RunPhase = 'Phase2'; Admin = $true; ErrorText = '*Phase2 must run in a non-elevated shell*' }
    ) {
        $guard = $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text -like "*throw '$($ErrorText.Trim('*'))*"
        }, $true) | Select-Object -First 1
        $guard | Should -Not -BeNullOrEmpty
        $Phase = $RunPhase
        $isAdmin = $Admin
        { & ([scriptblock]::Create($guard.Extent.Text)) } | Should -Throw $ErrorText
    }

    It 'starts Auto in installation rather than silently skipping packages' {
        $detection = $ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Clauses[0].Item1.Extent.Text -eq '$Phase -eq ''Auto'''
        }
        $Phase = 'Auto'
        $isAdmin = $false
        . ([scriptblock]::Create($detection.Extent.Text))
        $Phase | Should -Be 'Phase1'
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

    It 'does not probe or install explicitly skipped git and Node.js packages' {
        $script:corePackages = @(
            @{ Id = 'Git.Git'; Name = 'git'; Source = 'winget' }
            @{ Id = 'OpenJS.NodeJS.LTS'; Name = 'Node.js (LTS)'; Source = 'winget' }
        )
        Install-WingetPackages -Personal $false -SkipPackages @('Git.Git', 'OpenJS.NodeJS.LTS')
        $script:wingetCalls.Count | Should -Be 0
    }

    AfterEach {
        Remove-Item function:\global:winget -ErrorAction SilentlyContinue
    }

    Context 'identity-sensitive core packages' {
        BeforeEach {
            $definition = $ast.EndBlock.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $_.Left.Extent.Text -eq '$corePackages'
            }
            $script:corePackages = @(& ([scriptblock]::Create($definition.Right.Extent.Text)) |
                Where-Object Id -eq $PackageId)
            $script:corePackages.Count | Should -Be 1
            Mock Write-Host {}
            Mock Write-Warning {}
        }

        It 'keeps current <PackageId> idempotent without name fallback or reinstall' -TestCases @(
            @{ PackageId = 'bradygaster.Squad'; Source = 'winget' }
            @{ PackageId = 'XPDCK2L0R6V76J'; Source = 'msstore' }
            @{ PackageId = 'RedHat.Podman'; Source = 'winget' }
            @{ PackageId = 'RedHat.Podman-Desktop'; Source = 'winget' }
        ) {
            param($PackageId, $Source)
            $script:wingetResponses.Enqueue(@{
                ExitCode = 0
                Output = @(
                    ('{0,-24}{1,-28}{2,-12}{3,-12}Source' -f 'Name', 'Id', 'Version', 'Available')
                    ('-' * 90)
                    ('{0,-24}{1,-28}{2,-12}{3,-12}{4}' -f 'Official app', $PackageId, '1.2.3', '1.2.3', $Source)
                )
            })
            $script:wingetResponses.Enqueue(@{ ExitCode = -1978335189; Output = @() })

            Install-WingetPackages -Personal $false -NoApplicableUpgradeExitCode -1978335189

            $script:wingetCalls.Count | Should -Be 2
            ($script:wingetCalls[0] -join ' ') | Should -Be "list --id $PackageId --exact --source $Source --accept-source-agreements"
            ($script:wingetCalls[1] -join ' ') | Should -Be "upgrade --id $PackageId --exact --source $Source --accept-source-agreements --accept-package-agreements --silent --include-unknown"
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -like '*already up to date*'
            }
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It 'does not detect a near-name app when exact <PackageId> is unavailable' -TestCases @(
            @{ PackageId = 'bradygaster.Squad'; Source = 'winget'; NearId = 'Other.Squad' }
            @{ PackageId = 'bradygaster.Squad'; Source = 'winget'; NearId = 'bradygaster.Squad.Tools' }
            @{ PackageId = 'XPDCK2L0R6V76J'; Source = 'msstore'; NearId = 'GitHub.Copilot' }
            @{ PackageId = 'RedHat.Podman'; Source = 'winget'; NearId = 'RedHat.Podman-Desktop' }
            @{ PackageId = 'RedHat.Podman-Desktop'; Source = 'winget'; NearId = 'RedHat.Podman' }
        ) {
            param($PackageId, $Source, $NearId)
            $script:wingetResponses.Enqueue(@{
                ExitCode = -1978335212
                Output = @(
                    ('{0,-24}{1,-28}{2,-12}Source' -f 'Name', 'Id', 'Version')
                    ('-' * 80)
                    ('{0,-24}{1,-28}{2,-12}{3}' -f 'Similar app', $NearId, '9.9.9', $Source)
                )
            })
            $script:wingetResponses.Enqueue(@{ ExitCode = -1978335212; Output = @('No package found matching input criteria.') })
            $script:wingetResponses.Enqueue(@{ ExitCode = -1978335212; Output = @() })

            Install-WingetPackages -Personal $false -PackageNotFoundExitCode -1978335212

            $script:wingetCalls.Count | Should -Be 3
            ($script:wingetCalls[0] -join ' ') | Should -Be "list --id $PackageId --exact --source $Source --accept-source-agreements"
            ($script:wingetCalls[1] -join ' ') | Should -Be "search --id $PackageId --exact --source $Source --accept-source-agreements"
            ($script:wingetCalls[2] -join ' ') | Should -Be "install --id $PackageId --exact --source $Source --accept-source-agreements --accept-package-agreements --silent"
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like '*not available from the configured sources*'
            }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter {
                $Object -match 'Done:|Skipped:'
            }
        }
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

        Should -Invoke Get-WindowsOptionalFeature -Times 3 -Exactly
        Should -Invoke Enable-WindowsOptionalFeature -Times 0 -Exactly
        Should -Invoke Write-Warning -Times 3 -Exactly -ParameterFilter {
            $Message -like '*feature management is unavailable*'
        }
    }

    It 'still enables WSL features when Hyper-V is unavailable on Windows Home' {
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Get-WindowsOptionalFeature {
            if ($FeatureName -eq 'Microsoft-Hyper-V-All') { throw 'Feature name is unknown' }
            [pscustomobject]@{ State = 'Disabled' }
        }
        Mock Enable-WindowsOptionalFeature {}

        Enable-WindowsFeatures -IsAdmin $true

        Should -Invoke Enable-WindowsOptionalFeature -Times 2 -Exactly
        Should -Invoke Enable-WindowsOptionalFeature -Times 1 -Exactly -ParameterFilter {
            $FeatureName -eq 'Microsoft-Windows-Subsystem-Linux' -and $NoRestart
        }
        Should -Invoke Enable-WindowsOptionalFeature -Times 1 -Exactly -ParameterFilter {
            $FeatureName -eq 'VirtualMachinePlatform' -and $NoRestart
        }
    }

    It 'does not re-enable features that are already enabled or pending reboot' {
        Mock Write-Host {}
        Mock Get-WindowsOptionalFeature {
            [pscustomobject]@{ State = if ($FeatureName -eq 'VirtualMachinePlatform') { 'EnablePending' } else { 'Enabled' } }
        }
        Mock Enable-WindowsOptionalFeature {}
        Enable-WindowsFeatures -IsAdmin $true
        Should -Invoke Enable-WindowsOptionalFeature -Times 0
    }
}

Describe 'CUDA toolkit compatibility' -Tag 'LocalAI' {
    It 'selects CUDA <Version> and the exact target for compute <Capability>' -TestCases @(
        @('5.0', '5.2', '5.3', '6.0', '6.1', '6.2', '7.0', '7.2') | ForEach-Object {
            @{ Capability = $_; Version = '12.9'; Driver = [version]'576.57' }
        }
        @('7.5', '8.0', '8.6', '8.7', '8.9', '9.0', '10.0', '10.3', '11.0', '12.0', '12.1') | ForEach-Object {
            @{ Capability = $_; Version = '13.5'; Driver = [version]'620.0' }
        }
    ) {
        param($Capability, $Version, $Driver)
        $plan = Get-CudaInstallPlan -Gpu @([pscustomobject]@{ Name = 'NVIDIA fixture'; Capability = $Capability; Driver = '620.00' })
        $plan.Version | Should -Be $Version
        $plan.MinimumDriver | Should -Be $Driver
        $plan.Architectures | Should -HaveCount 1
        $plan.Architectures[0] | Should -Be ('compute_' + $Capability.Replace('.', ''))
    }

    It 'declines unsupported or malformed capability/driver data' -TestCases @(
        @{ Capability = '5.20'; Driver = '620.00' }
        @{ Capability = '9.9'; Driver = '620.00' }
        @{ Capability = ''; Driver = '620.00' }
        @{ Capability = '8.6'; Driver = 'unknown' }
    ) {
        param($Capability, $Driver)
        $plan = Get-CudaInstallPlan -Gpu @([pscustomobject]@{ Name = 'NVIDIA fixture'; Capability = $Capability; Driver = $Driver })
        $plan.Version | Should -BeNullOrEmpty
        $plan.Reason | Should -Match 'Unknown'
    }

    It 'requires manual selection for legacy plus compute <Capability>' -TestCases @(
        @{ Capability = '10.3' }; @{ Capability = '11.0' }; @{ Capability = '12.1' }
    ) {
        param($Capability)
        $plan = Get-CudaInstallPlan -Gpu @(
            [pscustomobject]@{ Name = 'Legacy'; Capability = '5.2'; Driver = '620.00' }
            [pscustomobject]@{ Name = 'Modern'; Capability = $Capability; Driver = '620.00' }
        )
        $plan.Version | Should -BeNullOrEmpty
        $plan.Reason | Should -Match 'Mixed'
    }

    It 'uses the legacy toolkit for supported mixed GPUs and retains all distinct targets' {
        $plan = Get-CudaInstallPlan -Gpu @(
            [pscustomobject]@{ Name = 'Legacy'; Capability = '5.2'; Driver = '620.00' }
            [pscustomobject]@{ Name = 'Modern'; Capability = '8.6'; Driver = '620.00' }
            [pscustomobject]@{ Name = 'Modern duplicate'; Capability = '8.6'; Driver = '620.00' }
        )
        $plan.Version | Should -Be '12.9'
        $plan.Architectures | Should -HaveCount 2
        $plan.Architectures | Should -Contain 'compute_52'
        $plan.Architectures | Should -Contain 'compute_86'
        (Get-CudaInstallPlan -Gpu @()).Reason | Should -Not -BeNullOrEmpty
    }

    Context 'mocked CUDA installation' {
        BeforeAll {
            if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) {
                function Get-PnpDevice { param($PresentOnly, $Class, $Status) }
            }
            function Invoke-TestNvidiaSmi {
                $global:LASTEXITCODE = $script:cudaSmiExit
                $script:cudaGpuRows
            }
            function winget {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]] $Arguments)
                $script:cudaInstallArguments = $Arguments
                $global:LASTEXITCODE = $script:cudaInstallExit
            }
        }
        BeforeEach {
            $script:cudaSmiExit = 0
            $script:cudaInstallExit = 0
            $script:cudaInstallArguments = @()
            $script:cudaGpuRows = @('00000000:01:00.0, NVIDIA fixture, 8.6, 620.00')
            $script:cudaBeforeCompilers = @()
            $script:cudaAfterCompilers = @([pscustomobject]@{
                Path = 'mock nvcc'; Version = [version]'13.5'; Architectures = @('compute_86')
            })
            Mock Get-CimInstance { [pscustomobject]@{ BuildNumber = '26100'; ProductType = 1 } }
            Mock Get-PnpDevice { [pscustomobject]@{ InstanceId = 'PCI\VEN_10DE&DEV_1234' } }
            Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-TestNvidiaSmi' } } -ParameterFilter { $Name -eq 'nvidia-smi' }
            Mock Get-CudaCompiler {
                if ($script:cudaInstallArguments.Count) { $script:cudaAfterCompilers } else { $script:cudaBeforeCompilers }
            }
            Mock Write-Host {}
            Mock Write-Warning {}
        }

        It 'skips explicitly excluded CUDA before probing the host' {
            Install-CudaToolkit -SkipPackages @('Nvidia.CUDA')
            Should -Invoke Get-CimInstance -Times 0
            $script:cudaInstallArguments | Should -BeNullOrEmpty
        }

        It 'does not install on an unvalidated OS build or without a present NVIDIA PCI device' -TestCases @(
            @{ Build = '22000'; Device = 'PCI\VEN_10DE&DEV_1234' }
            @{ Build = '26100'; Device = 'PCI\VEN_1002&DEV_1234' }
            @{ Build = '26100'; Device = 'ROOT\NVIDIA' }
        ) {
            param($Build, $Device)
            Mock Get-CimInstance { [pscustomobject]@{ BuildNumber = $Build; ProductType = 1 } }
            Mock Get-PnpDevice { [pscustomobject]@{ InstanceId = $Device } }
            Install-CudaToolkit
            $script:cudaInstallArguments | Should -BeNullOrEmpty
            Should -Invoke Get-CudaCompiler -Times 0
        }

        It 'does not install when the GPU query fails or its driver is too old' -TestCases @(
            @{ QueryExit = 1; Driver = '620.00' }
            @{ QueryExit = 0; Driver = '619.99' }
        ) {
            param($QueryExit, $Driver)
            $script:cudaSmiExit = $QueryExit
            $script:cudaGpuRows = @("00000000:01:00.0, NVIDIA fixture, 8.6, $Driver")
            Install-CudaToolkit
            $script:cudaInstallArguments | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1
        }

        It 'preserves a compatible older compiler before applying the newer toolkit driver threshold' {
            $script:cudaGpuRows = @('00000000:01:00.0, NVIDIA fixture, 8.6, 576.57')
            $script:cudaBeforeCompilers = @([pscustomobject]@{
                Path = 'existing nvcc'; Version = [version]'12.9'; Architectures = @('compute_86')
            })
            Install-CudaToolkit
            $script:cudaInstallArguments | Should -BeNullOrEmpty
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like '*compatible CUDA Toolkit*preserved*' }
            Should -Invoke Write-Warning -Times 0
        }

        It 'does not downgrade an unsupported newer compiler' {
            $script:cudaBeforeCompilers = @([pscustomobject]@{
                Path = 'future nvcc'; Version = [version]'14.0'; Architectures = @('compute_86')
            })
            Install-CudaToolkit
            $script:cudaInstallArguments | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*no downgrade*' }
        }

        It 'installs modern CUDA by exact version and verifies compiler targets' {
            $script:cudaGpuRows = @('00000000:01:00.0, NVIDIA GeForce RTX 3090, 8.6, 621.24')
            Install-CudaToolkit
            ($script:cudaInstallArguments -join ' ') | Should -Be 'install --id Nvidia.CUDA --exact --source winget --version 13.5 --scope machine --silent --accept-source-agreements --accept-package-agreements --disable-interactivity'
            Should -Invoke Get-CudaCompiler -Times 2 -Exactly
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like '*Done:*compiler and GPU targets verified*' }
        }

        It 'skips an empty GPU inventory before querying a driver' {
            Mock Get-PnpDevice { @() }
            Install-CudaToolkit
            Should -Invoke Get-Command -Times 0 -ParameterFilter { $Name -eq 'nvidia-smi' }
            $script:cudaInstallArguments | Should -BeNullOrEmpty
        }

        It 'does not install without a working driver executable' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'nvidia-smi' }
            Mock Test-Path { $false }
            Install-CudaToolkit
            Should -Invoke Get-CudaCompiler -Times 0
            $script:cudaInstallArguments | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*driver is missing*' }
        }

        It 'does not install for an unknown GPU capability' {
            $script:cudaGpuRows = @('00000000:01:00.0, NVIDIA fixture, 99.0, 621.24')
            Install-CudaToolkit
            Should -Invoke Get-CudaCompiler -Times 0
            $script:cudaInstallArguments | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*Unknown NVIDIA capability*' }
        }

        It 'selects explicit legacy toolkit components without installing a display driver' {
            $script:cudaGpuRows = @('00000000:01:00.0, NVIDIA fixture, 5.2, 576.57')
            $script:cudaAfterCompilers = @([pscustomobject]@{
                Path = 'mock nvcc'; Version = [version]'12.9'; Architectures = @('compute_52')
            })
            Install-CudaToolkit
            $versionIndex = [array]::IndexOf($script:cudaInstallArguments, '--version')
            $script:cudaInstallArguments[$versionIndex + 1] | Should -Be '12.9'
            $overrideIndex = [array]::IndexOf($script:cudaInstallArguments, '--override')
            $overrideIndex | Should -BeGreaterThan -1
            $override = $script:cudaInstallArguments[$overrideIndex + 1]
            $override | Should -Match '^-s -n nvcc_12\.9 '
            $override | Should -Match '\bcudart_12\.9\b'
            $override | Should -Not -Match '(?i)display|driver'
            @($override -split ' ' | Select-Object -Skip 2 | Where-Object { $_ -notmatch '^[a-z_]+_12\.9$' }) | Should -BeNullOrEmpty
        }

        It 'declines CUDA 12.9 on Windows 11 25H2' {
            Mock Get-CimInstance { [pscustomobject]@{ BuildNumber = '26200'; ProductType = 1 } }
            $script:cudaGpuRows = @('00000000:01:00.0, NVIDIA fixture, 5.2, 620.00')
            Install-CudaToolkit
            $script:cudaInstallArguments | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*12.9*25H2*' }
        }

        It 'fails loudly when installation fails or its claimed success cannot be verified' -TestCases @(
            @{ ExitCode = 5; Targets = @('compute_86') }
            @{ ExitCode = 0; Targets = @('compute_75') }
        ) {
            param($ExitCode, $Targets)
            $script:cudaInstallExit = $ExitCode
            $script:cudaAfterCompilers[0].Architectures = $Targets
            { Install-CudaToolkit } | Should -Throw '*CUDA Toolkit setup failed*'
            Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*Done:*' }
        }
    }
}

Describe 'Foundry Local readiness identity' -Tag 'LocalAI' {
    BeforeEach {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ ModelDirPath = 'models'; PipeName = 'foundry'; Endpoints = @('http://127.0.0.1:39839') }
        }
    }

    It 'requires the expected service payload and loopback endpoint, bypassing proxy configuration' {
        Test-FoundryReady | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'http://127.0.0.1:39839/openai/status' -and $TimeoutSec -eq 2 -and $NoProxy -and $ErrorAction -eq 'Stop'
        }
    }

    It 'rejects incomplete or foreign status payloads' -TestCases @(
        @{ ModelDir = ''; Pipe = 'foundry'; Endpoint = 'http://127.0.0.1:39839' }
        @{ ModelDir = 'models'; Pipe = ''; Endpoint = 'http://127.0.0.1:39839' }
        @{ ModelDir = 'models'; Pipe = 'foundry'; Endpoint = 'http://example.invalid:39839' }
        @{ ModelDir = 'models'; Pipe = 'foundry'; Endpoint = 'http://127.0.0.1:12345' }
        @{ ModelDir = 'models'; Pipe = 'foundry'; Endpoint = 'not a URI' }
    ) {
        param($ModelDir, $Pipe, $Endpoint)
        Mock Invoke-RestMethod {
            [pscustomobject]@{ ModelDirPath = $ModelDir; PipeName = $Pipe; Endpoints = @($Endpoint) }
        }
        Test-FoundryReady | Should -BeFalse
    }

    It 'returns false rather than treating an HTTP failure as readiness' {
        Mock Invoke-RestMethod { throw 'connection refused' }
        Test-FoundryReady | Should -BeFalse
    }
}

Describe 'Foundry Local owned login supervisor' -Tag 'LocalAI' {
    BeforeAll {
        function Invoke-TestFoundry {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]] $Arguments)
            $script:foundryCliCalls.Add(($Arguments -join ' '))
            $global:LASTEXITCODE = $script:foundryCliExit
            if ($Arguments[0] -eq 'server') { $script:foundryHelp } else { 'Foundry fixture 1.0' }
        }
        function winget {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]] $Arguments)
            $script:foundryInstallArguments = $Arguments
            $script:foundryOnPath = $true
            $global:LASTEXITCODE = 0
        }
        $script:foundrySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $script:foundryWrapperPath = Join-Path $env:LOCALAPPDATA 'altered-carbon\foundry-local\start-foundry.ps1'
    }
    BeforeEach {
        $script:foundryCliCalls = [System.Collections.Generic.List[string]]::new()
        $script:foundryInstallArguments = @()
        $script:foundryCliExit = 0
        $script:foundryHelp = '--port --idle-timeout'
        $script:foundryOnPath = $true
        $script:foundryWrapperExists = $false
        $script:foundryWrapperContent = ''
        $script:foundryExistingTask = $null
        Mock Get-CimInstance { [pscustomobject]@{ BuildNumber = '26100'; ProductType = 1 } }
        Mock Get-Command {
            if ($script:foundryOnPath) { [pscustomobject]@{ Source = 'Invoke-TestFoundry' } }
        } -ParameterFilter { $Name -eq 'foundry' }
        Mock Get-Command { [pscustomobject]@{ Source = 'mock-pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh' }
        Mock Update-PathFromRegistry {}
        Mock New-Item {}
        Mock Test-Path { $script:foundryWrapperExists } -ParameterFilter { $LiteralPath -eq $script:foundryWrapperPath }
        Mock Get-Content {
            if ($Raw) { $script:foundryWrapperContent } else { ($script:foundryWrapperContent -split '\r?\n')[0] }
        } -ParameterFilter { $LiteralPath -eq $script:foundryWrapperPath }
        Mock Set-Content {
            $script:foundryWrapperContent = $Value
            $script:foundryWrapperExists = $true
        } -ParameterFilter { $LiteralPath -eq $script:foundryWrapperPath }
        Mock Get-ScheduledTask {
            if ($TaskName) { [pscustomobject]@{ State = 'Running' } } else { $script:foundryExistingTask }
        }
        Mock New-ScheduledTaskAction { [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
        Mock New-ScheduledTaskTrigger { [pscustomobject]@{ UserId = $User; Enabled = $true } }
        Mock New-ScheduledTaskPrincipal { [pscustomobject]@{ UserId = $UserId } }
        Mock New-ScheduledTaskSettingsSet { [pscustomobject]@{ Enabled = $true } }
        Mock Register-ScheduledTask {} -RemoveParameterType @('Action', 'Trigger', 'Principal', 'Settings')
        Mock Start-ScheduledTask {}
        Mock Stop-ScheduledTask {}
        Mock Test-FoundryReady { $true }
        Mock Start-Sleep {}
        Mock Start-Process { throw 'The test must not start a real server' }
        Mock Stop-Process { throw 'The test must not stop processes' }
        Mock Write-Host {}
        Mock Write-Warning {}
    }

    It 'honors exclusion before probing the host or invoking package tools' {
        Install-FoundryLocal -SkipPackages @('Microsoft.FoundryLocal')
        Should -Invoke Get-CimInstance -Times 0
        Should -Invoke Register-ScheduledTask -Times 0
        $script:foundryCliCalls | Should -BeNullOrEmpty
    }

    It 'declines unsupported OS and server installations without modifying files' -TestCases @(
        @{ Build = '22631'; ProductType = 1 }
        @{ Build = '26100'; ProductType = 3 }
    ) {
        param($Build, $ProductType)
        Mock Get-CimInstance { [pscustomobject]@{ BuildNumber = $Build; ProductType = $ProductType } }
        Install-FoundryLocal
        Should -Invoke New-Item -Times 0
        $script:foundryCliCalls | Should -BeNullOrEmpty
    }

    It 'installs missing Foundry only for the current user and creates a least-privilege login task' {
        $script:foundryOnPath = $false
        Install-FoundryLocal
        ($script:foundryInstallArguments -join ' ') | Should -Be 'install --id Microsoft.FoundryLocal --exact --source winget --scope user --silent --accept-source-agreements --accept-package-agreements --disable-interactivity'
        @($script:foundryCliCalls) | Should -Be @('--version', 'server start --help')
        Should -Invoke New-ScheduledTaskPrincipal -Times 1 -Exactly -ParameterFilter {
            $UserId -eq $script:foundrySid -and $LogonType -eq 'Interactive' -and $RunLevel -eq 'Limited'
        }
        Should -Invoke New-ScheduledTaskTrigger -Times 1 -Exactly -ParameterFilter { $AtLogon -and $User -eq $script:foundrySid }
        Should -Invoke New-ScheduledTaskSettingsSet -Times 1 -Exactly -ParameterFilter {
            $MultipleInstances -eq 'IgnoreNew' -and $AllowStartIfOnBatteries -and $DontStopIfGoingOnBatteries -and $ExecutionTimeLimit -eq [timespan]::Zero
        }
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq "altered-carbon-foundry-local-$script:foundrySid" -and
            $Description -eq 'altered-carbon owned Foundry Local login supervisor v1'
        }
        Should -Invoke Start-Process -Times 0
        Should -Invoke Stop-Process -Times 0
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*MANUAL:*No provider, model, or credentials were configured*' }
    }

    It 'does not replace a wrapper lacking the ownership marker' {
        $script:foundryWrapperExists = $true
        $script:foundryWrapperContent = '# somebody else owns this'
        { Install-FoundryLocal } | Should -Throw '*unowned Foundry wrapper*'
        Should -Invoke Set-Content -Times 0
        Should -Invoke Register-ScheduledTask -Times 0
    }

    It 'does not replace or stop a task lacking its ownership description' {
        $script:foundryExistingTask = [pscustomobject]@{
            TaskName = "altered-carbon-foundry-local-$script:foundrySid"; Description = 'Foreign'; State = 'Running'
        }
        { Install-FoundryLocal } | Should -Throw '*unowned scheduled task*'
        Should -Invoke Register-ScheduledTask -Times 0
        Should -Invoke Stop-ScheduledTask -Times 0
        Should -Invoke Stop-Process -Times 0
    }

    It 'reuses matching files and a running task without reinstalling or restarting' {
        Install-FoundryLocal
        $script:foundryExistingTask = [pscustomobject]@{
            TaskName = "altered-carbon-foundry-local-$script:foundrySid"
            Description = 'altered-carbon owned Foundry Local login supervisor v1'
            State = 'Running'
            Actions = @([pscustomobject]@{
                Execute = 'mock-pwsh.exe'
                Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$script:foundryWrapperPath`""
            })
            Principal = [pscustomobject]@{ UserId = $script:foundrySid; LogonType = 'Interactive'; RunLevel = 'Limited' }
            Triggers = @([pscustomobject]@{
                CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskLogonTrigger' }; UserId = $script:foundrySid; Enabled = $true
            })
            Settings = [pscustomobject]@{
                Enabled = $true; MultipleInstances = 'IgnoreNew'; DisallowStartIfOnBatteries = $false
                StopIfGoingOnBatteries = $false; ExecutionTimeLimit = 'PT0S'
            }
        }
        Install-FoundryLocal
        Should -Invoke Set-Content -Times 1 -Exactly
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
        Should -Invoke Stop-ScheduledTask -Times 0
        Should -Invoke Start-ScheduledTask -Times 0
        $script:foundryInstallArguments | Should -BeNullOrEmpty

        $script:foundryWrapperContent += "`n# stale owned wrapper"
        Install-FoundryLocal
        Should -Invoke Stop-ScheduledTask -Times 1 -Exactly
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
        Should -Invoke Stop-Process -Times 0
    }

    It 'rejects unsupported CLI command flags before writing startup configuration' {
        $script:foundryHelp = '--port'
        { Install-FoundryLocal } | Should -Throw '*lacks documented server start*'
        Should -Invoke Set-Content -Times 0
        Should -Invoke Register-ScheduledTask -Times 0
    }

    It 'bounds readiness polling and fails without stopping unrelated processes' {
        Mock Test-FoundryReady { $false }
        { Install-FoundryLocal } | Should -Throw '*Foundry Local not ready*'
        Should -Invoke Start-Sleep -Times 30 -Exactly -ParameterFilter { $Seconds -eq 2 }
        Should -Invoke Stop-Process -Times 0
    }
}

Describe 'Azure Artifacts Credential Provider help probe' {
    BeforeAll {
        $originalProviderHelpExitCode = $global:LASTEXITCODE
        function Invoke-ProviderHelpFixture {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Arguments)
            $script:providerHelpArguments = $Arguments
            $global:LASTEXITCODE = $script:providerHelpExit
            'fixture help output'
        }
        function dotnet {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Arguments)
            Invoke-ProviderHelpFixture @Arguments
        }
    }
    AfterAll {
        $global:LASTEXITCODE = $originalProviderHelpExitCode
    }

    It 'checks only help through <Path> and treats exit <ExitCode> as usable=<Expected>' -TestCases @(
        @{ Path = 'Invoke-ProviderHelpFixture'; ExitCode = 0; Expected = $true }
        @{ Path = 'Invoke-ProviderHelpFixture'; ExitCode = 2; Expected = $false }
        @{ Path = 'fixture.dll'; ExitCode = 0; Expected = $true }
        @{ Path = 'fixture.dll'; ExitCode = 2; Expected = $false }
    ) {
        param($Path, $ExitCode, $Expected)
        $script:providerHelpExit = $ExitCode
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -in @('Invoke-ProviderHelpFixture', 'fixture.dll') }
        $result = @(Test-AzArtifactsCredentialProvider -Path $Path)
        $result.Count | Should -Be 1
        $result[0] | Should -Be $Expected
        $script:providerHelpArguments[-1] | Should -BeExactly '-h'
        $script:providerHelpArguments | Should -Not -Contain '-Uri'
    }
}

Describe 'Azure Artifacts Credential Provider installation' {
    BeforeAll {
        $originalProviderUserProfile = $env:USERPROFILE
    }
    BeforeEach {
        $providerSandbox = Join-Path $PSScriptRoot ".sandbox\credprovider-$([guid]::NewGuid())"
        $env:USERPROFILE = Join-Path $providerSandbox 'user'
        $providerRoot = Join-Path $env:USERPROFILE '.nuget\plugins\netcore'
        $providerDestination = Join-Path $providerRoot 'CredentialProvider.Microsoft'
        $providerApphost = Join-Path $providerDestination 'CredentialProvider.Microsoft.exe'
        $script:providerFixtureFiles = @('CredentialProvider.Microsoft.exe', 'CredentialProvider.Microsoft.dll',
            'CredentialProvider.Microsoft.deps.json', 'CredentialProvider.Microsoft.runtimeconfig.json', 'hostfxr.dll', 'coreclr.dll')
        $null = New-Item -Path $providerRoot -ItemType Directory -Force
        Mock Get-AzArtifactsCredentialProviderPath { $providerApphost }
        Mock Test-AzArtifactsCredentialProvider { Test-Path -LiteralPath $Path -PathType Leaf }
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'fictional archive' }
        Mock Get-FileHash { [pscustomobject]@{ Hash = 'f7d3cef19621fb3a87e4b38f5fbaba429917a4ca6881422764a474667dd0c038' } }
        Mock Expand-Archive {
            $provider = Join-Path $DestinationPath 'plugins\netcore\CredentialProvider.Microsoft'
            $null = New-Item -Path $provider -ItemType Directory -Force
            foreach ($file in $script:providerFixtureFiles) { Set-Content -LiteralPath (Join-Path $provider $file) -Value 'fixture' }
        }
    }
    AfterEach {
        $env:USERPROFILE = $originalProviderUserProfile
        Remove-Item -LiteralPath $providerSandbox -Recurse -Force
    }

    It 'reuses a usable <Location> provider without downloading or replacing it' -TestCases @(
        @{ Location = 'default' }
        @{ Location = 'configured' }
    ) {
        param($Location)
        if ($Location -eq 'configured') {
            $providerApphost = Join-Path $providerSandbox 'external\CredentialProvider.Microsoft.exe'
        }
        $null = New-Item -Path (Split-Path $providerApphost -Parent) -ItemType Directory -Force
        Set-Content -LiteralPath $providerApphost -Value 'existing provider'
        Install-AzArtifactsCredentialProvider
        Get-Content -LiteralPath $providerApphost | Should -Be 'existing provider'
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Expand-Archive -Times 0
    }

    It 'installs the verified self-contained <Architecture> asset per-user and cleans its exact stage' -TestCases @(
        @{ Architecture = 'X64'; Rid = 'win-x64'; Digest = 'f7d3cef19621fb3a87e4b38f5fbaba429917a4ca6881422764a474667dd0c038' }
        @{ Architecture = 'Arm64'; Rid = 'win-arm64'; Digest = '9aff3b5064ca47e37ddcabd95a85c87c92f1753f62014a7250045acc3943ef0a' }
    ) {
        param($Architecture, $Rid, $Digest)
        Mock Get-FileHash { [pscustomobject]@{ Hash = $Digest } }
        $otherPlugin = Join-Path $providerRoot 'Contoso.Plugin'
        $null = New-Item -Path $otherPlugin -ItemType Directory
        Set-Content -LiteralPath (Join-Path $otherPlugin 'keep') -Value 'untouched'
        Install-AzArtifactsCredentialProvider -Architecture $Architecture
        Test-Path -LiteralPath $providerApphost -PathType Leaf | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://github.com/microsoft/artifacts-credprovider/releases/download/v2.0.6/Microsoft.$Rid.NuGet.CredentialProvider.zip" -and
            $OutFile.StartsWith($providerRoot)
        }
        Should -Invoke Get-FileHash -Times 1 -Exactly -ParameterFilter { $Algorithm -eq 'SHA256' }
        Should -Invoke Test-AzArtifactsCredentialProvider -Times 1 -ParameterFilter { $Path -like '*extracted*CredentialProvider.Microsoft.exe' }
        @(Get-ChildItem -LiteralPath $providerRoot -Filter '.altered-carbon-*').Count | Should -Be 0
        Get-Content -LiteralPath (Join-Path $otherPlugin 'keep') | Should -Be 'untouched'
    }

    It 'preserves an existing incomplete provider without downloading or deleting it' {
        $null = New-Item -Path $providerDestination -ItemType Directory
        Set-Content -LiteralPath (Join-Path $providerDestination 'keep') -Value 'existing partial installation'
        { Install-AzArtifactsCredentialProvider } | Should -Throw '*preserved*'
        Get-Content -LiteralPath (Join-Path $providerDestination 'keep') | Should -Be 'existing partial installation'
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'fails closed for <Failure> without publishing a partial provider or leaving its stage' -TestCases @(
        @{ Failure = 'download' }
        @{ Failure = 'checksum' }
        @{ Failure = 'extraction' }
        @{ Failure = 'incomplete archive' }
        @{ Failure = 'unusable apphost' }
    ) {
        param($Failure)
        switch ($Failure) {
            'download' { Mock Invoke-WebRequest { throw 'Download failed' } }
            'checksum' { Mock Get-FileHash { [pscustomobject]@{ Hash = 'mismatch' } } }
            'extraction' { Mock Expand-Archive { throw 'Extraction failed' } }
            'incomplete archive' { $script:providerFixtureFiles = @('CredentialProvider.Microsoft.exe') }
            'unusable apphost' { Mock Test-AzArtifactsCredentialProvider { $false } }
        }
        { Install-AzArtifactsCredentialProvider -Architecture X64 } | Should -Throw
        Test-Path -LiteralPath $providerDestination | Should -BeFalse
        @(Get-ChildItem -LiteralPath $providerRoot -Filter '.altered-carbon-*').Count | Should -Be 0
    }
}

Describe 'Module repository configuration' -Tag 'LocalAI' {
    BeforeAll {
        function Register-PSRepository { [CmdletBinding()] param($Name, $SourceLocation, $InstallationPolicy, [switch]$Default) }
        function Get-PSResourceRepository { [CmdletBinding()] param($Name) }
        function Register-PSResourceRepository { [CmdletBinding()] param($Name, $Uri, [switch]$Trusted, $Priority, $CredentialProvider) }
        function Set-PSResourceRepository { [CmdletBinding()] param($Name, $Uri, [switch]$Trusted, $Priority, $CredentialProvider) }
        function Unregister-PSResourceRepository { [CmdletBinding()] param($Name) }
        function Find-PSResource { [CmdletBinding()] param($Name, $Repository) }
        function Save-PSResource { [CmdletBinding()] param($Name, $Repository, $Path, [switch]$AcceptLicense) }
        function Install-PSResource { [CmdletBinding()] param($Name, $Repository, $Scope, [switch]$AcceptLicense) }
        if (-not (Get-Command Get-PSRepository -ErrorAction SilentlyContinue)) {
            function Get-PSRepository { param($Name) }
            function Set-PSRepository { param($Name, $InstallationPolicy) }
            function Unregister-PSRepository { param($Name) }
            function Find-Module { param($Name, $Repository) }
            function Save-Module { param($Name, $Repository, $Path, [switch]$Force, [switch]$AcceptLicense) }
        }
        $macSource = Get-Content (Join-Path $PSScriptRoot '..' 'altered-carbon-mac.sh') -Raw
        $moduleCommand = [regex]::Match($macSource, '(?s)module_result="\$\(ALTERED_CARBON_MODULE_REPOSITORY="\$ps_repository" pwsh -NoProfile -Command "\\\r?\n(?<Program>.*?)"\)"')
        if (-not $moduleCommand.Success) { throw 'Could not isolate the generated macOS pwsh module command.' }
        $script:macModuleProgram = $moduleCommand.Groups['Program'].Value.Replace('\$', '$').Replace('$mod_name', 'Az')
        $repositoryCommand = [regex]::Match($macSource, '(?s)initialize_ps_repository\(\) \{.*?-Command ''(?<Program>.*?)''\r?\n\}')
        if (-not $repositoryCommand.Success) { throw 'Could not isolate the generated macOS repository command.' }
        $script:macRepositoryProgram = [scriptblock]::Create($repositoryCommand.Groups['Program'].Value)
        $script:originalModuleMode = $env:ALTERED_CARBON_MODULE_MODE
        $script:originalModuleRepository = $env:ALTERED_CARBON_MODULE_REPOSITORY
    }
    AfterAll {
        $env:ALTERED_CARBON_MODULE_MODE = $script:originalModuleMode
        $env:ALTERED_CARBON_MODULE_REPOSITORY = $script:originalModuleRepository
    }
    BeforeEach {
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Register-PSRepository {}
        Mock Set-PSRepository {}
        Mock Unregister-PSRepository {}
        Mock Register-PSResourceRepository {}
        Mock Set-PSResourceRepository {}
        Mock Unregister-PSResourceRepository {}
        Mock Get-Module { @() }
        Mock Find-Module { [pscustomobject]@{ Version = [version]'2.0' } }
        Mock Save-Module {}
        Mock Install-Module {}
        Mock Find-PSResource { throw 'Module discovery must remain on PowerShellGet.' }
        Mock Save-PSResource { throw 'Module saves must remain on PowerShellGet.' }
        Mock Install-PSResource { throw 'Module installation must remain on PowerShellGet.' }
        $env:ALTERED_CARBON_MODULE_REPOSITORY = 'PSGallery'
        $env:ALTERED_CARBON_MODULE_MODE = 'personal'
    }

    It 'registers the default gallery only when missing without changing trust' {
        Mock Get-PSRepository { $null }
        Set-PSGalleryTrust
        Should -Invoke Register-PSRepository -Times 1 -Exactly -ParameterFilter { $Default }
        Should -Invoke Set-PSRepository -Times 0
    }

    It 'preserves an existing gallery source and installation policy' {
        Mock Get-PSRepository { [pscustomobject]@{ Name = 'PSGallery'; InstallationPolicy = 'Untrusted'; SourceLocation = 'https://example.invalid/gallery' } }
        Set-PSGalleryTrust
        Should -Invoke Register-PSRepository -Times 0
        Should -Invoke Set-PSRepository -Times 0
    }

    It 'saves outdated modules from PSGallery explicitly rather than an ambient default source' {
        Mock Get-PSRepository {
            @(
                [pscustomobject]@{ Name = 'Contoso.Modules'; InstallationPolicy = 'Trusted' }
                [pscustomobject]@{ Name = 'PSGallery'; InstallationPolicy = 'Untrusted' }
            )
        }
        Mock Find-Module {
            if ($Repository -ne 'PSGallery') { throw 'Unexpected module repository' }
            [pscustomobject]@{ Version = [version]'2.0' }
        }
        Install-PSModules -ModuleDir 'mock-module-directory' -Repository (Initialize-PSModuleRepository)
        Should -Invoke Save-Module -Times 7 -Exactly -ParameterFilter {
            $Repository -eq 'PSGallery' -and $Path -eq 'mock-module-directory' -and $Force -and $AcceptLicense
        }
        Should -Invoke Find-Module -Times 7 -Exactly -ParameterFilter { $Repository -eq 'PSGallery' }
        Should -Invoke Save-Module -Times 0 -ParameterFilter { $Name -eq 'ActiveDirectory' }
    }

    It 'leaves current modules untouched and reports genuine gallery failures' {
        Mock Get-Module { [pscustomobject]@{ Version = [version]'2.0' } }
        Install-PSModules -ModuleDir 'mock-module-directory' -Repository PSGallery
        Should -Invoke Save-Module -Times 0
        Mock Find-Module { throw 'TLS connection failed' }
        Install-PSModules -ModuleDir 'mock-module-directory' -Repository PSGallery
        Should -Invoke Write-Warning -Times 7 -Exactly -ParameterFilter { $Message -like '*TLS connection failed*' }
        Should -Invoke Save-Module -Times 0
        Should -Invoke Set-PSRepository -Times 0
    }

    It 'does not replace a newer installed module with an older gallery version' {
        Mock Get-Module { @([pscustomobject]@{ Version = [version]'1.0' }; [pscustomobject]@{ Version = [version]'3.0' }) }
        Install-PSModules -ModuleDir 'mock-module-directory' -Repository PSGallery
        Should -Invoke Find-Module -Times 7 -Exactly -ParameterFilter { $Repository -eq 'PSGallery' }
        Should -Invoke Save-Module -Times 0
    }

    It 'executes the bash-generated pwsh command against PSGallery with multiple repositories configured' {
        Mock Get-PSRepository {
            @([pscustomobject]@{ Name = 'Contoso.Modules' }; [pscustomobject]@{ Name = 'PSGallery' })
        }
        Mock Find-Module {
            if ($Repository -ne 'PSGallery') { throw 'Unexpected module repository' }
            [pscustomobject]@{ Version = [version]'2.0' }
        }
        & ([scriptblock]::Create($script:macModuleProgram)) | Should -Be 'updated'
        Should -Invoke Find-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Az' -and $Repository -eq 'PSGallery' }
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Az' -and $Repository -eq 'PSGallery' -and $Scope -eq 'CurrentUser' -and $Force -and $AllowClobber -and $AcceptLicense
        }
        Mock Get-Module { @([pscustomobject]@{ Version = [version]'1.0' }; [pscustomobject]@{ Version = [version]'3.0' }) }
        & ([scriptblock]::Create($script:macModuleProgram)) | Should -Be 'current'
        Should -Invoke Install-Module -Times 1 -Exactly
    }

    It 'configures Phase 2 before module discovery and registers PSGallery only in Personal mode' {
        $stage = [regex]::Match($scriptContent, '(?ms)^    if \(\$Work.IsPresent\) \{\r?\n        Install-AzArtifactsCredentialProvider.*?^    Install-PSModules -ModuleDir \$psModuleDir -Repository \$psRepository\r?$')
        $stage.Success | Should -BeTrue
        $phase2Modules = [scriptblock]::Create($stage.Value)
        $script:providerPrepared = $false
        Mock Install-AzArtifactsCredentialProvider { $script:providerPrepared = $true }
        Mock Initialize-PSModuleRepository {
            if ($Work) {
                if (-not $script:providerPrepared) { throw 'Provider must be ready before repository setup' }
                'azure-powershell'
            } else { 'PSGallery' }
        }
        Mock Set-PSGalleryTrust {}
        Mock Install-PSModules {}
        $psModuleDir = 'mock-module-directory'
        $Work = [switch]$true
        $Personal = [switch]$false
        & $phase2Modules
        Should -Invoke Set-PSGalleryTrust -Times 0
        Should -Invoke Install-AzArtifactsCredentialProvider -Times 1 -Exactly
        Should -Invoke Install-PSModules -Times 1 -Exactly -ParameterFilter { $Repository -eq 'azure-powershell' }
        $Work = [switch]$false
        $Personal = [switch]$true
        & $phase2Modules
        Should -Invoke Install-AzArtifactsCredentialProvider -Times 1 -Exactly
        Should -Invoke Set-PSGalleryTrust -Times 1 -Exactly
        Should -Invoke Install-PSModules -Times 1 -Exactly -ParameterFilter { $Repository -eq 'PSGallery' }
        Mock Initialize-PSModuleRepository { throw 'Repository configuration failed' }
        { & $phase2Modules } | Should -Throw '*Repository configuration failed*'
        Should -Invoke Install-PSModules -Times 2 -Exactly
        $Work = [switch]$true
        $Personal = [switch]$false
        Mock Install-AzArtifactsCredentialProvider { throw 'Provider installation failed' }
        { & $phase2Modules } | Should -Throw '*Provider installation failed*'
        Should -Invoke Install-PSModules -Times 2 -Exactly
    }

    Context '<Platform> repository initialization' -ForEach @(
        @{ Platform = 'Windows' }
        @{ Platform = 'macOS' }
    ) {
        BeforeAll {
            function Invoke-RepositorySetup {
                param([switch] $Personal)
                if ($Platform -eq 'Windows') {
                    Initialize-PSModuleRepository -Work:(-not $Personal)
                } else {
                    $env:ALTERED_CARBON_MODULE_MODE = if ($Personal) { 'personal' } else { 'work' }
                    & $script:macRepositoryProgram
                }
            }
        }
        BeforeEach {
            $script:testRepositories = @([pscustomobject]@{ Name = 'Contoso.Modules'; SourceLocation = 'https://modules.example.test/v2'; InstallationPolicy = 'Untrusted' })
            $script:testResourceRepositories = @()
            Mock Get-Command { [pscustomobject]@{ Name = 'Get-PSResourceRepository' } } -ParameterFilter { $Name -eq 'Get-PSResourceRepository' }
            Mock Get-PSRepository { $script:testRepositories }
            Mock Get-PSResourceRepository { $script:testResourceRepositories }
            Mock Register-PSRepository {
                $script:testRepositories += [pscustomobject]@{ Name = $Name; SourceLocation = $SourceLocation; InstallationPolicy = 'Untrusted' }
            }
            Mock Register-PSResourceRepository {
                $script:testResourceRepositories += [pscustomobject]@{ Name = $Name; Uri = $Uri; Trusted = $false; Priority = 37; CredentialProvider = $CredentialProvider }
            }
        }

        It 'registers missing Work sources once and retains selected-repository PowerShellGet module operations' {
            $repository = Invoke-RepositorySetup
            $repository | Should -BeExactly 'azure-powershell'
            Invoke-RepositorySetup | Should -BeExactly $repository
            if ($Platform -eq 'Windows') {
                Install-PSModules -ModuleDir 'mock-module-directory' -Repository $repository
                Should -Invoke Find-Module -Times 7 -Exactly -ParameterFilter { $Repository -eq 'azure-powershell' }
                Should -Invoke Save-Module -Times 7 -Exactly -ParameterFilter { $Repository -eq 'azure-powershell' -and $Path -eq 'mock-module-directory' -and $Force -and $AcceptLicense }
            } else {
                $env:ALTERED_CARBON_MODULE_REPOSITORY = $repository
                & ([scriptblock]::Create($script:macModuleProgram)) | Should -Be 'updated'
                Should -Invoke Find-Module -Times 1 -Exactly -ParameterFilter { $Repository -eq 'azure-powershell' }
                Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Repository -eq 'azure-powershell' -and $Scope -eq 'CurrentUser' -and $Force -and $AllowClobber -and $AcceptLicense }
            }
            Should -Invoke Find-PSResource -Times 0
            Should -Invoke Save-PSResource -Times 0
            Should -Invoke Install-PSResource -Times 0
            Should -Invoke Register-PSRepository -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'azure-powershell' -and $SourceLocation -eq 'https://packagefeedproxy.microsoft.io/powershell/v2' -and -not $InstallationPolicy -and -not $Default
            }
            Should -Invoke Register-PSResourceRepository -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'azure-powershell' -and $Uri -eq 'https://packagefeedproxy.microsoft.io/powershell/v3/index.json' -and $CredentialProvider -eq 'AzArtifacts' -and -not $Trusted -and -not $Priority
            }
            Should -Invoke Set-PSRepository -Times 0
            Should -Invoke Set-PSResourceRepository -Times 0
            Should -Invoke Unregister-PSRepository -Times 0
            Should -Invoke Unregister-PSResourceRepository -Times 0
            $script:testRepositories[0].SourceLocation | Should -Be 'https://modules.example.test/v2'
            $script:testRepositories[0].InstallationPolicy | Should -Be 'Untrusted'
        }

        It 'preserves matching registrations including trust and priority' {
            $script:testRepositories = @([pscustomobject]@{
                Name = 'azure-powershell'; SourceLocation = 'https://packagefeedproxy.microsoft.io/powershell/v2/'; InstallationPolicy = 'Untrusted'
            }; [pscustomobject]@{
                Name = 'PSGallery'; SourceLocation = 'https://modules.example.test/gallery'; InstallationPolicy = 'Untrusted'
            })
            $script:testResourceRepositories = @([pscustomobject]@{
                Name = 'azure-powershell'; Uri = 'https://packagefeedproxy.microsoft.io/powershell/v3/index.json'; Trusted = $false; Priority = 37; CredentialProvider = 1
            }; [pscustomobject]@{
                Name = 'PSGallery'; Uri = 'https://modules.example.test/gallery'; Trusted = $false; Priority = 42
            })
            Invoke-RepositorySetup | Should -Be 'azure-powershell'
            Should -Invoke Register-PSRepository -Times 0
            Should -Invoke Register-PSResourceRepository -Times 0
            Should -Invoke Set-PSRepository -Times 0
            Should -Invoke Set-PSResourceRepository -Times 0
            Should -Invoke Unregister-PSRepository -Times 0
            Should -Invoke Unregister-PSResourceRepository -Times 0
            $script:testRepositories[0].InstallationPolicy | Should -Be 'Untrusted'
            $script:testRepositories[1].Name | Should -Be 'PSGallery'
            $script:testResourceRepositories[0].Trusted | Should -BeFalse
            $script:testResourceRepositories[0].Priority | Should -Be 37
            $script:testResourceRepositories[1].Priority | Should -Be 42
        }

        It 'enables a missing or None provider without changing existing URI trust or priority' -TestCases @(
            @{ ExistingProvider = $null }
            @{ ExistingProvider = 'None' }
        ) {
            param($ExistingProvider)
            $script:testResourceRepositories = @([pscustomobject]@{
                Name = 'azure-powershell'; Uri = 'https://packagefeedproxy.microsoft.io/powershell/v3/index.json'
                Trusted = $false; Priority = 37; CredentialProvider = $ExistingProvider
            })
            Invoke-RepositorySetup | Should -Be 'azure-powershell'
            Should -Invoke Set-PSResourceRepository -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'azure-powershell' -and $CredentialProvider -eq 'AzArtifacts' -and
                -not $PSBoundParameters.ContainsKey('Uri') -and -not $PSBoundParameters.ContainsKey('Trusted') -and -not $PSBoundParameters.ContainsKey('Priority')
            }
            $script:testResourceRepositories[0].Uri | Should -Be 'https://packagefeedproxy.microsoft.io/powershell/v3/index.json'
            $script:testResourceRepositories[0].Trusted | Should -BeFalse
            $script:testResourceRepositories[0].Priority | Should -Be 37
        }

        It 'preserves an unrecognized existing credential provider rather than replacing it' {
            $script:testResourceRepositories = @([pscustomobject]@{
                Name = 'azure-powershell'; Uri = 'https://packagefeedproxy.microsoft.io/powershell/v3/index.json'
                Trusted = $false; Priority = 37; CredentialProvider = 'Contoso.Provider'
            })
            { Invoke-RepositorySetup } | Should -Throw '*unsupported*preserved*'
            Should -Invoke Set-PSResourceRepository -Times 0
            Should -Invoke Register-PSRepository -Times 0
            Should -Invoke Register-PSResourceRepository -Times 0
        }

        It 'leaves a newer installed Work module untouched' {
            Mock Get-Module { [pscustomobject]@{ Version = [version]'3.0' } }
            if ($Platform -eq 'Windows') {
                Install-PSModules -ModuleDir 'mock-module-directory' -Repository 'azure-powershell'
                Should -Invoke Find-Module -Times 7 -Exactly -ParameterFilter { $Repository -eq 'azure-powershell' }
            } else {
                $env:ALTERED_CARBON_MODULE_REPOSITORY = 'azure-powershell'
                $env:ALTERED_CARBON_MODULE_MODE = 'work'
                & ([scriptblock]::Create($script:macModuleProgram)) | Should -Be 'current'
                Should -Invoke Find-Module -Times 1 -Exactly -ParameterFilter { $Repository -eq 'azure-powershell' }
            }
            Should -Invoke Save-Module -Times 0
            Should -Invoke Install-Module -Times 0
            Should -Invoke Find-PSResource -Times 0
            Should -Invoke Save-PSResource -Times 0
            Should -Invoke Install-PSResource -Times 0
        }

        It 'retains per-module handling of Work PowerShellGet <Failure> failures without changing engines' -TestCases @(
            @{ Failure = 'lookup' }
            @{ Failure = 'download' }
        ) {
            param($Failure)
            switch ($Failure) {
                'lookup' { Mock Find-Module { throw 'Module lookup failed' } }
                'download' {
                    Mock Save-Module { throw 'Module download failed' }
                    Mock Install-Module { throw 'Module download failed' }
                }
            }
            if ($Platform -eq 'Windows') {
                { Install-PSModules -ModuleDir 'mock-module-directory' -Repository 'azure-powershell' } | Should -Not -Throw
                Should -Invoke Write-Warning -Times 7 -Exactly -ParameterFilter { $Message -like '*Failed to install or update*failed*' }
                Should -Invoke Find-Module -Times 7 -Exactly -ParameterFilter { $Repository -eq 'azure-powershell' }
            } else {
                $env:ALTERED_CARBON_MODULE_REPOSITORY = 'azure-powershell'
                { & ([scriptblock]::Create($script:macModuleProgram)) } | Should -Throw '*failed*'
                Should -Invoke Find-Module -Times 1 -Exactly -ParameterFilter { $Repository -eq 'azure-powershell' }
            }
            Should -Invoke Find-PSResource -Times 0
            Should -Invoke Save-PSResource -Times 0
            Should -Invoke Install-PSResource -Times 0
        }

        It 'rejects conflicting <Api> registration before any registration or module operation' -TestCases @(
            @{ Api = 'PowerShellGet' }
            @{ Api = 'PSResourceGet' }
        ) {
            param($Api)
            if ($Api -eq 'PowerShellGet') {
                $script:testRepositories = @([pscustomobject]@{ Name = 'azure-powershell'; SourceLocation = 'https://modules.example.test/v2' })
            } else {
                $script:testResourceRepositories = @([pscustomobject]@{ Name = 'azure-powershell'; Uri = 'https://modules.example.test/v3/index.json' })
            }
            { Invoke-RepositorySetup } | Should -Throw '*different source*'
            Should -Invoke Register-PSRepository -Times 0
            Should -Invoke Register-PSResourceRepository -Times 0
            Should -Invoke Find-Module -Times 0
            Should -Invoke Save-Module -Times 0
            Should -Invoke Install-Module -Times 0
            Should -Invoke Set-PSRepository -Times 0
            Should -Invoke Set-PSResourceRepository -Times 0
        }

        It 'propagates <Operation> errors without public fallback or module operations' -TestCases @(
            @{ Operation = 'Get-PSRepository' }
            @{ Operation = 'Get-PSResourceRepository' }
            @{ Operation = 'Register-PSRepository' }
            @{ Operation = 'Register-PSResourceRepository' }
        ) {
            param($Operation)
            Mock $Operation { throw 'Repository operation failed' }
            { Invoke-RepositorySetup } | Should -Throw '*Repository operation failed*'
            Should -Invoke Find-Module -Times 0
            Should -Invoke Save-Module -Times 0
            Should -Invoke Install-Module -Times 0
            Should -Invoke Register-PSRepository -Times 0 -ParameterFilter { $Default -or $Name -eq 'PSGallery' }
        }

        It 'reports unavailable PSResourceGet without bootstrapping it' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-PSResourceRepository' }
            Invoke-RepositorySetup | Should -Be 'azure-powershell'
            Should -Invoke Register-PSRepository -Times 1 -Exactly
            Should -Invoke Get-PSResourceRepository -Times 0
            Should -Invoke Register-PSResourceRepository -Times 0
            Should -Invoke Install-Module -Times 0
        }

        It 'returns the Personal source without inspecting or changing either repository registry' {
            Invoke-RepositorySetup -Personal | Should -Be 'PSGallery'
            Should -Invoke Get-PSRepository -Times 0
            Should -Invoke Get-PSResourceRepository -Times 0
            Should -Invoke Register-PSRepository -Times 0
            Should -Invoke Register-PSResourceRepository -Times 0
            Should -Invoke Set-PSRepository -Times 0
            Should -Invoke Set-PSResourceRepository -Times 0
        }
    }
}

Describe 'Foundry Local emitted Windows artifacts' -Tag 'LocalAI' {
    BeforeAll {
        function Invoke-TestFoundry {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]] $Arguments)
            $global:LASTEXITCODE = 0
            if ($Arguments -contains '--help') { '--port --idle-timeout' } else { '1.0' }
        }
        function winget {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]] $Arguments)
            $script:foundryInstallArguments = $Arguments
            $script:foundryAvailable = $true
            $global:LASTEXITCODE = 0
        }
        function Get-TestFoundryListeners { @() }
        $script:originalFoundryLocalAppData = $env:LOCALAPPDATA
    }

    BeforeEach {
        $env:LOCALAPPDATA = Join-Path $TestDrive "user's local data & apps"
        $script:foundryAvailable = $true
        $script:foundryInstallArguments = @()
        $script:foundryTask = $null
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Start-Sleep {}
        Mock Update-PathFromRegistry {}
        Mock Get-CimInstance { [pscustomobject]@{ BuildNumber = '26100'; ProductType = 1 } }
        Mock Get-Command {
            if ($script:foundryAvailable) { [pscustomobject]@{ Source = 'Invoke-TestFoundry' } }
        } -ParameterFilter { $Name -eq 'foundry' }
        Mock Get-ScheduledTask {
            if ($TaskName) { [pscustomobject]@{ State = 'Running' } } else { $script:foundryTask }
        }
        Mock New-ScheduledTaskAction { [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
        Mock New-ScheduledTaskTrigger {
            [pscustomobject]@{ UserId = $User; Enabled = $true; CimClass = @{ CimClassName = 'MSFT_TaskLogonTrigger' } }
        }
        Mock New-ScheduledTaskPrincipal { [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel } }
        Mock New-ScheduledTaskSettingsSet {
            [pscustomobject]@{
                Enabled = $true; MultipleInstances = $MultipleInstances; DisallowStartIfOnBatteries = $false
                StopIfGoingOnBatteries = $false; ExecutionTimeLimit = 'PT0S'
            }
        }
        Mock Register-ScheduledTask {
            $script:foundryTask = [pscustomobject]@{
                TaskName = $TaskName; Description = $Description; Actions = @($Action); Triggers = @($Trigger)
                Principal = $Principal; Settings = $Settings; State = 'Running'
            }
        }
        Mock Start-ScheduledTask {}
        Mock Stop-ScheduledTask {}
        Mock Test-FoundryReady { $true }
    }

    AfterEach { $env:LOCALAPPDATA = $script:originalFoundryLocalAppData }

    It 'emits a parseable wrapper and quoted task action for paths with spaces and apostrophes' {
        Install-FoundryLocal
        $arguments = $script:foundryTask.Actions[0].Arguments
        $argumentMatch = [regex]::Match($arguments, '\-File "([^"]+)"$')
        $argumentMatch.Success | Should -BeTrue
        $wrapperPath = $argumentMatch.Groups[1].Value
        $wrapperPath | Should -Be (Join-Path $env:LOCALAPPDATA 'altered-carbon\foundry-local\start-foundry.ps1')
        $wrapperErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$null, [ref]$wrapperErrors)
        $wrapperErrors | Should -BeNullOrEmpty
    }

    It 'runs the emitted supervisor safely for <Scenario>' -ForEach @(
        @{ Scenario = 'already healthy'; Healthy = $true; Occupied = $false; ReadyAfterStart = $true }
        @{ Scenario = 'new healthy server'; Healthy = $false; Occupied = $false; ReadyAfterStart = $true }
        @{ Scenario = 'foreign port conflict'; Healthy = $false; Occupied = $true; ReadyAfterStart = $false }
        @{ Scenario = 'readiness failure'; Healthy = $false; Occupied = $false; ReadyAfterStart = $false }
    ) {
        Install-FoundryLocal
        $wrapperPath = Join-Path $env:LOCALAPPDATA 'altered-carbon\foundry-local\start-foundry.ps1'
        $wrapperAst = [System.Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$null, [ref]$null)
        $loop = $wrapperAst.Find({ param($node) $node -is [System.Management.Automation.Language.WhileStatementAst] }, $true)
        $body = $loop.Body.Statements[0].Extent.Text
        # Substitute only the static OS listener probe; run the actual emitted startup branch.
        $body = $body.Replace('[Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()', '(Get-TestFoundryListeners)')
        $script:foundryProbeCount = 0
        Mock Test-FoundryReady {
            $script:foundryProbeCount++
            if ($script:foundryProbeCount -eq 1) { $Healthy } else { $ReadyAfterStart }
        }
        Mock Get-TestFoundryListeners { if ($Occupied) { [pscustomobject]@{ Port = 39839 } } }
        Mock Start-Process {
            $process = [pscustomobject]@{ ExitCode = 0; Id = 12345 }
            $process | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $true } -PassThru
        }
        Mock Stop-Process {}
        $directory = Split-Path -Parent $wrapperPath
        if ($Occupied -or -not $ReadyAfterStart) {
            { & ([scriptblock]::Create($body)) } | Should -Throw
            Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*Foundry Local ready at*' }
        } else {
            & ([scriptblock]::Create($body))
        }
        Should -Invoke Start-Process -Times $(if ($Healthy -or $Occupied) { 0 } else { 1 }) -Exactly
        if (-not $Healthy -and -not $Occupied) {
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'Invoke-TestFoundry' -and
                ($ArgumentList -join ' ') -eq 'server start --port 39839 --idle-timeout 0' -and
                $RedirectStandardOutput -eq (Join-Path $directory 'server-start.log') -and
                $RedirectStandardError -eq (Join-Path $directory 'server-start-error.log')
            }
        }
        Should -Invoke Stop-Process -Times 0
    }
}

Describe 'Phase 2 custom-option handoff' {
    It 'round-trips custom values and skip arrays in <Mode> mode without executing their contents' -ForEach @(
        @{ Mode = 'Work'; IsPersonal = $false }
        @{ Mode = 'Personal'; IsPersonal = $true }
    ) {
        $fixturePath = Join-Path $TestDrive "user's bootstrap.ps1"
        Set-Content -LiteralPath $fixturePath -Value @'
param([switch]$Work, [switch]$Personal, $Phase, $ResumeToken, $OmpTheme, $NerdFont, [string[]]$SkipPackages)
[pscustomobject]@{ Work = $Work.IsPresent; Personal = $Personal.IsPresent; Phase = $Phase; Token = $ResumeToken; Theme = $OmpTheme; Font = $NerdFont; Skip = $SkipPackages }
'@
        $token = [guid]::NewGuid()
        $theme = "user's theme; throw 'not code'"
        $arguments = Get-Phase2TaskArguments -ScriptPath $fixturePath -Personal $IsPersonal -ThemeName $theme -FontName 'FiraCode' -SkipPackages @('Spotify.Spotify', 'Git.Git') -Token $token
        $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($arguments -split ' ')[-1]))
        $result = & ([scriptblock]::Create($command))
        $result.Work | Should -Be (-not $IsPersonal)
        $result.Personal | Should -Be $IsPersonal
        $result.Phase | Should -Be 'Phase2'
        $result.Token | Should -Be $token.ToString()
        $result.Theme | Should -Be $theme
        $result.Font | Should -Be 'FiraCode'
        $result.Skip.Count | Should -Be 2
        $result.Skip | Should -Contain 'Spotify.Spotify'
        $result.Skip | Should -Contain 'Git.Git'
    }

    It 'accepts an empty skip list' {
        $arguments = Get-Phase2TaskArguments -ScriptPath 'C:\bootstrap.ps1' -ThemeName 'night-owl' -FontName 'CodeNewRoman' -Token ([guid]::NewGuid())
        $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($arguments -split ' ')[-1]))
        $command | Should -Not -Match '-SkipPackages'
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($command, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }
}

Describe 'Fresh Windows Terminal configuration' {
    BeforeAll {
        $oldLocalAppData = $env:LOCALAPPDATA
    }
    BeforeEach {
        $env:LOCALAPPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $packagePath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_test'
        $null = New-Item -Path $packagePath -ItemType Directory -Force
        $settingsPath = Join-Path $packagePath 'LocalState\settings.json'
        $previewPath = Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe'
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $previewPath }
        Mock Write-Host {}
        Mock Write-Warning {}
    }
    AfterAll {
        $env:LOCALAPPDATA = $oldLocalAppData
    }

    It 'creates a usable Preview default before Terminal has ever been opened and remains idempotent' {
        Set-WindowsTerminalConfig -FontFaceName 'CodeNewRoman Nerd Font'
        Set-WindowsTerminalConfig -FontFaceName 'CodeNewRoman Nerd Font'
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $settings.profiles.list.Count | Should -Be 1
        $settings.defaultProfile | Should -Be $settings.profiles.list[0].guid
        $settings.profiles.list[0].commandline | Should -Be "`"$previewPath`""
        $settings.profiles.defaults.font.face | Should -Be 'CodeNewRoman Nerd Font'
        Should -Invoke Write-Warning -Times 0
    }

    It 'preserves existing font options and reuses a discovered Preview profile' {
        $null = New-Item -Path (Split-Path $settingsPath) -ItemType Directory -Force
        Set-Content -LiteralPath $settingsPath -Value @'
{
  // Terminal settings support comments.
  "profiles": {
    "defaults": { "font": { "size": 14, "weight": "bold" } },
    "list": [{ "name": "PowerShell Preview", "source": "Windows.Terminal.PowershellCore", "guid": "{test-preview}" }]
  }
}
'@
        Set-WindowsTerminalConfig -FontFaceName 'FiraCode Nerd Font'
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $settings.profiles.list.Count | Should -Be 1
        $settings.defaultProfile | Should -Be '{test-preview}'
        $settings.profiles.defaults.font.size | Should -Be 14
        $settings.profiles.defaults.font.weight | Should -Be 'bold'
        $settings.profiles.defaults.font.face | Should -Be 'FiraCode Nerd Font'
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

Describe 'Standalone Copilot CLI provisioning' -Tag 'BootstrapSafety' {
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

    It 'provisions the standalone package without the retired gh-copilot extension' {
        $functionDefs.Name | Should -Not -Contain 'Install-GitHubCopilotCli'
        $scriptContent | Should -Not -Match '(?i)@github/copilot|gh-copilot|Install-GitHubCopilotCli'
        $packageDefinition = $ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -eq '$corePackages'
        }
        $packages = & ([scriptblock]::Create($packageDefinition.Right.Extent.Text))
        $packages.Id | Should -Contain 'GitHub.cli'
        $packages.Id | Should -Contain 'GitHub.Copilot'
        $commands = $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)
        foreach ($command in $commands) {
            $command.GetCommandName() | Should -Not -Be 'copilot'
            $command.Extent.Text | Should -Not -Match '(?i)\bgh\s+(copilot|extension)\b'
        }
    }

    It 'verifies GitHub CLI and Copilot CLI independently' {
        Show-VerificationSummary
        Should -Invoke Get-CommandVersion -Times 1 -Exactly -ParameterFilter { $Command -eq 'gh' }
        Should -Invoke Get-CommandVersion -Times 1 -Exactly -ParameterFilter { $Command -eq 'copilot' }
        Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'GitHub CLI' -and $Installed -and $Details -eq '1.2.3'
        }
        Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'GitHub Copilot CLI' -and $Installed -and $Details -eq '1.2.3'
        }
        $scriptContent | Should -Match "Id\s*=\s*'GitHub\.cli'"
        $scriptContent | Should -Match "Id\s*=\s*'github\.copilot-chat'"
    }

    It 'reports a missing standalone Copilot even when GitHub CLI is present' {
        Mock Get-CommandVersion { $null } -ParameterFilter { $Command -eq 'copilot' }
        Show-VerificationSummary
        Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'GitHub Copilot CLI' -and -not $Installed
        }
        Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'GitHub CLI' -and $Installed
        }
    }

    It 'still verifies the current Copilot Chat extension in both editors without retired or synthetic results' {
        Mock Get-Command { [pscustomobject]@{ Name = $Name } } -ParameterFilter { $Name -in @('code', 'code-insiders') }
        Show-VerificationSummary
        Should -Invoke Write-VerificationLine -Times 0 -Exactly -ParameterFilter {
            $Label -eq '  GitHub Copilot'
        }
        Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
            $Label -eq '  GitHub Copilot Chat extension for VS Code' -and $Installed
        }
        Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
            $Label -eq '  GitHub Copilot Chat extension for VS Code Insiders' -and $Installed
        }
        Should -Invoke Write-VerificationLine -Times 2 -Exactly -ParameterFilter {
            $Details -eq 'github.copilot-chat' -and $Installed
        }
    }
}

Describe 'Desktop app verification identity' {
    BeforeEach {
        Mock Get-ItemProperty { @() }
        Mock Get-CommandVersion { 'CLI 1.2.3' }
        Mock Get-Command { $null } -ParameterFilter { $Name -in @('code', 'code-insiders') }
        Mock Write-Host {}
        Mock Write-VerificationLine {}
    }

    It 'accepts official <Name> uninstall registrations without requiring a version' -TestCases @(
        @{ Name = 'GitHub Copilot'; Publisher = 'GitHub Inc.' }
        @{ Name = 'GitHub Copilot'; Publisher = 'GitHub, Inc.' }
        @{ Name = 'Podman Desktop'; Publisher = 'Red Hat, Inc.' }
        @{ Name = 'Podman Desktop'; Publisher = 'Red Hat' }
    ) {
        param($Name, $Publisher)
        $script:desktopRegistration = [pscustomobject]@{ DisplayName = $Name; Publisher = $Publisher; DisplayVersion = '' }
        Mock Get-ItemProperty { $script:desktopRegistration }

        Show-VerificationSummary

        Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
            $Label -like "$Name*" -and $Label -in @('GitHub Copilot App (desktop)', 'Podman Desktop') -and
            $Installed -and $Details -eq 'installed (uninstall registration)'
        }
    }

    It 'does not substitute CLI or lookalike registrations for either desktop app' {
        Mock Get-ItemProperty {
            @(
                [pscustomobject]@{ DisplayName = 'GitHub Copilot CLI'; Publisher = 'GitHub Inc.'; DisplayVersion = '1.0' }
                [pscustomobject]@{ DisplayName = 'GitHub Copilot'; Publisher = 'Other Publisher'; DisplayVersion = '1.0' }
                [pscustomobject]@{ DisplayName = 'Podman'; Publisher = 'Red Hat'; DisplayVersion = '1.0' }
                [pscustomobject]@{ DisplayName = 'Podman Desktop'; Publisher = 'Other Publisher'; DisplayVersion = '1.0' }
            )
        }

        Show-VerificationSummary

        Should -Invoke Write-VerificationLine -Times 2 -Exactly -ParameterFilter {
            $Label -in @('GitHub Copilot App (desktop)', 'Podman Desktop') -and -not $Installed -and -not $Details
        }
        Should -Invoke Write-VerificationLine -Times 2 -Exactly -ParameterFilter {
            $Label -in @('GitHub Copilot CLI', 'Podman CLI') -and $Installed -and $Details -eq 'CLI 1.2.3'
        }
    }

    It 'reports registered desktop versions independently of missing CLIs' {
        Mock Get-CommandVersion { $null }
        Mock Get-ItemProperty {
            @(
                [pscustomobject]@{ DisplayName = 'GitHub Copilot'; Publisher = 'GitHub Inc.'; DisplayVersion = '2.3.4' }
                [pscustomobject]@{ DisplayName = 'Podman Desktop'; Publisher = 'Red Hat'; DisplayVersion = '5.6.7' }
            )
        }

        Show-VerificationSummary

        Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'GitHub Copilot App (desktop)' -and $Installed -and $Details -eq '2.3.4'
        }
        Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'Podman Desktop' -and $Installed -and $Details -eq '5.6.7'
        }
        Should -Invoke Write-VerificationLine -Times 2 -Exactly -ParameterFilter {
            $Label -in @('GitHub Copilot CLI', 'Podman CLI') -and -not $Installed
        }
    }
}

Describe 'Editor Copilot Chat package verification' -Tag 'CopilotVerification' {
    BeforeAll {
        function code {
            param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
            Invoke-TestEditor -Editor 'code' -Arguments $Arguments
        }
        function code-insiders {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Test double for the editor CLI command.')]
            param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
            Invoke-TestEditor -Editor 'code-insiders' -Arguments $Arguments
        }
        function Invoke-TestEditor {
            param([string] $Editor, [string[]] $Arguments)
            $script:editorCalls.Add(@{ Editor = $Editor; Arguments = $Arguments })
            switch ($Arguments[0]) {
                '--list-extensions' {
                    if ($script:listThrows) { throw 'listing unavailable' }
                    $global:LASTEXITCODE = $script:listExitCode
                    $script:listedExtensions
                }
                '--locate-extension' {
                    if ($script:locateThrows) { throw 'locate unavailable' }
                    $global:LASTEXITCODE = $script:locateExitCode
                    $script:locatedPaths
                }
                '--install-extension' {
                    if ($script:installThrows) { throw 'installation denied' }
                    $global:LASTEXITCODE = $script:installExitCode
                    'mock installer diagnostic'
                }
                default { throw "Unexpected editor invocation: $Arguments" }
            }
        }
        $copilotSandbox = Join-Path $PSScriptRoot ".sandbox\copilot-$([guid]::NewGuid())"
        $null = New-Item -Path $copilotSandbox -ItemType Directory -Force
        $script:manifestPath = Join-Path $copilotSandbox 'package.json'
    }

    AfterAll {
        Remove-Item -LiteralPath $copilotSandbox -Recurse -Force
    }

    Context '<EditorLabel>' -ForEach @(
        @{ Editor = 'code'; EditorLabel = 'VS Code' }
        @{ Editor = 'code-insiders'; EditorLabel = 'VS Code Insiders' }
    ) {
        BeforeEach {
            $script:selectedEditor = $Editor
            $script:expectedLabel = "  GitHub Copilot Chat extension for $EditorLabel"
            $script:expectedInstallLabel = "GitHub Copilot Chat extension for $EditorLabel (github.copilot-chat)"
            $script:editorCalls = [System.Collections.Generic.List[hashtable]]::new()
            $script:listedExtensions = @(
                'ms-azuretools.vscode-azureresourcegroups'
                'ms-azuretools.vscode-bicep'
                'ms-azuretools.vscode-azure-github-copilot'
                'ms-windows-ai-studio.windows-ai-studio'
                'ms-security.ms-sentinel'
            )
            $script:locatedPaths = @($copilotSandbox)
            $script:listExitCode = 0
            $script:locateExitCode = 0
            $script:installExitCode = 0
            $script:listThrows = $false
            $script:locateThrows = $false
            $script:installThrows = $false
            '{"publisher":"GitHub","name":"copilot-chat","version":"0.69.0"}' |
                Set-Content -LiteralPath $manifestPath
            Mock Get-Command {
                if ($Name -eq $script:selectedEditor) { [pscustomobject]@{ Name = $Name } }
            } -ParameterFilter { $Name -in @('code', 'code-insiders') }
            Mock Get-CommandVersion { '1.2.3' }
            Mock Write-VerificationLine {}
            Mock Write-Host {}
            Mock Write-Warning {}
        }

        It 'accepts a listed user extension without locating or reinstalling it' {
            $script:listedExtensions += 'github.copilot-chat'
            Show-VerificationSummary
            Install-VSCodeExtensions
            Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
                $Label -eq $script:expectedLabel -and $Installed -and $Details -eq 'github.copilot-chat'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq "  Skipped: $script:expectedInstallLabel already installed."
            }
            @($script:editorCalls | Where-Object { $_.Arguments[0] -ne '--list-extensions' }).Count | Should -Be 0
        }

        It 'verifies an editor-included exact package and skips reinstalling it' {
            Show-VerificationSummary
            Install-VSCodeExtensions
            Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
                $Label -eq $script:expectedLabel -and $Installed -and
                $Details -eq 'github.copilot-chat (included with editor, version 0.69.0; presence only)'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq "  Skipped: $script:expectedInstallLabel - github.copilot-chat (included with editor, version 0.69.0; presence only)."
            }
            @($script:editorCalls | Where-Object { $_.Arguments[0] -eq '--install-extension' }).Count | Should -Be 0
            @($script:editorCalls | Where-Object {
                $_.Editor -eq $script:selectedEditor -and
                ($_.Arguments -join ' ') -eq '--locate-extension github.copilot-chat'
            }).Count | Should -Be 2
            Should -Invoke Write-Warning -Times 0 -Exactly
        }

        It 'reports genuinely missing Chat separately from Copilot CLI and installs the exact extension' {
            $script:locatedPaths = @()
            $script:listedExtensions += 'github.copilot'
            Show-VerificationSummary
            Install-VSCodeExtensions
            Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
                $Label -eq $script:expectedLabel -and -not $Installed -and
                $Details -eq "github.copilot-chat; not found or could not be verified. Check Extensions in $EditorLabel; this is not Copilot CLI"
            }
            @($script:editorCalls | Where-Object {
                $_.Editor -eq $script:selectedEditor -and
                ($_.Arguments -join ' ') -eq '--install-extension github.copilot-chat --force'
            }).Count | Should -Be 1
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq "  Done: $script:expectedInstallLabel"
            }
        }

        It 'rejects <Fixture> rather than claiming an included Chat package' -ForEach @(
            @{ Fixture = 'wrong publisher'; Manifest = '{"publisher":"other","name":"copilot-chat","version":"1.0"}' }
            @{ Fixture = 'legacy extension'; Manifest = '{"publisher":"github","name":"copilot","version":"1.0"}' }
            @{ Fixture = 'missing version'; Manifest = '{"publisher":"github","name":"copilot-chat"}' }
            @{ Fixture = 'malformed manifest'; Manifest = '{not JSON' }
            @{ Fixture = 'missing manifest'; Manifest = $null }
            @{ Fixture = 'relative package path'; Manifest = '{}'; RelativePath = $true }
        ) {
            if ($null -eq $Manifest) {
                Remove-Item -LiteralPath $manifestPath
            } else {
                Set-Content -LiteralPath $manifestPath -Value $Manifest
            }
            if ($RelativePath) { $script:locatedPaths = @('relative-extension-directory') }
            Get-VSCodeCopilotDetails -Editor $Editor | Should -BeNullOrEmpty
            Show-VerificationSummary
            Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
                $Label -eq $script:expectedLabel -and -not $Installed -and
                $Details -like 'github.copilot-chat; not found or could not be verified.*'
            }
        }

        It 'rejects a <Failure> locate even with a valid manifest path' -ForEach @(
            @{ Failure = 'nonzero'; ExitCode = 17; Throws = $false }
            @{ Failure = 'throwing'; ExitCode = 0; Throws = $true }
        ) {
            $script:locateExitCode = $ExitCode
            $script:locateThrows = $Throws
            Get-VSCodeCopilotDetails -Editor $Editor | Should -BeNullOrEmpty
            Show-VerificationSummary
            Should -Invoke Write-VerificationLine -Times 1 -Exactly -ParameterFilter {
                $Label -eq $script:expectedLabel -and -not $Installed
            }
        }

        It 'warns on a <Failure> list without claiming absence or installing extensions' -ForEach @(
            @{ Failure = 'nonzero'; ExitCode = 23; Throws = $false; Diagnostic = 'extension listing exited with code 23' }
            @{ Failure = 'throwing'; ExitCode = 0; Throws = $true; Diagnostic = 'listing unavailable' }
        ) {
            $script:listExitCode = $ExitCode
            $script:listThrows = $Throws
            $script:listedExtensions += 'github.copilot-chat'
            Show-VerificationSummary
            Install-VSCodeExtensions
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Could not verify extensions for ${EditorLabel}: $Diagnostic"
            }
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Could not check extensions for ${EditorLabel}: $Diagnostic"
            }
            Should -Invoke Write-VerificationLine -Times 0 -Exactly -ParameterFilter { $Label -like '* extension for *' }
            @($script:editorCalls | Where-Object { $_.Arguments[0] -ne '--list-extensions' }).Count | Should -Be 0
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*Done:*' }
        }

        It 'reports a <Failure> install with editor and ID but never Done' -ForEach @(
            @{ Failure = 'nonzero'; ExitCode = 31; Throws = $false; Diagnostic = 'exit code 31: mock installer diagnostic' }
            @{ Failure = 'throwing'; ExitCode = 0; Throws = $true; Diagnostic = 'installation denied' }
        ) {
            $script:locatedPaths = @()
            $script:installExitCode = $ExitCode
            $script:installThrows = $Throws
            Install-VSCodeExtensions
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Could not install ${script:expectedInstallLabel}: $Diagnostic"
            }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*Done:*' }
        }
    }
}

Describe 'Phase 2 Spotify outcomes' -Tag 'SpotifyVerification' {
    BeforeAll {
        function winget {
            param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
            throw "Unmocked Spotify command: $Arguments"
        }
        $spotifyAssignment = $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$spotifyOutput'
        }, $true)
        $spotifyOutcome = $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$LASTEXITCODE -eq 0' -and
            $node.Extent.Text -match 'Done: Spotify installed'
        }, $true)
        $spotifyAssignment.Count | Should -Be 1
        $spotifyOutcome.Count | Should -Be 1
        # Execute only the isolated Spotify command and its outcome handler.
        $script:runSpotify = [scriptblock]::Create($spotifyAssignment.Extent.Text + "`n" + $spotifyOutcome.Extent.Text)
        foreach ($constant in $wingetConstants.GetEnumerator()) {
            Set-Variable -Name $constant.Key -Value $constant.Value
        }
    }

    BeforeEach {
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock winget {
            $global:LASTEXITCODE = $script:spotifyExitCode
            'mock Spotify output'
        }
    }

    It 'skips the confirmed no-applicable-upgrade outcome without warning or a redundant presence probe' {
        $script:spotifyExitCode = -1978335189
        & $runSpotify
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq '  Skipped: Spotify is already up to date.'
        }
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*Done:*' }
        Should -Invoke Write-Warning -Times 0 -Exactly
        Should -Invoke winget -Times 1 -Exactly
        Should -Invoke winget -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -eq 'install --id Spotify.Spotify --source winget --accept-source-agreements --accept-package-agreements --silent'
        }
    }

    It 'still reports a successful installation as Done' {
        $script:spotifyExitCode = 0
        & $runSpotify
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq '  Done: Spotify installed.' }
        Should -Invoke Write-Warning -Times 0 -Exactly
    }

    It 'does not suppress genuine unexpected Spotify failures' {
        $script:spotifyExitCode = 42
        & $runSpotify
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -eq '  winget exited with code 42 for Spotify'
        }
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -match 'Done:|Skipped:' }
    }

    It 'honors an explicit Spotify skip during Phase 2' {
        $skipGuard = $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '''Spotify.Spotify'' -notin $SkipPackages'
        }, $true)
        $skipGuard.Count | Should -Be 1
        $SkipPackages = @('Spotify.Spotify')
        & ([scriptblock]::Create($skipGuard.Extent.Text))
        Should -Invoke winget -Times 0
    }
}

Describe 'Per-user Nerd Font setup' {
    BeforeAll {
        function oh-my-posh { param([Parameter(ValueFromRemainingArguments)] [string[]]$Arguments) }
    }
    BeforeEach {
        Mock Write-Host {}
        Mock Get-Command { [pscustomobject]@{ Name = 'oh-my-posh' } } -ParameterFilter { $Name -eq 'oh-my-posh' }
        Mock Test-Path { $true }
        Mock Get-ItemProperty { [pscustomobject]@{} }
        Mock Start-Process { throw 'Font setup must not elevate' }
        Mock Copy-Item { throw 'Font setup must not promote fonts into Windows Fonts' }
        Mock oh-my-posh { $global:LASTEXITCODE = 0 }
    }

    It 'reuses installed per-user fonts without requesting elevation or reinstalling' {
        Mock Get-ItemProperty {
            [pscustomobject]@{
                'CodeNewRoman Nerd Font Regular (TrueType)' = 'regular.ttf'
                'CodeNewRoman Nerd Font Mono Regular (TrueType)' = 'mono.ttf'
            }
        } -ParameterFilter { $Path -like 'HKCU:*' }

        $font = Install-NerdFont -FontName 'CodeNewRoman'
        $font.Face | Should -Be 'CodeNewRoman Nerd Font'
        $font.Mono | Should -Be 'CodeNewRoman Nerd Font Mono'
        Should -Invoke oh-my-posh -Times 0
        Should -Invoke Start-Process -Times 0
        Should -Invoke Copy-Item -Times 0
    }

    It 'installs a missing font in the current user session without promotion' {
        $font = Install-NerdFont -FontName 'FiraCode'
        $font.Face | Should -Be 'FiraCode Nerd Font'
        Should -Invoke oh-my-posh -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -eq 'font install FiraCode'
        }
        Should -Invoke Start-Process -Times 0
        Should -Invoke Copy-Item -Times 0
    }
}

Describe 'Phase 2 one-shot resume safety' -Tag 'BootstrapSafety' {
    BeforeAll {
        $resumeGuard = $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$Phase -eq ''Phase2'''
        }, $false) | Select-Object -First 1
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

    It 'retires the logon task before checking Phase 2 host and elevation requirements' {
        $contextGuards = $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -like '$Phase -eq ''Phase2'' -and*'
        }, $true)
        $contextGuards.Count | Should -Be 2
        foreach ($guard in $contextGuards) {
            $guard.Extent.StartOffset | Should -BeGreaterThan $resumeGuard.Extent.EndOffset
        }
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
    BeforeEach {
        Mock Test-Path { $false }
        Mock New-Item {}
        Mock Set-ItemProperty {}
        Mock Remove-ItemProperty {}
        Mock Remove-Item {}
        Mock Start-Process {}
        Mock Write-Host {}
        Mock Write-Warning {}
    }

    It 'preserves all four unrelated Explorer preferences on repeated runs' {
        Set-FileExplorerOptions
        Set-FileExplorerOptions

        foreach ($preference in @(
            @{ Key = 'Advanced'; Name = 'HideFileExt'; Value = 0 }
            @{ Key = 'Advanced'; Name = 'Hidden'; Value = 1 }
            @{ Key = 'Advanced'; Name = 'ShowSuperHidden'; Value = 1 }
            @{ Key = 'CabinetState'; Name = 'FullPath'; Value = 1 }
        )) {
            Should -Invoke Set-ItemProperty -Times 2 -Exactly -ParameterFilter {
                $Path -eq "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\$($preference.Key)" -and
                $Name -eq $preference.Name -and $Value -eq $preference.Value
            }
        }
        Should -Invoke Set-ItemProperty -Times 8 -Exactly
        Should -Invoke Write-Warning -Times 0
    }

    It 'neither creates nor changes nor removes existing run-as policy, and opens no misleading Settings page' {
        Set-FileExplorerOptions
        Should -Invoke New-Item -Times 0
        Should -Invoke Remove-ItemProperty -Times 0
        Should -Invoke Remove-Item -Times 0
        Should -Invoke Start-Process -Times 0
        Should -Invoke Set-ItemProperty -Times 0 -ParameterFilter {
            $Path -like '*\Policies\*' -or $Name -eq 'ShowRunAsDifferentUserInStart'
        }
        ($functionDefs | Where-Object Name -EQ 'Set-FileExplorerOptions').Extent.Text |
            Should -Not -Match 'ShowRunAsDifferentUserInStart|ms-settings:'
    }

    It 'warns without falsely claiming success when an unrelated Explorer write is denied' {
        Mock Set-ItemProperty { throw 'Explorer preference denied' }
        { Set-FileExplorerOptions } | Should -Not -Throw
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -like '*Failed to configure File Explorer options*Explorer preference denied*'
        }
        Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*Done:*' }
    }
}

Describe 'Persistent setup reports' -Tag 'SetupReports' {
    BeforeAll {
        $sandbox = Join-Path $PSScriptRoot ".sandbox\reports-$([guid]::NewGuid())"
        $script:reportLocalAppData = $env:LOCALAPPDATA
        $null = New-Item -Path $sandbox -ItemType Directory -Force
    }
    BeforeEach {
        $env:LOCALAPPDATA = $sandbox
        $script:verificationResults = [System.Collections.Generic.List[object]]::new()
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Start-Process {}
    }
    AfterAll {
        $env:LOCALAPPDATA = $script:reportLocalAppData
        $script:verificationResults = $null
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }

    It 'collects accurate presence results without retaining console indentation' {
        Write-VerificationLine -Label '  present tool' -Installed $true -Details 'v1'
        Write-VerificationLine -Label '  missing tool' -Installed $false -Details 'not verified'
        $verificationResults.Count | Should -Be 2
        $verificationResults[0].Check | Should -Be 'present tool'
        $verificationResults[0].Status | Should -Be 'OK'
        $verificationResults[0].Details | Should -Be 'v1'
        $verificationResults[1].Status | Should -Be 'MISSING / NOT VERIFIED'
        $verificationResults[1].Details | Should -Be 'not verified'
    }

    It 'persists a completed report at its documented path even with missing optional checks' {
        $path = Write-SetupReport -Phase Phase2 -TranscriptPath 'C:\logs\.altered-carbon-test.log' -Results @(
            [pscustomobject]@{ Check = 'optional tool'; Status = 'MISSING / NOT VERIFIED'; Details = 'not installed' }
        )
        $path | Should -Be (Join-Path $sandbox 'altered-carbon\reports\.altered-carbon-test-Phase2.html')
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $html = Get-Content -LiteralPath $path -Raw
        $html | Should -Match '<h2>Completed</h2>'
        $html | Should -Match 'MISSING / NOT VERIFIED'
        $html | Should -Match 'not that every optional installation succeeded'
        $html | Should -Match ([regex]::Escape('C:\logs\.altered-carbon-test.log'))
        $html | Should -Not -Match '<h2>Failure</h2>'
        Should -Invoke Start-Process -Times 0
    }

    It 'escapes phase, transcript, error, and every verification cell as HTML text' {
        $payload = '<script>alert("x" & ''y'')</script>'
        $path = Write-SetupReport -Phase 'Phase2 & review' -TranscriptPath 'C:\logs\a&b.log' -FailureMessage $payload -Results @(
            [pscustomobject]@{ Check = $payload; Status = $payload; Details = $payload }
        )
        $html = Get-Content -LiteralPath $path -Raw
        $html | Should -Match '<h2>Failed / incomplete</h2>'
        $html | Should -Match 'Phase2 &amp; review'
        $html | Should -Match 'a&amp;b\.log'
        $html | Should -Not -Match ([regex]::Escape($payload))
        [regex]::Matches($html, '&lt;script&gt;').Count | Should -Be 4
        $html | Should -Match 'without -ResumeToken'
        $html | Should -Match 'Phase1 as administrator'
    }

    It 'persists early <RunPhase> failures with explicit absent-verification guidance' -ForEach @(
        @{ RunPhase = 'Phase1' }
        @{ RunPhase = 'Phase2' }
    ) {
        $path = Write-SetupReport -Phase $RunPhase -TranscriptPath 'C:\logs\early.log' -FailureMessage 'Initialization failed'
        $html = Get-Content -LiteralPath $path -Raw
        $html | Should -Match '<h2>Failed / incomplete</h2>'
        $html | Should -Match '<pre>Initialization failed</pre>'
        $html | Should -Match 'No verification results were collected'
        $html | Should -Not -Match '<h2>Completed</h2>'
    }

    It 'keeps the report when browser launch fails and prints a manual-open path' {
        $path = Write-SetupReport -Phase Phase2 -TranscriptPath 'C:\logs\browser.log'
        Mock Start-Process { throw 'No HTML association' }
        { Open-SetupReport -Path $path } | Should -Not -Throw
        Test-Path -LiteralPath $path | Should -BeTrue
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $path -and $ErrorAction -eq 'Stop'
        }
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq "Setup report saved: $path" }
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -like "*Open '$path' manually*No HTML association*"
        }
    }

    It 'requests the saved report in the default browser without promising a visible tab' {
        Open-SetupReport -Path 'C:\reports\existing.html'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\reports\existing.html' -and $ErrorAction -eq 'Stop'
        }
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like '*if no page appears*manually*' }
        Should -Invoke Write-Warning -Times 0
    }

    It 'propagates <Operation> failures instead of returning a false saved path' -ForEach @(
        @{ Operation = 'directory creation' }
        @{ Operation = 'file write' }
    ) {
        if ($Operation -eq 'directory creation') {
            Mock New-Item { throw 'Report storage denied' }
        } else {
            Mock Set-Content { throw 'Report storage denied' }
        }
        { Write-SetupReport -Phase Phase2 -TranscriptPath 'C:\logs\denied.log' } |
            Should -Throw '*Report storage denied*'
        Should -Invoke Start-Process -Times 0
    }

    It 'can save repeatedly without appending HTML or losing other runs and phases' {
        $first = Write-SetupReport -Phase Phase2 -TranscriptPath 'C:\logs\first.log'
        $second = Write-SetupReport -Phase Phase2 -TranscriptPath 'C:\logs\second.log'
        $failed = Write-SetupReport -Phase Phase1 -TranscriptPath 'C:\logs\first.log' -FailureMessage 'early failure'
        Write-SetupReport -Phase Phase2 -TranscriptPath 'C:\logs\first.log' | Should -Be $first
        foreach ($path in @($first, $second, $failed)) { Test-Path -LiteralPath $path | Should -BeTrue }
        [regex]::Matches((Get-Content -LiteralPath $first -Raw), '<!doctype html>').Count | Should -Be 1
        Get-Content -LiteralPath $failed -Raw | Should -Match '<h2>Failed / incomplete</h2>'
    }
}

Describe 'Report finalization and original failure preservation' -Tag 'SetupReports' {
    BeforeAll {
        # Replace only the orchestration body. Execute the real catch/finally/rethrow
        # without installs, scheduler, profile, registry, or transcript mutations.
        $mainTry = $ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.TryStatementAst] -and
            $_.Body.Extent.Text -match 'Test-WingetAvailable'
        } | Select-Object -First 1
        $mainTry | Should -Not -BeNullOrEmpty
        $finalThrow = $ast.EndBlock.Statements[-1]
        $finalThrow.Extent.Text | Should -Be 'if ($runFailure) { throw $runFailure }'
        $finalizationCode = '$runFailure = $null' + "`n" +
            $mainTry.Extent.Text.Replace($mainTry.Body.Extent.Text, '{ Invoke-TestOrchestration }') +
            "`n" + $finalThrow.Extent.Text
        $script:runFinalization = [scriptblock]::Create($finalizationCode)
        $script:openReportBody = (Get-Command Open-SetupReport).ScriptBlock
        function Invoke-TestOrchestration { throw 'Must be mocked' }
        $sandbox = Join-Path $PSScriptRoot ".sandbox\finalization-$([guid]::NewGuid())"
        $null = New-Item -Path $sandbox -ItemType Directory -Force
    }
    BeforeEach {
        $script:Phase = 'Phase2'
        $script:logFile = 'C:\logs\finalization.log'
        $script:verificationResults = [System.Collections.Generic.List[object]]::new()
        $script:originalFailure = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new('Original orchestration failure'),
            'OriginalFailure', [System.Management.Automation.ErrorCategory]::OperationStopped, $null
        )
        Mock Invoke-TestOrchestration {}
        Mock Write-SetupReport { 'C:\reports\saved.html' }
        Mock Open-SetupReport {}
        Mock Stop-Transcript {}
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Write-Verbose {}
    }
    AfterAll {
        $script:verificationResults = $null
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }

    It 'saves collected Phase2 results before opening and stopping the transcript' {
        Mock Invoke-TestOrchestration { Write-VerificationLine -Label 'tool' -Installed $true -Details 'v2' }
        Mock Open-SetupReport {
            Should -Invoke Write-SetupReport -Times 1 -Exactly
            Should -Invoke Stop-Transcript -Times 0
        }
        { & $runFinalization } | Should -Not -Throw
        Should -Invoke Write-SetupReport -Times 1 -Exactly -ParameterFilter {
            $Phase -eq 'Phase2' -and $TranscriptPath -eq $logFile -and
            -not $FailureMessage -and $Results.Count -eq 1 -and
            $Results[0].Check -eq 'tool' -and $Results[0].Status -eq 'OK'
        }
        Should -Invoke Open-SetupReport -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\reports\saved.html' }
        Should -Invoke Stop-Transcript -Times 1 -Exactly
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like '*Setup complete*' }
    }

    It 'does not call Phase1 handoff full setup completion or create a completed report' {
        $script:Phase = 'Phase1'
        { & $runFinalization } | Should -Not -Throw
        Should -Invoke Write-SetupReport -Times 0
        Should -Invoke Open-SetupReport -Times 0
        Should -Invoke Stop-Transcript -Times 1 -Exactly
        Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*Setup complete*' }
    }

    It 'saves an incomplete report and rethrows the original <RunPhase> error record' -ForEach @(
        @{ RunPhase = 'Phase1' }
        @{ RunPhase = 'Phase2' }
    ) {
        $script:Phase = $RunPhase
        Mock Invoke-TestOrchestration { throw $script:originalFailure }
        $caught = $null
        try { & $runFinalization } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        [object]::ReferenceEquals($caught.Exception, $originalFailure.Exception) | Should -BeTrue
        $caught.FullyQualifiedErrorId | Should -Be 'OriginalFailure'
        Should -Invoke Write-SetupReport -Times 1 -Exactly -ParameterFilter {
            $Phase -eq $RunPhase -and $FailureMessage -eq 'Original orchestration failure' -and $Results.Count -eq 0
        }
        Should -Invoke Open-SetupReport -Times 1 -Exactly
        Should -Invoke Stop-Transcript -Times 1 -Exactly
        Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*Setup complete*' }
    }

    It 'fails a previously successful run if report persistence fails, without opening or claiming completion' {
        Mock Write-SetupReport { throw 'Report disk full' }
        { & $runFinalization } | Should -Throw '*Report disk full*'
        Should -Invoke Open-SetupReport -Times 0
        Should -Invoke Stop-Transcript -Times 1 -Exactly
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*Could not save*Report disk full*' }
        Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*Setup complete*' }
    }

    It 'does not change the original <Outcome> outcome when the browser cannot launch' -ForEach @(
        @{ Outcome = 'successful'; OperationFails = $false }
        @{ Outcome = 'failed'; OperationFails = $true }
    ) {
        Mock Start-Process { throw 'Browser unavailable' }
        Mock Open-SetupReport { & $script:openReportBody -Path $Path }
        if ($OperationFails) { Mock Invoke-TestOrchestration { throw $script:originalFailure } }
        $caught = $null
        try { & $runFinalization } catch { $caught = $_ }
        if ($OperationFails) {
            [object]::ReferenceEquals($caught.Exception, $originalFailure.Exception) | Should -BeTrue
        } else {
            $caught | Should -BeNullOrEmpty
        }
        Should -Invoke Write-SetupReport -Times 1 -Exactly
        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Stop-Transcript -Times 1 -Exactly
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*manually*Browser unavailable*' }
        Should -Invoke Write-Warning -Times 0 -ParameterFilter { $Message -like '*Could not save*' }
    }

    It 'preserves the original error when reporting and transcript shutdown also fail' {
        Mock Invoke-TestOrchestration { throw $script:originalFailure }
        Mock Write-SetupReport { throw 'Secondary report failure' }
        Mock Stop-Transcript { throw 'Secondary transcript failure' }
        $caught = $null
        try { & $runFinalization } catch { $caught = $_ }
        [object]::ReferenceEquals($caught.Exception, $originalFailure.Exception) | Should -BeTrue
        $caught.FullyQualifiedErrorId | Should -Be 'OriginalFailure'
        Should -Invoke Open-SetupReport -Times 0
        Should -Invoke Stop-Transcript -Times 1 -Exactly
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*Secondary report failure*' }
        Should -Invoke Write-Verbose -Times 1 -ParameterFilter { $Message -like '*Secondary transcript failure*' }
    }

    It 'tolerates an inactive transcript after successful report saving' {
        Mock Stop-Transcript { throw 'Not transcribing' }
        { & $runFinalization } | Should -Not -Throw
        Should -Invoke Write-Verbose -Times 1 -ParameterFilter { $Message -like '*Not transcribing*' }
    }

    It 'returns the correct native exit status for <Scenario>' -ForEach @(
        @{ Scenario = 'success'; OperationFails = $false; ReportFails = $false; ExpectedExit = 0; ExpectedError = '' }
        @{ Scenario = 'orchestration failure'; OperationFails = $true; ReportFails = $false; ExpectedExit = 1; ExpectedError = 'ORIGINAL_SENTINEL' }
        @{ Scenario = 'report failure'; OperationFails = $false; ReportFails = $true; ExpectedExit = 1; ExpectedError = 'REPORT_SENTINEL' }
        @{ Scenario = 'both failures'; OperationFails = $true; ReportFails = $true; ExpectedExit = 1; ExpectedError = 'ORIGINAL_SENTINEL' }
    ) {
        $operationBody = if ($OperationFails) { "throw 'ORIGINAL_SENTINEL'" } else { '' }
        $reportBody = if ($ReportFails) { "throw 'REPORT_SENTINEL'" } else { "'saved.html'" }
        $fixture = @"
`$ErrorActionPreference = 'Stop'
`$Phase = 'Phase2'
`$logFile = 'test.log'
`$script:verificationResults = [System.Collections.Generic.List[object]]::new()
function Invoke-TestOrchestration { $operationBody }
function Write-SetupReport { $reportBody }
function Open-SetupReport {}
function Stop-Transcript { throw 'TRANSCRIPT_SENTINEL' }
$finalizationCode
"@
        $fixturePath = Join-Path $sandbox "$([guid]::NewGuid()).ps1"
        Set-Content -LiteralPath $fixturePath -Value $fixture -Encoding UTF8
        $output = & pwsh -NoProfile -File $fixturePath 2>&1
        $LASTEXITCODE | Should -Be $ExpectedExit
        if ($ExpectedError) {
            ($output -join "`n") | Should -Match $ExpectedError
        }
        Remove-Item -LiteralPath $fixturePath -Force
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
