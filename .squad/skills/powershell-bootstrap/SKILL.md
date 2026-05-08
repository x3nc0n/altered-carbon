# Skill: Idempotent Script Audit

**When to use:** Auditing PowerShell bootstrap/setup scripts for safe re-run behavior.

## Checklist

1. **Undefined variables in conditionals** — PowerShell treats undefined vars as `$null`. Comparisons like `$x -eq $UNDEFINED` are always `$false`. Search for all variable references and verify definitions.
2. **SetEnvironmentVariable accumulation** — `[System.Environment]::SetEnvironmentVariable('X', $val, 'User')` overwrites, not appends. Safe for single values. Dangerous if building semicolon-delimited lists (e.g., PATH) without reading the existing value first.
3. **Profile/config migration guards** — When migrating content from one file to another, always check if the destination already contains the content before prepending/appending. Use `[regex]::Escape()` for safe matching.
4. **Read-modify-write config files** — JSON round-tripping via `ConvertFrom-Json | ... | ConvertTo-Json` preserves data but may reformat. Acceptable for settings files, but note it changes whitespace/ordering.
5. **Sentinel comments for managed blocks** — Use start/end comment markers (e.g., `# ── managed by X ──` / `# ── end X ──`) and strip-then-rewrite pattern for idempotent config injection.
6. **PATH refresh after installs** — Always refresh `$env:Path` from Machine+User registry values after installing tools that modify PATH. Check that downstream code doesn't run before the refresh.
7. **Exit code handling** — winget, choco, npm all use different exit code conventions. Define constants for known codes. Never assume `0 = success, anything else = failure` without checking docs.
8. **Catalog-vs-installed version drift** — Before logging `Updating X from A to B`, compare version segments numerically. If `A > B`, skip and log that the installed version is newer than the catalog version.
9. **Unavailable-source handling** — If `winget search` or `Find-Module` confirms an item is no longer published from the configured source, replace the stale ID or skip with manual guidance. Do not keep retrying a guaranteed package-not-found path.

## Anti-patterns

- Comparing `$LASTEXITCODE` against an undefined constant (silently always false)
- Appending to files without dedup check on re-run
- Assuming tools are on PATH immediately after `winget install` without explicit refresh
- Using `$ErrorActionPreference = 'Stop'` globally but wrapping external commands (winget/choco) that communicate via exit codes, not exceptions
- Logging an upgrade before verifying that the available version is actually newer
- Treating RSAT or delisted modules as if they were normal PSGallery installs
