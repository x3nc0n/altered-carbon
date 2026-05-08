# Mouse — History

## Project Context
- **Project:** altered-carbon — developer environment bootstrap automation
- **User:** John Spaid
- **Stack:** PowerShell 7+ (Windows), bash (macOS), Homebrew, winget, Chocolatey
- **Key files:** tests/altered-carbon.Tests.ps1, .github/workflows/ci-*.yml
- **Design goals:** Idempotent, one-shot, minimal interaction, resume after reboot

## Learnings

- 2026-05-02T18:16:07-05:00 — Tank added `app_exists()` helper and updated `ensure_cask()` in `altered-carbon-mac.sh` to accept optional 3rd parameter for app bundle name. All 27 cask calls now pass correct `.app` bundle names. Script passes `bash -n` syntax check. This keeps the bootstrap idempotent for App Store / direct-download installs.
- macOS shell coverage now lives in `tests/altered-carbon-mac.tests.sh` as a plain bash harness, so contributors can run `bash tests/altered-carbon-mac.tests.sh` without introducing `bats-core`.
- The macOS tests load only helper functions from `altered-carbon-mac.sh`, mock `brew`, and redirect app bundle lookups into repo-local `tests/.sandbox/` paths to stay fast and side-effect-free.
- Key test targets for the macOS bootstrap are `app_exists()` and `ensure_cask()` in `altered-carbon-mac.sh`, especially skip handling and app-bundle idempotency behavior.
- 2026-05-07T16:54:11.295-05:00 — `tests/altered-carbon.Tests.ps1` now covers winget exit-code constants, `Test-WingetKnownVersion`, `Install-WingetPackages` fallback/success/location handling, and `Enable-WindowsFeatures` graceful skip behavior by AST-loading functions and mocking `winget` / Windows feature cmdlets so `altered-carbon.ps1` is never executed for side effects.
- 2026-05-07T16:54:11.295-05:00 — Spawned to add Pester tests for new exit code constants (`Test-WingetExitCode`) and helper function `Test-WingetKnownVersion` in `tests/altered-carbon.Tests.ps1`. Tank's 23/23 tests provide baseline; Mouse extends coverage for tank-verified bugs.
- 2026-05-07T19:13:12.675-05:00 — `tests/altered-carbon.Tests.ps1` now covers `Compare-WingetVersions`, the newer-than-catalog skip path in `Install-WingetPackages`, built-in `gh copilot` detection in `Install-GitHubCopilotCli`, guarded `oh-my-posh` module removal in `Set-OhMyPoshProfile`, and registry-path creation in `Set-FileExplorerOptions` for `HKCU:\Software\Policies\Microsoft\Windows\Explorer`.
- 2026-05-07T19:13:12.675-05:00 — Windows test coverage in this repo mixes AST-executed helper-function tests with static assertions against `altered-carbon.ps1` for top-level flows such as Spotify ShellExecute exit-code handling, updated winget package IDs (`PrivateInternetAccess.PrivateInternetAccess`, `ElementLabs.LMStudio`), Lightroom/Xbox delist notes, and RSAT/unavailable module metadata.
- 2026-05-08T00:13:00Z — Tank fixed 10 issues from Phase 1 & Phase 2 runs: winget version comparison, package ID corrections (PIA, LM Studio), Spotify exit code handling, ActiveDirectory RSAT treatment, PSKusto removal, oh-my-posh quiet uninstall, Explorer registry path creation, unavailable package skipping, and version display format. All 39/39 Pester tests passing. Decision recorded in decisions.md (winget source reconciliation). Mouse now extends coverage for Tank's fixes.
