# Skill: PowerShell CI with PSScriptAnalyzer + Pester

## When to Use

When setting up CI/CD for PowerShell scripts that perform system operations (installs, config changes) that can't be executed in CI.

## Pattern: AST-Based Function Extraction for Pester

When a script has side effects at the top level but contains testable helper functions, extract them via PowerShell AST without executing the script:

```powershell
BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'script.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
    $functionDefs = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($fn in $functionDefs) {
        Invoke-Expression $fn.Extent.Text
    }
}
```

## Pattern: PSScriptAnalyzer Settings for Bootstrap Scripts

Bootstrap/installer scripts commonly need these exclusions:
- `PSAvoidUsingWriteHost` — intentional colored output
- `PSAvoidUsingInvokeExpression` — piped init patterns (oh-my-posh, etc.)
- `PSReviewUnusedParameter` — switch params used implicitly via ParameterSetName
- `PSUseShouldProcessForStateChangingFunctions` — not a module

Always use a checked-in `PSScriptAnalyzerSettings.psd1` rather than inline exclusions.

## Pattern: Syntax Validation Without Execution

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) { exit 1 }
```

## Constraints: winget on GitHub Actions

- `windows-latest` runners have winget available but package installs are unreliable
- Never attempt real `winget install` in CI — use static analysis only
- Package ID format validation (regex) is a good substitute for live validation
