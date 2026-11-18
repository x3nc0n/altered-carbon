# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [1.3.0] - 2026-11-18

### Changed
- Windows uses winget for git and Node.js LTS instead of bootstrapping Chocolatey for two packages. Existing Chocolatey installations are not removed.
- Windows installs and verifies the standalone `GitHub.Copilot` package: GitHub CLI's `gh copilot` downloads it on demand, rather than bundling the executable.
- Windows installs the free `WinSCP.WinSCP` package instead of the paid Microsoft Store edition.
- Work IQ installation/update now runs in non-elevated Phase 2, after Work-mode npm registry configuration.
- Font setup accepts current-user Nerd Fonts directly, removing unnecessary system-wide promotion and extra elevation prompts.
- Bootstrap CI/release jobs use current checkout/artifact action majors. Tests remain on Pester 5, and failed tests now fail the CI job.

### Fixed
- Scheduled Phase 2 preserves custom theme, font, and skip options across reboot, including quoted paths and argument values.
- `-SkipPackages` is honored for git, Node.js, and Phase 2 Spotify installation.
- Auto starts installation instead of silently running configuration only from a non-admin shell. Explicit phases validate elevation; Phase 2 requires PowerShell 7.6+ for current module prerequisites.
- Terminal configuration creates an explicit PowerShell Preview default on first run before dynamic profiles exist, preserves font size/weight, and uses the publisher's correct Preview delegation identities.
- Windows Home's unavailable Hyper-V feature no longer prevents enabling WSL prerequisite features; already enabled/pending features are left alone.
- Battle.net's install path uses the Windows environment rather than assuming a `C:` system drive.

## [1.2.0] - 2026-10-20

### Added
- Windows saves and opens a local Phase 2 HTML completion report with verification results and transcript location; handled orchestration failures in either phase save an incomplete report. Browser launch failures print a manual-open path.
- Work-only 1ES npm feed registry configuration at user scope and Agency installation through the documented Microsoft InstallTool. Existing Agency installations are skipped; authentication and HTTP proxy settings are left untouched.

### Changed
- Removed the unreliable "Run as different user" Start-menu policy write and misleading Settings shortcut; existing policy values are left untouched, with supported manual alternatives documented.
- Windows and macOS now rely on Copilot CLI being included with GitHub CLI instead of separately installing or upgrading the legacy `github/gh-copilot` extension.
- Removed standalone Copilot CLI presence/version checks and post-install verification; GitHub CLI installation and verification and editor Copilot configuration are unchanged.

### Fixed
- Windows closes transcripts on handled orchestration failures, preserves failure exit behavior, and no longer labels a successful Phase 1 handoff as full setup completion. Report saving failures are surfaced as errors rather than claiming completion.
- Windows recognizes editor-included GitHub Copilot Chat packages in VS Code and VS Code Insiders instead of reporting them missing or reinstalling them. Extension messages identify the editor channel and extension ID, distinguish missing editor Copilot from Copilot CLI, and surface extension command failures instead of claiming success.
- Windows Phase 2 treats Spotify's winget "no applicable upgrade" result as already up to date rather than an install warning.
- Windows Phase 2 retires its scheduled task before initialization/configuration and uses a durable one-shot attempt marker to prevent repeated configuration after failures. Cleanup failures stop the run with manual recovery guidance; new tasks grant their user permission to remove them.
- Legacy oh-my-posh cache deletion now accepts only discovered module directories, rejecting filesystem roots, user-profile ancestors, and reparse points instead of recursively deleting an unchecked `POSH_PATH`.

## [1.1.0] - 2026-10-02

### Changed
- Homebrew-managed formulae and casks are now upgraded when outdated instead of being skipped whenever already installed.
- PowerShell Gallery modules are now version-checked and updated on both Windows and macOS.
- Updated Homebrew cask names to the current canonical tokens for Docker Desktop (`docker-desktop`) and ComfyUI (`comfy`).
- Consolidated VS Code Copilot setup on the current `github.copilot-chat` extension.
- Ensured macOS uses the same customized `night-owl` theme as Windows, including the battery-status segment and current battery option names.

### Fixed
- Updated Nerd Font installation for current Oh My Posh releases, which infer user/system scope and no longer accept `--user`.

### Removed
- Removed management of the retired `github/gh-copilot` GitHub CLI extension.
- Removed stale PowerShell modules `Microsoft.Graph.Intune`, `AzSentinel`, `MSAL.PS`, and unavailable `PSKusto`; their supported functionality is covered by the maintained Microsoft Graph and Az modules already installed.
- Removed Microsoft365DSC from the macOS module list because its full configuration workflow remains Windows-focused.

## [1.0.0] - 2026-04-15

### Added
- GitHub Copilot CLI support via the `github/gh-copilot` GitHub CLI extension.
- Microsoft Work IQ CLI support via the global npm package `@microsoft/workiq`.
- Non-admin Node.js LTS fallback via winget package `OpenJS.NodeJS.LTS`.
- Additional managed VS Code extensions for `github.copilot-chat`, `ms-azuretools.vscode-azure-github-copilot`, and `ms-windows-ai-studio.windows-ai-studio`.
- A post-install verification summary that reports the status of key CLIs and VS Code extensions.

### Changed
- Updated the installer to treat Node.js like git: prefer Chocolatey when available, then fall back to winget.
- Expanded README coverage for Copilot CLI, Work IQ, Node.js fallback behavior, and the broader AI-related extension set.
