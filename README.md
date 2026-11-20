
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

> **Before resetting:** Save this repository (including `night-owl.omp.json`) and your personal files, SSH/GPG keys, unsynced settings, and recovery information somewhere off this machine. This script reinstalls tools; it is not a data, credential, license, or sign-in backup.

Run the Windows commands above **as Administrator under your own Windows account**, not another administrator's account. A fresh Windows PowerShell 5.1 session can run Phase 1; App Installer (`winget`) and internet access must already be available. If Windows blocks the downloaded script, review it and use `Unblock-File .\altered-carbon.ps1` and a process-scoped execution policy as needed; do not change machine policy.

Windows uses two phases: elevated installation, then non-elevated configuration in the installed PowerShell 7 at the next logon after reboot. Phase 2 requires PowerShell **7.6+** for the [current Microsoft365DSC prerequisites](https://microsoft365dsc.com/user-guide/get-started/prerequisites/); Windows PowerShell 5.1 is only the initial bootstrap host, not a supported host for all installed modules. Microsoft365DSC's dependency initialization and any RSAT/LCM setup remain separate workload-specific steps.

`Auto` always starts Phase 1 rather than silently skipping installation from a non-admin shell. Explicit Phase 1 requires elevation; Phase 2 rejects it. The reboot still requires confirmation; `-SkipReboot` leaves it to you. Keep the script and theme at the same local path through reboot. The scheduled handoff retains your mode, theme, font, and skip list. A manual Phase 2 retry must supply those options again.

Phase 2 removes its logon task **before** initialization or configuration, so a configuration error does not retry at every login. New tasks grant the current user permission to remove that task.

Each scheduled attempt also records a durable one-shot marker in `%LOCALAPPDATA%\altered-carbon`. If task cleanup fails, the script stops with an error rather than claiming success or running configuration. Remove `altered-carbon-phase2` from Task Scheduler as administrator if directed, then retry from a non-elevated shell with `.\altered-carbon.ps1 -Work -Phase Phase2` (or `-Personal`). Do not supply the internal `-ResumeToken` on a manual retry.

Phase 2 saves a local HTML report under `%LOCALAPPDATA%\altered-carbon\reports` and requests that your default browser open it. The saved path is printed even if browser launch fails; a successful launch request does not guarantee a visible browser tab. Reports include verification results and the transcript location (`%USERPROFILE%\.altered-carbon-*.log`). Previously the summary existed only in the console, with no report page to open.

Handled orchestration failures in either phase also produce an **incomplete** report, close the transcript, and exit with an error. Phase 1 success means Phase 2 is still pending, not that all setup finished. A completed report means execution reached the end; optional operations may still have warnings, and verification checks presence only. Review the transcript as well. Forced termination, power loss, and failures before orchestration starts cannot guarantee a report. Reports/logs can contain personal paths or diagnostic details; review before sharing. Old logs, reports, and one-shot markers are retained, not automatically deleted.

### macOS (Shell)

```bash
# Personal mode — core + personal apps
./altered-carbon-mac.sh --personal

# Work mode — everything from personal + work-only apps
./altered-carbon-mac.sh --work
```

> **Note:** On macOS, Work mode includes all Personal packages plus work-specific additions (e.g., Intune Company Portal).

## Release Notes

- Current release: [v1.6.0](https://github.com/x3nc0n/altered-carbon/releases/tag/v1.6.0)
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
| `-Phase` | No | `Auto` | `Phase1` (also `Auto`) for elevated installation; `Phase2` for non-elevated manual configuration/retry |
| `-SkipReboot` | No | Off | Leave reboot to the user after Phase 1 |

\* One of `-Work` or `-Personal` must be specified.

### macOS (`altered-carbon-mac.sh`)

| Parameter | Required | Default | Description |
|---|---|---|---|
| `--personal`, `-p` | Yes* | — | Install core + personal apps |
| `--work`, `-w` | Yes* | — | Everything from personal + work-only apps |
| `--omp-theme` | No | `night-owl` | oh-my-posh theme name (without `.omp.json`) |
| `--nerd-font` | No | `CodeNewRoman` | Nerd Font installed via oh-my-posh and set in terminals/editors |
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
1. git *(via winget)*
1. Node.js (LTS) *(via winget)*
1. GitHub Desktop
1. GitHub CLI
1. GitHub Copilot CLI *(standalone `GitHub.Copilot` winget package)*
1. GitHub Copilot App *(desktop, Microsoft Store product `XPDCK2L0R6V76J`; separate from the CLI and editor extensions)*
1. Squad CLI *(`@bradygaster/squad-cli`, via official winget package `bradygaster.Squad`)*
1. Podman engine/CLI *(`RedHat.Podman`)* and Podman Desktop *(`RedHat.Podman-Desktop`)*
1. Microsoft Foundry Local *(per-user Phase 2 installation and login autostart on supported Windows 11)*
1. NVIDIA CUDA Toolkit *(Windows x64 only, gated by detected GPU capability, driver, and OS; see below)*
1. Microsoft Work IQ CLI *(via npm package `@microsoft/workiq`, installed/updated in non-elevated Phase 2)*
1. oh-my-posh
1. PowerToys
1. NerdFont (installed via oh-my-posh CLI, configurable with `-NerdFont` parameter)
1. Spotify
1. Azure CLI (Az CLI)
1. 7zip
1. WinSCP *(free publisher package `WinSCP.WinSCP`, not the paid Store edition)*
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
1. VS Code / VS Code Insiders extensions:
    1. Azure Resources (ID: `ms-azuretools.vscode-azureresourcegroups`)
    1. Bicep (ID: `ms-azuretools.vscode-bicep`)
    1. GitHub Copilot Chat (ID: `github.copilot-chat`)
    1. GitHub Copilot for Azure (ID: `ms-azuretools.vscode-azure-github-copilot`)
    1. AI Toolkit for Visual Studio Code (ID: `ms-windows-ai-studio.windows-ai-studio`)
    1. Microsoft Sentinel (ID: `ms-security.ms-sentinel`)

Windows checks GitHub Copilot Chat separately for VS Code and VS Code Insiders. Some releases include this extension with the editor, so it does not appear in `--list-extensions` (which lists user extensions). Setup also checks `--locate-extension github.copilot-chat` and its package identity before reporting it present or skipping installation. The summary names the editor channel and extension ID; it checks presence, not sign-in, enablement, or subscription status. A missing editor extension is unrelated to standalone Copilot CLI.

GitHub CLI's [`gh copilot`](https://github.com/cli/cli/blob/trunk/pkg/cmd/copilot/copilot.go) can download Copilot on first interactive use; it does not bundle the standalone binary. Windows installs and verifies the standalone CLI explicitly so it is ready without a first-use download. Sign-in and a suitable subscription are still required.

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

#### Work Mode Only (`-Work`)

1. Sets the current user's npm registry to the 1ES package feed proxy (`https://packagefeedproxy.microsoft.io/npm/`), only when it differs.
1. Installs Agency through Microsoft's documented InstallTool (`https://aka.ms/InstallTool.ps1`, product `agency`), unless Agency is already installed.

These steps run in non-elevated Phase 2. They do not set HTTP proxy options, copy authentication tokens, or change Personal-mode configuration. Corporate network access and any required authentication must already be available; failures stop with guidance to retry Phase 2.

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

Windows Terminal supports per-user fonts, so font setup no longer requests a second elevation just to copy fonts into the Windows directory. Restart Terminal after installation if font discovery has not refreshed. On a fresh install, setup creates an explicit PowerShell Preview profile when Terminal has not generated its dynamic profiles yet.

Setup no longer changes the **Run as different user** Start-menu policy or removes an existing value. [Microsoft documents this policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-startmenu#showrunasdifferentuserinstart) as applying only to supported Start applications, not a general File Explorer menu switch. Managed policy keys may deny writes even under HKCU; a registry value alone does not verify GUI behavior. For supported desktop apps, use Shift+right-click on the application's taskbar jump-list entry instead. If Start-menu policy is required, have your administrator manage it through Group Policy/MDM; the bootstrap does not bypass that policy.

### macOS (`altered-carbon-mac.sh`)

#### Core (Both Modes)

1. Visual Studio Code
1. Visual Studio Code Insiders
1. GitHub Desktop
1. Podman engine/CLI *(`podman` formula)* and Podman Desktop *(`podman-desktop` cask)*
1. Microsoft Foundry Local *(Apple Silicon/macOS 15+ only, with a user login LaunchAgent; no CUDA installation on macOS)*
1. PowerShell (7)
1. git
1. git LFS
1. Node.js
1. GitHub CLI *(`gh copilot` can offer an interactive first-use download; standalone `copilot` is not provisioned by the macOS script)*
1. GitHub Copilot App *(desktop, `github-copilot-app` cask; separate from the CLI and editor extensions)*
1. Squad CLI *(`@bradygaster/squad-cli`, via official Homebrew cask `bradygaster/squad/squad`)*
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
1. Ghostty
1. PowerShell modules (macOS-compatible subset):
    1. Microsoft.Graph
    1. Az
    1. ExchangeOnlineManagement
    1. MicrosoftTeams
    1. PnP.PowerShell
    1. MicrosoftPowerBIMgmt
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

Work mode includes all personal apps plus:

1. The current user's npm registry set to the 1ES package feed proxy (`https://packagefeedproxy.microsoft.io/npm/`), only when it differs.
1. Agency installed through Microsoft's documented InstallTool (`https://aka.ms/InstallTool.sh`, product `agency`), unless already installed.

These Work-only steps do not set HTTP proxy options or copy authentication tokens. Corporate network access and any required authentication must already be available. Personal runs do not configure the work feed or install Agency.

#### Configuration Applied

1. oh-my-posh theme in zsh (`~/.zshrc`) and PowerShell (`$PROFILE`), default: `night-owl`
1. Managed oh-my-posh config stored in `~/.config/altered-carbon/`
1. The same customized theme used on Windows, including the battery-status segment, stored in `~/.config/oh-my-posh/themes/`
1. Ghostty config at `~/.config/ghostty/config` updated with selected Nerd Font Mono variant, 14pt font size, and a dark theme (`night-owl` when available, `Catppuccin Frappe` fallback)
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

The [GitHub Copilot desktop app](https://github.com/github/app#install) is installed through the verified [Microsoft Store product](https://apps.microsoft.com/detail/xpdck2l0r6v76j) on Windows (`winget install --id XPDCK2L0R6V76J --exact --source msstore`) and the [Homebrew cask](https://formulae.brew.sh/cask/github-copilot-app) on macOS (`brew install --cask github-copilot-app`). These packages select the appropriate architecture. Existing user/system Windows uninstall registrations must match both the desktop product name and GitHub publisher for verification; the CLI alone does not satisfy it. macOS checks the `GitHub Copilot.app` bundle. Sign-in remains manual. Skip with `-SkipPackages 'XPDCK2L0R6V76J'` or `--skip github-copilot-app`.

Squad uses the author's [official native installation commands](https://github.com/bradygaster/squad/blob/dev/README.md#2-install-squad): `winget install --id bradygaster.Squad --exact` on Windows and `brew install --cask bradygaster/squad/squad` on macOS, through the existing unattended install/upgrade helpers (not npm). It is included in both modes. Skip it with `-SkipPackages 'bradygaster.Squad'` or `--skip bradygaster/squad/squad` (`--skip squad` also works). Windows installs it in Phase 1 and verifies `squad --version` in Phase 2, including the saved report; macOS checks it in the final summary. Native packages include their own Node.js runtime.

The [upstream installation guide](https://github.github.io/squad/docs/get-started/installation/) notes that WinGet publication can lag a release and only one Squad channel can own the command. If the stable package is unavailable or conflicts with an existing preview, insider, or npm installation, review the warning and resolve the installation manually before retrying; setup does not switch channels or fall back to npm. GitHub Copilot CLI and its sign-in are separate prerequisites for running agent teams; on macOS, provision standalone Copilot separately. Project initialization and upgrades remain explicit, per-repository actions; setup does not run them.

Podman and Podman Desktop replace the former macOS Docker Desktop default and are core packages on both platforms. Windows uses [`RedHat.Podman`](https://github.com/microsoft/winget-pkgs/tree/master/manifests/r/RedHat/Podman) and the [documented `RedHat.Podman-Desktop` package](https://podman-desktop.io/docs/installation/windows-install); macOS uses the documented [`brew install podman`](https://podman.io/docs/installation) and [`brew install --cask podman-desktop`](https://podman-desktop.io/docs/installation/macos-install) commands. Upstream documents Homebrew as an alternative, not its recommended installation method; avoid mixing Homebrew and upstream Podman installers.

Setup does **not** uninstall existing Docker software, delete/migrate images or containers, change Docker contexts/sockets, or create/start Podman machines. CLI/Desktop presence checks do not prove a running engine. After installation, complete Podman's prerequisites/onboarding for your platform, then explicitly create/start a machine (`podman machine init`, `podman machine start`) and check `podman info`. On Windows, feature enablement alone is insufficient: finish WSL runtime installation/update or configure Hyper-V as documented before initializing a machine. Skip engine and desktop separately with `-SkipPackages 'RedHat.Podman','RedHat.Podman-Desktop'` or `--skip podman --skip podman-desktop`.

### Foundry Local and the Copilot desktop provider

Both modes install Microsoft's [Foundry Local CLI](https://learn.microsoft.com/en-us/azure/foundry-local/reference/reference-cli) without downloading or loading models. Windows uses `winget install --id Microsoft.FoundryLocal --exact --source winget --scope user` in **non-elevated Phase 2**, not machine-wide Phase 1. This automation targets the tested Windows 11 24H2+ x64/ARM64 baseline; it explicitly skips other Windows configurations rather than treating an installer's minimum OS as a runtime guarantee. macOS uses the [official tap](https://github.com/microsoft/homebrew-foundrylocal), `brew tap microsoft/foundrylocal` then `brew install microsoft/foundrylocal/foundrylocal`, only on native Apple Silicon/macOS 15+. Existing installations are preserved; an older CLI missing the documented server flags produces an actionable upgrade error, not a guessed legacy command.

The owned supervisor starts `foundry server start --port 39839 --idle-timeout 0`, checks the documented `/openai/status` response, and keeps checking the daemon while logged in. Readiness is bounded; failure is an error with log paths, not a successful provider configuration. A healthy existing endpoint is reused without a restart. Occupied ports and existing daemons on another port are left alone: inspect `foundry server status`, resolve the conflict, and rerun. No unrelated process is killed, server restarted, or service/job removed. Status verification does not call `foundry model list` (which can download execution providers), and does not prove a model is available for inference.

- **Windows:** per-SID task `altered-carbon-foundry-local-<SID>` uses an interactive, limited user principal, logon trigger, `IgnoreNew`, no execution time limit, and permits battery operation. Wrapper/logs: `%LOCALAPPDATA%\altered-carbon\foundry-local` (`startup.log`, `server-start.log`, `server-start-error.log`). It is separate from the one-shot Phase 2 resume task.
- **macOS:** `~/Library/LaunchAgents/io.altered-carbon.foundry-local.plist` runs a persistent foreground Python supervisor with `RunAtLoad`/`KeepAlive` and a 60-second retry throttle. It does not use `brew services` or repeatedly launch a short-lived daemon starter. Python 3 from Xcode command line tools and a logged-in GUI session are required. Wrapper/logs: `${XDG_CONFIG_HOME:-$HOME/.config}/altered-carbon/foundry-local` (`startup.log`, `startup-error.log`, `server-start.log`). There is no battery restriction.

Autostart means **after user login following reboot**, not a pre-login/system service. Matching owned registrations are reused; conflicting unowned registrations/files are not overwritten. Skip installation **and registration** with `-SkipPackages 'Microsoft.FoundryLocal'` or `--skip foundrylocal` (the fully qualified formula also works). Skipping does not disable previously configured autostart. To disable it explicitly, use Task Scheduler for the named Windows task, or `launchctl bootout "gui/$(id -u)/io.altered-carbon.foundry-local"` and remove its owned plist on macOS. This does not stop an already running Foundry daemon.

The [GitHub Copilot desktop app documents UI-based model provider setup](https://docs.github.com/en/copilot/how-tos/github-copilot-app/add-llm-models), not a supported provider configuration file/API. Open **Settings > Model providers > Add provider > Foundry Local**, using **`http://127.0.0.1:39839/v1`** where an endpoint is requested. Select and download a model **explicitly**, subject to its license, disk/memory requirements, and hardware support. Discover the actual model ID from your installation rather than copying a placeholder: `foundry model list --verbose` can download execution providers on first use; `GET /openai/models` lists cached models without choosing/downloading one. Use the actual discovered ID in clients. Setup does not edit app settings, invent a provider schema/API key, touch credentials/credential stores, or claim automatic provider success.

### NVIDIA CUDA Toolkit

CUDA is a separate development toolkit, **not an NVIDIA driver install** or a prerequisite check for Copilot provider configuration. Elevated Windows Phase 1 installs exact package `Nvidia.CUDA` only on documented Windows x64 builds, after finding a present healthy PCI NVIDIA display adapter and successfully querying `nvidia-smi` for compute capability and driver version. AMD/Intel/no GPU, missing/broken drivers, failed queries, and unknown capabilities are explicitly skipped. Remote Desktop/headless sessions are not rejected merely for being remote/headless. The `CUDA Version` banner in `nvidia-smi` describes driver support, not an installed toolkit.

- Known modern capabilities **7.5, 8.0, 8.6, 8.7, 8.9, 9.0, 10.0, 10.3, 11.0, 12.0, 12.1** select **CUDA 13.5**, conservatively requiring an existing **620+ driver** for full support. This release's Windows toolkit does not bundle a display driver.
- Known legacy capabilities **5.0, 5.2, 5.3, 6.0, 6.1, 6.2, 7.0, 7.2** select **CUDA 12.9** (WinGet's 12.9.1 installer), requiring an existing **576.57+ driver**. CUDA 13 dropped pre-7.5 compilation. As documented in the [12.9.1 Windows silent installation guide](https://docs.nvidia.com/cuda/archive/12.9.1/cuda-installation-guide-microsoft-windows/index.html#install-the-cuda-software), `--override` supplies `-s -n` and an explicit allowlist of versioned compiler/runtime/math-library/header/development subpackages, **excluding `Display.Driver`**; the unsafe default bundled-driver installation is never used. Optional profilers, samples, documentation, and Nsight are not requested.
- For multiple GPUs, all queried devices must be understood and driver-compatible; legacy devices select 12.9. Mixed generations not covered by that toolkit are left for explicit side-by-side installation. Version 12.9 does not automate installation on Windows 11 25H2, absent from its OS matrix.

Setup checks `nvcc --version` and `--list-gpu-arch`, including versioned toolkit directories and `CUDA_PATH*` when PATH is stale. An existing compatible compiler/toolkit is preserved, rather than upgraded needlessly. Newer toolkits are never uninstalled/downgraded or automatically displaced; unresolved side-by-side needs produce guidance. Installation is checked again for the actual compiler and all required GPU targets. Compiling CUDA C++ applications still requires a supported Visual Studio C++ toolchain; setup does not build/run a GPU workload or promise every library supports every legacy device.

Skip with `-SkipPackages 'Nvidia.CUDA'`. Modern macOS explicitly skips CUDA (10.2 was NVIDIA's last macOS toolkit). These gates follow NVIDIA's [current](https://developer.nvidia.com/cuda/gpus) and [legacy](https://developer.nvidia.com/cuda/gpus/legacy) capability tables and [Windows installation guide](https://docs.nvidia.com/cuda/cuda-installation-guide-microsoft-windows/index.html). CUDA toolkit support for older GPUs must not be confused with Foundry's separate CUDA execution-provider requirements (RTX 30-series or later in its current CLI documentation).

Windows uses **winget / Microsoft Store** for applications, **npm** for Work IQ, **PowerShell Gallery** for modules, and publisher tools for fonts and Agency. Chocolatey is no longer bootstrapped just to install git and Node.js; existing Chocolatey installations are left untouched. PATH is refreshed from the registry before downstream tools run. Most package versions are intentionally unpinned; CUDA uses the compatibility-pinned versions above.

Every Gallery module lookup/save/install explicitly selects `-Repository PSGallery` on both platforms, including the PowerShell generated by the macOS script. Windows continues saving into the intended `~\.psmodule` path, not a custom feed or an implicit default module directory. Existing repository registrations, source URLs, and trust policies are preserved; missing PSGallery is registered with its default policy. These changes do not perform an out-of-band module repair or alter other repositories.

Hyper-V is edition-dependent. Its absence on Windows Home does not prevent enabling the WSL prerequisite features. Run `wsl --install` after reboot to install WSL and a Linux distribution; the script only enables Windows features.

On macOS, the script runs `brew update` and upgrades each managed formula or cask when Homebrew reports it is outdated. Applications found outside Homebrew are left untouched. PowerShell Gallery modules are also compared with the current gallery version and updated when needed.