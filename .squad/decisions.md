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
### macOS app bundle detection for casks (Tank, 2026-05-02)

- Add an `app_exists` helper near the other shell helpers.
- Let `ensure_cask` accept an optional third `app_name` argument and check `/Applications/{name}.app` plus `$HOME/Applications/{name}.app` before the existing Homebrew check.
- Pass explicit bundle names for known first-party casks, while leaving `--extra` packages on the existing brew-only path when no bundle name is known.
- **Impact:** The macOS bootstrap remains fast and idempotent, and respects apps already installed outside Homebrew.

### macOS single-prompt elevation (Niobe, 2026-05-02)

- Keep the current sudo keepalive pattern.
- Install Nerd Fonts with `oh-my-posh font install --user` so fonts land in `~/Library/Fonts` without a new sudo prompt.
- Export `HOMEBREW_CASK_OPTS="--no-quarantine"` and `HOMEBREW_NO_AUTO_UPDATE=1` before brew installs.
- Run the Xcode Command Line Tools check before Homebrew package work so any system dialog appears early.
- **Impact:** The macOS bootstrap stays aligned with the project goal of a single elevation prompt per run.

### Bash test infrastructure for macOS (Mouse, 2026-05-02)

- Add plain bash test script in `tests/altered-carbon-mac.tests.sh` instead of introducing `bats-core` as a new dependency.
- Extract helper functions (`app_exists`, `ensure_cask`) under test while mocking `brew` and isolating fake app bundles inside repo-local `tests/.sandbox/` paths.
- **Rationale:** No existing bash testing toolchain in repo; `bats` not required; lightweight harness keeps dependencies minimal and tests remain fast/side-effect-free.
- **Status:** Tests created and passing. Contributors can run `bash tests/altered-carbon-mac.tests.sh`.
- **Consequence:** Future macOS shell tests should prefer this lightweight harness unless team later adopts a shared bash test framework.

### Terminal.app Nerd Font configuration (Tank, 2026-05-02)

- Configure Terminal.app by exporting `com.apple.Terminal`, updating the default profile's `Font` archive to `${NERD_FONT}NerdFontMono-Regular` at 14pt with Python `plistlib`, and importing the plist back.
- **Rationale:** The macOS bootstrap installs Nerd Fonts and configures VS Code, but Terminal.app kept its existing font. This keeps the bootstrap idempotent, uses the existing `--nerd-font` option, and avoids relying on AppleScript automation permissions.
- **Status:** Implementation complete and tested (8 passing tests).

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
