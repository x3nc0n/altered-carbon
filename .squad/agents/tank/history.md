# Tank — History

## Project Context
- **Project:** altered-carbon — developer environment bootstrap automation
- **User:** John Spaid
- **Stack:** PowerShell 7+ (Windows), bash (macOS), Homebrew, winget, Chocolatey
- **Key files:** altered-carbon.ps1 (Windows), altered-carbon-mac.sh (macOS)
- **Design goals:** Idempotent, one-shot, minimal interaction, resume after reboot, single elevation prompt per session

## Learnings

- 2026-05-02T18:12:49-05:00 — `altered-carbon-mac.sh` now treats app bundles in `/Applications` and `~/Applications` as already installed before falling back to `brew list --cask`, keeping `ensure_cask` idempotent for App Store and direct-download installs.
- 2026-05-02T18:12:49-05:00 — For macOS casks with non-obvious bundle names, pass an explicit third `ensure_cask` argument for the `.app` bundle name; omit it for `--extra` casks so they stay brew-only.
- 2026-05-02T18:12:49-05:00 — Team-relevant macOS installer decisions belong in `.squad/decisions/inbox/`, and the primary shell implementation file is `altered-carbon-mac.sh`.
- 2026-05-02T23:56:29-05:00 — Mouse created `tests/altered-carbon-mac.tests.sh` with 8 passing tests covering `app_exists()` and `ensure_cask()` app-bundle detection. Tests use repo-local mocked `brew` and `tests/.sandbox/` for isolation, establishing lightweight bash testing foundation for future shell coverage.
- 2026-05-02T19:11:55-05:00 — Terminal.app font state lives in `com.apple.Terminal` under `Window Settings` → profile `Font` as NSKeyedArchiver `NSFont` data, so `altered-carbon-mac.sh` now updates the default profile via `defaults export/import` and Python `plistlib` instead of AppleScript prompts.
- 2026-05-03T02:08:48Z — Scribe orchestration: Terminal.app Nerd Font PostScript name bug identified—script constructs incorrect PS name causing broken glyphs. Tank spawned to fix. Orchestration logs created.
- 2026-05-07T16:54:11.295-05:00 — `altered-carbon.ps1` now treats winget exit code `0x8A15002B` as “already up to date,” keeps `0x8A150077` for “app in use,” and surfaces `0x8A150014` as a package/source mismatch instead of a misleading lock warning.
- 2026-05-07T16:54:11.295-05:00 — Personal package entries can include an optional `Location` field; `Install-WingetPackages` forwards it to both `winget upgrade` and `winget install`, with Battle.net using `C:\Program Files (x86)\Battle.net` for unattended installs.
- 2026-05-07T16:54:11.295-05:00 — `Enable-WindowsFeatures` in `altered-carbon.ps1` must wrap `Get-WindowsOptionalFeature` in `try/catch` because some Windows editions throw terminating COM errors like “Class not registered,” and the script should skip gracefully instead of aborting.
- 2026-05-07T16:54:11.295-05:00 — Five integration bugs fixed in `altered-carbon.ps1`: (1) exit code constant `0x8A15002B` → `-1978335189` as "no applicable upgrade" (success), (2) `0x8A150077` reserved for "app in use" warning, (3) `0x8A150014` as package/source mismatch with fallback to install, (4) Get-WindowsOptionalFeature COM error handling, (5) version display for unrecognized formats. All 23 Pester tests passing.
- 2026-05-07T16:54:11.295-05:00 — Scribe merged 3 decision inbox items (Spotify directive, verification fixes, winget exit codes) into decisions.md and staged `.squad/` artifacts for commit.
- 2026-05-07T19:14:46.168-05:00 — `altered-carbon.ps1` now compares numeric version segments before logging winget upgrades and skips with a clear message when the installed version is newer than the catalog version, preventing false “Updating X to older Y” output.
- 2026-05-07T19:14:46.168-05:00 — Current winget package IDs in `altered-carbon.ps1` are `PrivateInternetAccess.PrivateInternetAccess` for PIA VPN and `ElementLabs.LMStudio` for LM Studio; Adobe Lightroom, Xbox app, and NVIDIA App are not currently installable from the configured sources and should be skipped with manual guidance instead of retried blindly.
- 2026-05-07T19:14:46.168-05:00 — Phase 2 PowerShell module handling in `altered-carbon.ps1` must treat `ActiveDirectory` as an RSAT component and `PSKusto` as unavailable from PSGallery, while only uninstalling the deprecated `oh-my-posh` module when PowerShellGet reports it as actually installed.
