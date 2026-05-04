# Project Context

- **Owner:** John Spaid
- **Project:** PowerShell automation for Windows dev environment setup — installs VS Code, Windows Terminal, PowerShell 7, git, GitHub Desktop/CLI, oh-my-posh, PowerToys, and more via winget. Goal is seamless "run once" experience with GitHub Actions for testing/validation.
- **Stack:** PowerShell 7+, winget, GitHub Actions, Windows features (Hyper-V, WSL)
- **Created:** 2026-04-28

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-04-28 — Full Script Audit (altered-carbon.ps1)
- **Script length:** ~1178 lines, single monolithic file.
- **Key architecture:** Chocolatey for git/node (PATH reliability), winget for everything else, custom PSModulePath in `~/.psmodule`, profile redirection to `~/.psprofile/profile.ps1` with stubs at default `$PROFILE` locations.
- **Critical bug found:** `$WINGET_APP_IN_USE` variable referenced at lines 373, 385, 448 but never defined — comparisons silently evaluate as `$LASTEXITCODE -eq $null` (always false). This means "app in use" exit codes from winget are misreported as generic failures.
- **Idempotency pattern:** Profile migration (lines 822-876) checks for `'managed by altered-carbon'` sentinel in existing profiles. PS7 migration lacks duplicate-content guard (line 838), PS5.1 migration has one (line 868). Running twice can duplicate migrated content in the PS7 path.
- **PSModulePath:** Line 146 unconditionally calls `SetEnvironmentVariable('PSModulePath', $psModuleDir, 'User')` — safe because it always writes the same single value. No accumulation risk.
- **Windows Terminal config:** Read-modify-write pattern (lines 927-984) preserves existing settings.json keys not touched by the script. Font and defaultProfile are overwritten each run but this is intentional.
- **VS Code settings.json:** Overwrites `editor.fontFamily` but preserves all other keys. ConvertTo-Json round-trips may reformat the file (cosmetic, not data-losing).
- **Test strategy:** Script is not currently testable with Pester. Needs function extraction and a dry-run mode. Recommend Pester for unit tests on helper functions, manual/VM integration tests for install flows.
