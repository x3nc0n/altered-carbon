# Decisions Archive

## 2026-05-07: winget exit-code regression coverage in Pester tests

**Date:** 2026-05-07T16:54:11.295-05:00  
**Author:** Mouse (Tester)  
**Scope:** `tests/altered-carbon.Tests.ps1`

### Decision

Keep regression coverage for `altered-carbon.ps1` side-effect free by AST-loading function definitions, then inject package lists and mock `winget`, `Get-WindowsOptionalFeature`, and `Enable-WindowsOptionalFeature` for exit-code and feature-management scenarios.

### Why

The new winget handling depends on `$LASTEXITCODE`, optional `--location` arguments, and upgrade-to-install fallback behavior that should be tested without performing real installs. Mocked command-level tests give us deterministic coverage for idempotency paths and "Class not registered" skips while staying aligned with the existing test architecture.

---

## 2026-05-07: winget exit-code handling for idempotent Windows installs

**Date:** 2026-05-07T16:54:11.295-05:00  
**Author:** Tank (Shell Dev)  
**Severity:** High

### Context

`altered-carbon.ps1` was treating winget `0x8A15002B` as "app in use," which produced false lock warnings whenever a package was already current. The same script also surfaced raw package-not-found errors for IDs that `winget list` could detect but `winget upgrade` could not reconcile.

### Decision

1. Treat `0x8A15002B` (`-1978335189`) as "no applicable upgrade" and therefore a success path for upgrade checks.
2. Reserve `0x8A150077` (`-1978335113`) for the real "app in use" warning path.
3. Treat `0x8A150014` (`-1978335212`) as a package/source mismatch: after an upgrade attempt fails with that code, try `winget install`; if install returns the same code, warn that the package is unavailable from configured sources and the package ID should be verified.
4. Allow package entries to provide a `Location` value so winget can run unattended for installers like Battle.net that require an explicit install root.

### Consequence

Repeated runs now stay idempotent and quieter on already-current systems, while genuinely blocked or misconfigured packages produce actionable messages. This also gives the package list a clear extension point for installer-specific arguments without hardcoding one-off command branches.

---

## 2026-05-05: Post-install verification logic fixes

**Date:** 2026-05-05T17:39:12.405-05:00  
**Author:** Tank (Shell Dev)  
**Severity:** Medium

### Context

`Show-VerificationSummary` in `altered-carbon.ps1` had two detection bugs that caused false MISSING results on an otherwise correctly-configured machine.

### Decision 1: GitHub Copilot CLI — prefer built-in subcommand over extension

GitHub has rolled Copilot CLI functionality directly into the `gh` binary as a built-in subcommand. Running `gh extension list` returns "no installed extensions found" even when `gh copilot --help` works perfectly, so the old extension-only check produced a false negative.

**New logic:**
1. Run `gh copilot --help`; if exit code is 0, mark installed with `'built-in subcommand'`.
2. Only if the built-in check fails, fall back to scanning `gh extension list` for `gh-copilot`; if found, mark installed with `'gh extension installed'`.
3. If neither passes, report MISSING.

**Consequence:** Verification correctly reflects reality on systems where `gh` ships the built-in (current state) as well as hypothetical systems where only the extension is present.

### Decision 2: VS Code Copilot extensions — treat github.copilot + github.copilot-chat as a consolidated pair

GitHub consolidated `github.copilot` and `github.copilot-chat` into a single distributed extension. VS Code stable lists only `github.copilot-chat`; VS Code Insiders lists only `github.copilot`. Both represent full Copilot functionality.

**New logic:**
- Before iterating extensions, compute whether either ID in the pair is present in the installed list.
- For each member of the pair: if it is not directly installed but its partner is, mark it installed with `(consolidated)` appended to the details string.
- Extensions outside the pair are unaffected.

**Consequence:** Neither VS Code variant reports false MISSING for Copilot. The `(consolidated)` tag distinguishes detection-via-partner from direct listing, preserving observability.

---

## 2026-04-28: User directive — Spotify in core packages

**Date:** 2026-04-28T07:38:52Z  
**By:** John Spaid (via Copilot)  
**Severity:** Operational

Spotify in core packages (Work mode) is intentional — do not move it to personal-only. User request — captured for team memory.
