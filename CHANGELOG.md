# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Work-only 1ES npm feed registry configuration at user scope and Agency installation through the documented Microsoft InstallTool. Existing Agency installations are skipped; authentication and HTTP proxy settings are left untouched.

### Changed
- Windows and macOS now rely on Copilot CLI being included with GitHub CLI instead of separately installing or upgrading the legacy `github/gh-copilot` extension.
- Removed standalone Copilot CLI presence/version checks and post-install verification; GitHub CLI installation and verification and editor Copilot configuration are unchanged.

### Fixed
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
