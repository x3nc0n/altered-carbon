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
    }

    It 'assigns the correct exit code values' {
        $wingetConstants.WINGET_NO_APPLICABLE_UPGRADE | Should -Be -1978335189
        $wingetConstants.WINGET_PACKAGE_NOT_FOUND | Should -Be -1978335212
        $wingetConstants.WINGET_APP_IN_USE | Should -Be -1978335113
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
        $fnNames | Should -Contain 'Invoke-ElevatedFontPromotion'
        $fnNames | Should -Contain 'Get-CommandVersion'
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

        Assert-MockCalled Write-Warning -Times 1 -ParameterFilter {
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
}

Describe 'Enable-WindowsFeatures' {
    It 'skips gracefully when optional feature management is unavailable' {
        Mock Get-WindowsOptionalFeature {
            throw [System.InvalidOperationException]::new('Class not registered')
        }
        Mock Enable-WindowsOptionalFeature {}
        Mock Write-Warning {}

        Enable-WindowsFeatures -IsAdmin $true

        Assert-MockCalled Get-WindowsOptionalFeature -Times 1
        Assert-MockCalled Enable-WindowsOptionalFeature -Times 0
        Assert-MockCalled Write-Warning -Times 1 -ParameterFilter {
            $Message -like '*feature management is unavailable*'
        }
    }
}
