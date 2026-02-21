# altered-carbon

This repo is PowerShell that (re)installs and/or updates the following:
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
1. Azure CLI (Az CLI)
1. 7zip
1. WinSCP

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

The script accepts parameters so each person can tailor it to their preferences:

```powershell
# Run with all defaults
.\altered-carbon.ps1

# Use a different oh-my-posh theme
.\altered-carbon.ps1 -OmpTheme 'jandedobbeleer'

# Use a different Nerd Font
.\altered-carbon.ps1 -NerdFont 'FiraCode'

# Skip specific packages
.\altered-carbon.ps1 -SkipPackages 'Spotify.Spotify'

# Add extra packages
.\altered-carbon.ps1 -ExtraPackages @(@{Id='Mozilla.Firefox'; Name='Firefox'})

# Combine options
.\altered-carbon.ps1 -OmpTheme 'catppuccin' -NerdFont 'JetBrainsMono' -SkipPackages 'Spotify.Spotify'
```

| Parameter | Default | Description |
|---|---|---|
| `-OmpTheme` | `night-owl` | oh-my-posh theme name (without `.omp.json`) |
| `-NerdFont` | `CodeNewRoman` | Nerd Font installed via oh-my-posh and set in terminals/editors |
| `-SkipPackages` | _(none)_ | winget package IDs to exclude from the default list |
| `-ExtraPackages` | _(none)_ | Additional `@{Id='...'; Name='...'}` hashtables to install |

If possible, it installs these tools from the following sources, in order of priority:
1. Microsoft Store
1. Well-known Internet sources only - direct from publisher website, no third-party or download aggregation sites