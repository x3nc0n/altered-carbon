# Project Context

- **Owner:** John Spaid
- **Project:** PowerShell automation for Windows dev environment setup — installs VS Code, Windows Terminal, PowerShell 7, git, GitHub Desktop/CLI, oh-my-posh, PowerToys, and more via winget. Goal is seamless "run once" experience with GitHub Actions for testing/validation.
- **Stack:** PowerShell 7+, winget, GitHub Actions, Windows features (Hyper-V, WSL)
- **Created:** 2026-04-28

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-04-28 — CI/CD Pipeline Design
- **Script structure**: `altered-carbon.ps1` is ~1178 lines with 4 helper functions (`Get-WingetVersionInfo`, `Invoke-ElevatedFontPromotion`, `Get-CommandVersion`, `Write-VerificationLine`). Functions can be extracted via AST for isolated testing without executing side effects.
- **PSScriptAnalyzer**: Must exclude `PSAvoidUsingWriteHost` (intentional colored output), `PSAvoidUsingInvokeExpression` (oh-my-posh init pattern), `PSReviewUnusedParameter` (`-Work` switch used implicitly via ParameterSetName), and `PSUseShouldProcessForStateChangingFunctions` (bootstrap script, not a module).
- **Pester approach**: Since the script performs real installs, tests use AST parsing to extract function definitions and test them in isolation. Package list integrity and script structure are validated via regex/AST without executing any installs.
- **winget on CI runners**: `windows-latest` GitHub Actions runners have limited winget support — package installs may fail or require `--accept-source-agreements`. CI should NOT attempt real installs; stick to lint, parse, and unit tests.
- **Package ID diversity**: The script contains Chocolatey IDs (`git`, `nodejs-lts`), winget IDs (`Microsoft.PowerShell`), MS Store IDs (`9N1F85V9T8BN`), and VS Code extension IDs (`github.copilot`). Test regex patterns must account for all formats.
- **Key files**: `PSScriptAnalyzerSettings.psd1` (lint config), `tests/altered-carbon.Tests.ps1` (Pester tests), `.github/workflows/ci-lint.yml` (lint + syntax), `.github/workflows/ci-test.yml` (Pester), `.github/workflows/release.yml` (tag-based releases).
- **Trailing whitespace**: Lines 414 and 440 had trailing whitespace caught by PSScriptAnalyzer — fixed.
