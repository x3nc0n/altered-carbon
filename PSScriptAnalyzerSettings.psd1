@{
    # PSScriptAnalyzer settings for altered-carbon
    # This is an installation/bootstrap script — some rules don't apply.

    Severity = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # The script uses Write-Host intentionally for colored console output during setup.
        'PSAvoidUsingWriteHost'

        # Invoke-Expression is used deliberately for oh-my-posh init piping,
        # which is the documented usage pattern from oh-my-posh.
        'PSAvoidUsingInvokeExpression'

        # ConvertTo-SecureString is not used, but the bootstrapping pattern
        # (downloading Chocolatey install.ps1) triggers this heuristic.
        'PSAvoidUsingConvertToSecureStringWithPlainText'

        # The script is intentionally a monolithic bootstrap — not a module.
        'PSUseShouldProcessForStateChangingFunctions'

        # We use positional parameters in well-known commands (Join-Path, etc.)
        'PSAvoidUsingPositionalParameters'

        # The -Work switch is used implicitly via ParameterSetName; the script
        # branches on $Personal while -Work is the "default" core path.
        'PSReviewUnusedParameter'
    )

    Rules = @{
        # Enforce compatible syntax for Windows PowerShell 5.1 (fresh install target).
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
