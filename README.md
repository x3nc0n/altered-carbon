# altered-carbon

This repo is PowerShell that (re)installs and/or updates developer tools on a fresh Windows installation. It requires either `-Work` or `-Personal` mode to be specified.

## Modes

### Core (Both Modes)
The following are installed in both `-Work` and `-Personal` modes:

1. Visual Studio Code
1. Visual Studio Code Insiders
1. Windows Terminal Preview
1. PowerShell (7)
1. PowerShell Preview (7)
1. git
1. GitHub Desktop
1. GitHub CLI
1. oh-my-posh
1. PowerToys
1. NerdFont Code New Roman
1. Spotify (install only; Spotify manages its own updates)
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

### Personal Mode Only (`-Personal`)
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

It also sets the following defaults and settings:
1. Windows Terminal Preview as default terminal
1. PowerShell Preview as the default shell
1. oh-my-posh theme (default: `night-owl`, configurable via `-OmpTheme`)
1. Updates Windows Terminal Preview settings to use the selected Nerd Font (default: `CodeNewRoman`, configurable via `-NerdFont`)
1. Updates Visual Studio Code and Visual Studio Code Insiders to use the selected Nerd Font Mono variant
1. Enables the following System->Advanced->File Explorer options:
  1. Show file extensions
  1. Show hidden and system files
  1. Show full path in title bar
  1. Show option to run as different user in Start

## Customization

The script requires `-Work` or `-Personal` mode, plus accepts optional parameters:

```powershell
# Work mode (core apps only)
.\altered-carbon.ps1 -Work

# Personal mode (core + personal apps)
.\altered-carbon.ps1 -Personal

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

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Work` | Yes* | - | Install core apps for work environment |
| `-Personal` | Yes* | - | Install core + personal apps |
| `-OmpTheme` | No | `night-owl` | oh-my-posh theme name (without `.omp.json`) |
| `-NerdFont` | No | `CodeNewRoman` | Nerd Font installed via oh-my-posh and set in terminals/editors |
| `-SkipPackages` | No | _(none)_ | winget package IDs to exclude from the default list |
| `-ExtraPackages` | No | _(none)_ | Additional `@{Id='...'; Name='...'}` hashtables to install |

\* One of `-Work` or `-Personal` must be specified.

If possible, it installs these tools from the following sources, in order of priority:
1. Microsoft Store
1. Well-known Internet sources only - direct from publisher website, no third-party or download aggregation sites