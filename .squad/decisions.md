# Squad Decisions

## Active Decisions

### macOS app bundle detection for casks (Tank, 2026-05-02)

- Add an `app_exists` helper near the other shell helpers.
- Let `ensure_cask` accept an optional third `app_name` argument and check `/Applications/{name}.app` plus `$HOME/Applications/{name}.app` before the existing Homebrew check.
- Pass explicit bundle names for known first-party casks, while leaving `--extra` packages on the existing brew-only path when no bundle name is known.
- **Impact:** The macOS bootstrap remains fast and idempotent, and respects apps already installed outside Homebrew.

### macOS single-prompt elevation (Niobe, 2026-05-02)

- Keep the current sudo keepalive pattern.
- Install Nerd Fonts with `oh-my-posh font install --user` so fonts land in `~/Library/Fonts` without a new sudo prompt.
- Export `HOMEBREW_CASK_OPTS="--no-quarantine"` and `HOMEBREW_NO_AUTO_UPDATE=1` before brew installs.
- Run the Xcode Command Line Tools check before Homebrew package work so any system dialog appears early.
- **Impact:** The macOS bootstrap stays aligned with the project goal of a single elevation prompt per run.

### Bash test infrastructure for macOS (Mouse, 2026-05-02)

- Add plain bash test script in `tests/altered-carbon-mac.tests.sh` instead of introducing `bats-core` as a new dependency.
- Extract helper functions (`app_exists`, `ensure_cask`) under test while mocking `brew` and isolating fake app bundles inside repo-local `tests/.sandbox/` paths.
- **Rationale:** No existing bash testing toolchain in repo; `bats` not required; lightweight harness keeps dependencies minimal and tests remain fast/side-effect-free.
- **Status:** Tests created and passing. Contributors can run `bash tests/altered-carbon-mac.tests.sh`.
- **Consequence:** Future macOS shell tests should prefer this lightweight harness unless team later adopts a shared bash test framework.

### Terminal.app Nerd Font configuration (Tank, 2026-05-02)

- Configure Terminal.app by exporting `com.apple.Terminal`, updating the default profile's `Font` archive to `${NERD_FONT}NerdFontMono-Regular` at 14pt with Python `plistlib`, and importing the plist back.
- **Rationale:** The macOS bootstrap installs Nerd Fonts and configures VS Code, but Terminal.app kept its existing font. This keeps the bootstrap idempotent, uses the existing `--nerd-font` option, and avoids relying on AppleScript automation permissions.
- **Status:** Implementation complete and tested (8 passing tests).

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
