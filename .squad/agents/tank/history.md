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
