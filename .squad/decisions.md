# Squad Decisions

## Active Decisions

### 1. Define `$WINGET_APP_IN_USE` constant
**Date:** 2026-04-28 | **Author:** Falconer (Tester) | **Severity:** Critical

`$WINGET_APP_IN_USE` is referenced but never defined, causing "app in use" exit codes to be missed. Must add constant:
```powershell
$WINGET_APP_IN_USE = -1978335189   # 0x8A150077
```
**Impact:** Users get confusing generic errors instead of actionable guidance when apps are locked during install.

### 2. Fix PS7 profile migration duplicate-content guard
**Date:** 2026-04-28 | **Author:** Falconer (Tester) | **Severity:** High

PS7 profile migration (lines 826-840) lacks the duplicate-check guard that PS5.1 uses. On re-runs with recreated custom profiles, content duplicates. **Recommendation:** Add `$currentContent -notmatch` guard from PS5.1 path (line 868) to PS7 block.

### 3. Two-Phase Execution Strategy with Scheduled Task Resume
**Date:** 2026-04-28 | **Author:** Kovacs (Lead) | **Severity:** High

Current script is single-phase with reboot/resume issues. Recommended architecture:
- **Phase 1 (Admin):** Chocolatey, git, Node.js, all winget packages (except Spotify), Windows Features, register Phase 2 scheduled task, reboot
- **Phase 2 (Current User, non-admin):** Spotify, configuration, VS Code extensions, modules, verification, self-delete task

Use `Register-ScheduledTask` with `AtLogon` trigger to eliminate "run twice" problem.

### 4. Add Transcript Logging
**Date:** 2026-04-28 | **Author:** Kovacs (Lead) | **Severity:** Medium

Wrap entire script in `Start-Transcript` / `Stop-Transcript` for zero-effort debugging:
```powershell
$logFile = Join-Path $env:USERPROFILE ".altered-carbon-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logFile -Append
```

### 5. CI/CD Pipeline Implementation (IMPLEMENTED)
**Date:** 2026-04-28 | **Author:** Ortega (DevOps) | **Status:** Done

Three-workflow CI/CD pipeline created:
- `ci-lint.yml` — PSScriptAnalyzer + syntax validation + package format checks
- `ci-test.yml` — Pester 5 test suite (23 tests, all passing)
- `release.yml` — Tag-triggered release workflow with CHANGELOG validation

**Files:** `.github/workflows/{ci-lint,ci-test,release}.yml`, `PSScriptAnalyzerSettings.psd1`, `tests/altered-carbon.Tests.ps1`

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
