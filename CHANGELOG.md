# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
