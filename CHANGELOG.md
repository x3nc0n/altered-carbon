# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed
- GitHub Copilot CLI extension install/upgrade now checks `gh auth status` before attempting the operation and emits a clear warning when `gh` is not authenticated, instead of silently failing with a bare exit-code warning.
- `gh extension install` and `gh extension upgrade` output is no longer fully suppressed; if either command fails, `gh`'s own error text is surfaced so the cause is visible.
- Added the `gh auth login` tip to the `gh extension upgrade` failure path (it was previously only shown for `gh extension install` failures).

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
