# Squad Team

> altered-carbon

## Coordinator

| Name | Role | Notes |
|------|------|-------|
| Squad | Coordinator | Routes work, enforces handoffs and reviewer gates. |

## Members

| Name | Role | Charter | Status |
|------|------|---------|--------|
| Morpheus | Lead | .squad/agents/morpheus/charter.md | 🏗️ Active |
| Tank | Shell Dev | .squad/agents/tank/charter.md | 🔧 Active |
| Mouse | Tester | .squad/agents/mouse/charter.md | 🧪 Active |
| Niobe | DevOps/Config | .squad/agents/niobe/charter.md | ⚙️ Active |
| Scribe | Session Logger | .squad/agents/scribe/charter.md | 📋 Active |
| Ralph | Work Monitor | — | 🔄 Monitor |

## Project Context

- **Project:** altered-carbon
- **User:** John Spaid
- **Created:** 2026-05-02
- **Stack:** PowerShell 7+ (Windows), bash (macOS), Homebrew, winget, Chocolatey
- **Description:** Bootstrap automation that reinstalls and configures developer environments from scratch on Windows and macOS. Scripts must be idempotent, one-shot (minimal user interaction), and able to resume after reboot. Elevation/sudo should prompt at most once per session.
