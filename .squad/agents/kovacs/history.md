# Project Context

- **Owner:** John Spaid
- **Project:** PowerShell automation for Windows dev environment setup — installs VS Code, Windows Terminal, PowerShell 7, git, GitHub Desktop/CLI, oh-my-posh, PowerToys, and more via winget. Goal is seamless "run once" experience with GitHub Actions for testing/validation.
- **Stack:** PowerShell 7+, winget, GitHub Actions, Windows features (Hyper-V, WSL)
- **Created:** 2026-04-28

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-04-28 — Architecture Review of altered-carbon.ps1

- **Script size**: 1178 lines, monolithic. Well-commented section headers but no modular decomposition.
- **Key files**: `altered-carbon.ps1` (main script), `night-owl.omp.json` (oh-my-posh theme), `README.md` (comprehensive).
- **Package managers**: Dual strategy — Chocolatey for git/Node.js (reliable PATH), winget for everything else.
- **OneDrive avoidance**: Custom `~\.psmodule` and `~\.psprofile` directories keep PS config out of OneDrive sync. Profile stub at `$PROFILE` dot-sources real profile.
- **$WINGET_APP_IN_USE bug**: Variable referenced at lines 373, 385, 448 but never defined. Compares `$LASTEXITCODE` against `$null`, so the "app in use" detection branch never fires. Needs `$WINGET_APP_IN_USE = -1978335189` (0x8A150019).
- **GitHub CLI auth bug (reported fixed)**: Confirmed fixed — `gh extension list` is called with `2>$null` and result checked before proceeding. No auth check blocks Copilot CLI install.
- **ErrorActionPreference = 'Stop'** is set globally (line 35). External commands (winget, choco, gh) use `Write-Warning` on failure so they don't terminate, but any unexpected cmdlet error will abort the entire script with no recovery.
- **No reboot/resume strategy**: Hyper-V and WSL require reboot, but script has no mechanism to resume after reboot.
- **No transcript/logging**: Debugging failed runs requires re-running.
- **Spotify in core packages**: Installed for both Work and Personal modes — possibly intentional but worth confirming.
- **John prefers**: `winget` over manual downloads, idempotent scripts, `-Work` / `-Personal` mode split.
