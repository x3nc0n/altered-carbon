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
