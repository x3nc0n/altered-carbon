# Niobe — History

## Project Context
- **Project:** altered-carbon — developer environment bootstrap automation
- **User:** John Spaid
- **Stack:** PowerShell 7+ (Windows), bash (macOS), Homebrew, winget, Chocolatey
- **Key files:** altered-carbon-mac.sh (macOS config sections), altered-carbon.ps1 (Windows config sections)
- **Design goals:** Idempotent, one-shot, minimal interaction, single elevation prompt per session

## Learnings

- 2026-05-02T17:53:49-05:00 — macOS single-prompt elevation in `altered-carbon-mac.sh` depends on the existing sudo keepalive loop plus avoiding fresh privileged operations during installs. The current pattern is: install Nerd Fonts with `oh-my-posh font install --user`, export `HOMEBREW_CASK_OPTS="--no-quarantine"` and `HOMEBREW_NO_AUTO_UPDATE=1` before brew installs, and keep user-managed fonts under `~/Library/Fonts`.
- 2026-05-02T17:53:49-05:00 — The Xcode Command Line Tools check should run before Homebrew work in the macOS bootstrap so any system dialog appears up front instead of interrupting package installs later. Key file paths for this flow are `altered-carbon-mac.sh`, `~/Library/Fonts`, and `/Library/Fonts`.
