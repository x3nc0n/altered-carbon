# Copilot Instructions — altered-carbon

## Project Overview

PowerShell automation that reinstalls and configures a Windows developer environment from scratch. Target apps: VS Code, VS Code Insiders, Windows Terminal Preview, PowerShell 7/Preview, git, GitHub Desktop, GitHub CLI, oh-my-posh, and PowerToys.

## Architecture

- **Installer scripts**: PowerShell (`.ps1`) scripts that install each application, likely via `winget` or direct download.
- **Configuration scripts**: Set defaults — Windows Terminal Preview as default terminal, PowerShell Preview as default shell, and oh-my-posh with the `night-owl` theme.
- Scripts should be idempotent — safe to re-run without side effects.

## Conventions

- **Language**: PowerShell 7+ (`pwsh`). Use modern cmdlets and syntax; avoid legacy Windows PowerShell (`powershell.exe`) patterns.
- **Package manager**: Prefer `winget` for installations when a package is available.
- **Script organization**: One script per logical concern (e.g., one for installs, one for config, or one per application).
- **Error handling**: Use `$ErrorActionPreference = 'Stop'` and try/catch blocks. Scripts run unattended, so failures must be loud.
- **No hardcoded paths**: Use environment variables (`$env:USERPROFILE`, `$env:LOCALAPPDATA`, `$env:POSH_THEMES_PATH`) instead of absolute paths.

## Key Patterns

- oh-my-posh is configured via the PowerShell profile at `$PROFILE` with:
  ```powershell
  oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\night-owl.omp.json" | Invoke-Expression
  ```
- Default terminal/shell settings are stored in Windows Terminal's `settings.json` (typically at `$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_*\LocalState\settings.json`).

## When Adding New Tools

1. Add a `winget install` invocation (or equivalent) to the install script.
2. Add any post-install configuration (e.g., config file writes, PATH updates).
3. Update `README.md` to list the new tool.
4. Keep scripts idempotent — check if already installed/configured before acting.
