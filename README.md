
# altered-carbon

Scripts that (re)install and configure developer tools on a fresh machine. Supports both **Windows** and **macOS**.

## Quick Start

### Windows (PowerShell)

```powershell
# Work mode — core apps only
.\altered-carbon.ps1 -Work

# Personal mode — core + personal apps
.\altered-carbon.ps1 -Personal
```

> **Tip:** Run as Administrator for full functionality (Chocolatey installs, Hyper-V, WSL 2).

### macOS (Shell)

```bash
# Personal mode — core + personal apps
./altered-carbon-mac.sh --personal

# Work mode — everything from personal + work-only apps
./altered-carbon-mac.sh --work
```

> **Note:** On macOS, Work mode includes all Personal packages plus work-specific additions (e.g., Intune Company Portal).

## Release Notes

- Current release notes draft: `releases/v1.0.0.md`
- Changelog: `CHANGELOG.md`

## Examples

### Windows

```powershell
# Use a different oh-my-posh theme
.\altered-carbon.ps1 -Work -OmpTheme 'jandedobbeleer'

# Use a different Nerd Font
.\altered-carbon.ps1 -Personal -NerdFont 'FiraCode'

# Skip specific packages
.\altered-carbon.ps1 -Work -SkipPackages 'Spotify.Spotify'

# Add extra packages
.\altered-carbon.ps1 -Personal -ExtraPackages @(@{Id='Mozilla.Firefox'; Name='Firefox'})

# Combine options
.\altered-carbon.ps1 -Work -OmpTheme 'catppuccin' -NerdFont 'JetBrainsMono' -SkipPackages 'Spotify.Spotify'
```

### macOS

```bash
# Use a different oh-my-posh theme
./altered-carbon-mac.sh --personal --omp-theme catppuccin

# Use a different Nerd Font
./altered-carbon-mac.sh --personal --nerd-font FiraCode

# Skip specific packages
./altered-carbon-mac.sh --personal --skip spotify

# Add extra casks
./altered-carbon-mac.sh --work --extra firefox

# Combine options
./altered-carbon-mac.sh --personal --omp-theme catppuccin --nerd-font JetBrainsMono --skip spotify
```

## Parameters

### Windows (`altered-carbon.ps1`)

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Work` | Yes* | — | Install core apps for work environment |
| `-Personal` | Yes* | — | Install core + personal apps |
| `-OmpTheme` | No | `night-owl` | oh-my-posh theme name (without `.omp.json`) |
| `-NerdFont` | No | `CodeNewRoman` | Nerd Font installed via oh-my-posh and set in terminals/editors |
| `-SkipPackages` | No | _(none)_ | winget package IDs to exclude from the default list |
| `-ExtraPackages` | No | _(none)_ | Additional `@{Id='...'; Name='...'}` hashtables to install |

\* One of `-Work` or `-Personal` must be specified.

### macOS (`altered-carbon-mac.sh`)

| Parameter | Required | Default | Description |
|---|---|---|---|
| `--personal`, `-p` | Yes* | — | Install core + personal apps |
| `--work`, `-w` | Yes* | — | Everything from personal + work-only apps |
| `--omp-theme` | No | `night-owl` | oh-my-posh theme name (without `.omp.json`) |
| `--nerd-font` | No | `CodeNewRoman` | Nerd Font installed via oh-my-posh and set in editors |
| `--skip` | No | _(none)_ | Brew formula/cask name to skip (repeatable) |
| `--extra` | No | _(none)_ | Extra brew cask to install (repeatable) |

\* One of `--personal` or `--work` must be specified.

## What Gets Installed

### Windows (`altered-carbon.ps1`)

#### Core (Both Modes)

1. Visual Studio Code
1. Visual Studio Code Insiders
1. Windows Terminal Preview
1. PowerShell (7)
1. PowerShell Preview (7)
1. git *(via Chocolatey when admin, winget fallback)*
1. Node.js (LTS) *(via Chocolatey when admin, winget fallback)*
1. GitHub Desktop
1. GitHub CLI
1. GitHub Copilot CLI *(via GitHub CLI extension `github/gh-copilot`)*
1. Microsoft Work IQ CLI *(via npm package `@microsoft/workiq`)*
1. oh-my-posh
1. PowerToys
1. NerdFont (installed via oh-my-posh CLI, configurable with `-NerdFont` parameter)
1. Spotify
1. Azure CLI (Az CLI)
1. 7zip
1. WinSCP
1. Logitech G Hub
1. Logitech Options+
1. Yealink USB Connect
1. Elgato StreamDeck
1. Windows App
1. Hyper-V (Windows feature, requires admin)
1. WSL 2 (Windows feature, requires admin)
1. Nvidia App (auto-detected if Nvidia GPU present)
1. PowerShell modules:
    1. Microsoft.Graph
    1. Az
    1. ExchangeOnlineManagement
    1. MicrosoftTeams
    1. PnP.PowerShell
    1. MicrosoftPowerBIMgmt
    1. Microsoft365DSC
    1. ActiveDirectory
    1. Microsoft.Graph.Intune
    1. AzSentinel
    1. MSAL.PS
    1. PSKusto
1. VS Code / VS Code Insiders extensions:
    1. Azure Resources (ID: `ms-azuretools.vscode-azureresourcegroups`)
    1. Bicep (ID: `ms-azuretools.vscode-bicep`)
    1. GitHub Copilot (ID: `github.copilot`)
    1. GitHub Copilot Chat (ID: `github.copilot-chat`)
    1. GitHub Copilot for Azure (ID: `ms-azuretools.vscode-azure-github-copilot`)
    1. AI Toolkit for Visual Studio Code (ID: `ms-windows-ai-studio.windows-ai-studio`)
    1. Microsoft Sentinel (ID: `ms-security.ms-sentinel`)

#### Personal Mode Only (`-Personal`)

In addition to core apps:

1. Steam
1. Discord
1. Battle.net
1. Signal
1. Google Chrome
1. Brave Browser
1. PIA VPN Client
1. Cursor IDE
1. LM Studio
1. Adobe Creative Cloud
1. Adobe Lightroom
1. Xbox

#### Configuration Applied

1. Windows Terminal Preview as default terminal
1. PowerShell Preview as the default shell
1. oh-my-posh theme (default: `night-owl`, configurable via `-OmpTheme`)
1. Updates Windows Terminal Preview settings to use the selected Nerd Font (default: `CodeNewRoman`, configurable via `-NerdFont`)
1. Updates Visual Studio Code and Visual Studio Code Insiders to use the selected Nerd Font Mono variant
1. Enables the following System → Advanced → File Explorer options:
    1. Show file extensions
    1. Show hidden and system files
    1. Show full path in title bar
    1. Show option to run as different user in Start

### macOS (`altered-carbon-mac.sh`)

#### Core (Both Modes)

1. Visual Studio Code
1. Visual Studio Code Insiders
1. GitHub Desktop
1. Docker Desktop
1. PowerShell (7)
1. git
1. git LFS
1. Node.js
1. GitHub CLI
1. GitHub Copilot CLI *(via GitHub CLI extension `github/gh-copilot`)*
1. oh-my-posh
1. NerdFont (installed via oh-my-posh CLI, configurable with `--nerd-font`)
1. Spotify
1. Azure CLI
1. OpenJDK 17
1. dotnet SDK
1. Mac App Store CLI (`mas`)
1. Microsoft Edge
1. Microsoft Teams
1. Microsoft Outlook
1. Microsoft Excel
1. Microsoft Word
1. Microsoft PowerPoint
1. Microsoft OneNote
1. Windows App
1. Logi Tune
1. GitHub Copilot for Xcode
1. PowerShell modules (macOS-compatible subset):
    1. Microsoft.Graph
    1. Az
    1. ExchangeOnlineManagement
    1. MicrosoftTeams
    1. PnP.PowerShell
    1. MicrosoftPowerBIMgmt
    1. Microsoft365DSC
    1. Microsoft.Graph.Intune
    1. MSAL.PS
1. VS Code / VS Code Insiders extensions: *(same as Windows)*

#### Personal Apps (included in both modes)

1. Steam
1. Discord
1. Signal
1. Brave Browser
1. LM Studio
1. Moonlight
1. ComfyUI
1. Bitwarden
1. Canva
1. Parallels Desktop
1. Android Studio
1. WiFiman Desktop
1. chruby + ruby-install (Ruby toolchain)

#### Work Mode Only (`--work`)

Work mode includes all personal apps plus work-specific additions. Currently a placeholder for apps like Intune Company Portal.

#### Configuration Applied

1. oh-my-posh theme in zsh (`~/.zshrc`) and PowerShell (`$PROFILE`), default: `night-owl`
1. Managed oh-my-posh config stored in `~/.config/altered-carbon/`
1. Custom theme stored in `~/.config/oh-my-posh/themes/`
1. VS Code and VS Code Insiders editor font set to selected Nerd Font Mono variant
1. Finder: show all file extensions, show hidden files, show path bar, show status bar, list view, folders on top

## OneDrive-Safe PowerShell Layout (Windows)

By default, PowerShell stores user modules and the `$PROFILE` script inside the Documents folder, which OneDrive often syncs. This can cause:

- Unwanted space usage in OneDrive
- Sync conflicts across machines
- Security alerts (e.g., Purview) due to example secrets in default modules

**This script creates two hidden folders under your user profile directory to keep PowerShell data out of OneDrive:**

| Folder | Purpose |
|---|---|
| `~\.psmodule` | Module storage — `PSModulePath` is set to this location |
| `~\.psprofile` | Profile config — oh-my-posh init and any other profile customizations live here |

A tiny stub is placed at the default `$PROFILE` path (inside Documents) that dot-sources the real profile from `~\.psprofile\profile.ps1`. This way only a harmless one-liner syncs via OneDrive, while the actual config stays local.

If you already have content in your existing `$PROFILE`, the script will migrate it into `~\.psprofile\profile.ps1` automatically before writing the stub.

> **Note:** You may need to restart your PowerShell session for the new `PSModulePath` to take effect everywhere.

## Package Managers

The script uses **two** package managers, each for what it does best:

| Manager | Used For | Why |
|---|---|---|
| **Chocolatey** | `git`, `Node.js` (+ Git Credential Manager) | Reliable PATH integration — VS Code, GitHub Desktop, and other tools find `git.exe` and `node.exe` immediately without a session restart |
| **winget** | Everything else | Built-in on Windows 11, handles Microsoft Store apps, broad catalogue |

Chocolatey is bootstrapped automatically when running as Administrator. On non-admin runs the script falls back to winget for git and Node.js.

The script installs tools from the following sources, in order of priority:
1. Chocolatey (for git and developer tools that need reliable PATH handling)
1. winget / Microsoft Store
1. Well-known Internet sources only — direct from publisher website, no third-party or download aggregation sites