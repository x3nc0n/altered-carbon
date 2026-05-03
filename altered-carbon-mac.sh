#!/usr/bin/env bash
# altered-carbon-mac.sh — Bootstrap a fresh macOS developer environment.
#
# Usage:
#   ./altered-carbon-mac.sh --personal                          # personal mode (core apps)
#   ./altered-carbon-mac.sh --work                              # work mode (core + personal + work apps)
#   ./altered-carbon-mac.sh --personal --omp-theme catppuccin   # different oh-my-posh theme
#   ./altered-carbon-mac.sh --work --nerd-font FiraCode         # different Nerd Font
#   ./altered-carbon-mac.sh --personal --skip spotify           # skip specific packages
#   ./altered-carbon-mac.sh --work --extra firefox              # add extra casks

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

MODE=""
OMP_THEME="night-owl"
NERD_FONT="CodeNewRoman"
SKIP_PACKAGES=()
EXTRA_PACKAGES=()

# ── Colours ───────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Colour

info()    { printf "${CYAN}%s${NC}\n" "$*"; }
ok()      { printf "${GREEN}  Done: %s${NC}\n" "$*"; }
skip()    { printf "${YELLOW}  Skipped: %s${NC}\n" "$*"; }
warn()    { printf "${YELLOW}  Warning: %s${NC}\n" "$*" >&2; }
fail()    { printf "${RED}  Error: %s${NC}\n" "$*" >&2; }

# ── Argument Parsing ──────────────────────────────────────────────────────────

print_usage() {
    cat <<EOF
Usage: $(basename "$0") --personal | --work [OPTIONS]

Modes:
  --personal, -p    Install core apps (dev tools, productivity, media)
  --work, -w        Install everything from personal + work-only apps

Options:
  --omp-theme NAME  oh-my-posh theme (default: night-owl)
  --nerd-font NAME  Nerd Font to install (default: CodeNewRoman)
  --skip PKG        Brew formula/cask to skip (repeatable)
  --extra PKG       Extra brew cask to install (repeatable)
  --help, -h        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --personal|-p) MODE="personal"; shift ;;
        --work|-w)     MODE="work"; shift ;;
        --omp-theme)   OMP_THEME="$2"; shift 2 ;;
        --nerd-font)   NERD_FONT="$2"; shift 2 ;;
        --skip)        SKIP_PACKAGES+=("$2"); shift 2 ;;
        --extra)       EXTRA_PACKAGES+=("$2"); shift 2 ;;
        --help|-h)     print_usage; exit 0 ;;
        *)             fail "Unknown argument: $1"; print_usage; exit 1 ;;
    esac
done

if [[ -z "$MODE" ]]; then
    fail "You must specify --personal or --work."
    print_usage
    exit 1
fi

# ── Helper Functions ──────────────────────────────────────────────────────────

is_skipped() {
    local pkg="$1"
    if [[ ${#SKIP_PACKAGES[@]} -gt 0 ]]; then
        for s in "${SKIP_PACKAGES[@]}"; do
            [[ "$s" == "$pkg" ]] && return 0
        done
    fi
    return 1
}

APP_EXISTS_LOCATION=""

app_exists() {
    local app_name="$1"
    local system_app="/Applications/${app_name}.app"
    local user_app="$HOME/Applications/${app_name}.app"

    APP_EXISTS_LOCATION=""

    if [[ -d "$system_app" ]]; then
        APP_EXISTS_LOCATION="/Applications"
        return 0
    fi

    if [[ -d "$user_app" ]]; then
        APP_EXISTS_LOCATION="~/Applications"
        return 0
    fi

    return 1
}

ensure_formula() {
    local formula="$1"
    local name="${2:-$formula}"

    if is_skipped "$formula"; then
        skip "$name (skipped by --skip)"
        return 0
    fi

    info "Checking $name ($formula)..."
    if brew list --formula "$formula" &>/dev/null; then
        skip "$name already installed."
    else
        brew install "$formula" || { warn "Failed to install $name"; return 1; }
        ok "$name installed."
    fi
}

ensure_cask() {
    local cask="$1"
    local name="${2:-$cask}"
    local app_name="${3:-}"

    if is_skipped "$cask"; then
        skip "$name (skipped by --skip)"
        return 0
    fi

    info "Checking $name ($cask)..."
    if [[ -n "$app_name" ]] && app_exists "$app_name"; then
        skip "$name already installed (found in ${APP_EXISTS_LOCATION})."
    elif brew list --cask "$cask" &>/dev/null; then
        skip "$name already installed."
    else
        brew install --cask "$cask" || { warn "Failed to install $name"; return 1; }
        ok "$name installed."
    fi
}

ensure_vscode_ext() {
    local editor="$1"
    local ext_id="$2"
    local ext_name="$3"

    if ! command -v "$editor" &>/dev/null; then
        return 1
    fi

    local installed
    installed=$("$editor" --list-extensions 2>/dev/null)
    if echo "$installed" | grep -qi "^${ext_id}$"; then
        skip "$ext_name already installed in $editor."
    else
        info "  Installing $ext_name in $editor..."
        "$editor" --install-extension "$ext_id" --force &>/dev/null
        ok "$ext_name installed in $editor."
    fi
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

info "altered-carbon-mac: bootstrapping macOS environment (mode: $MODE)"
echo ""

# Prompt for admin password once and keep sudo credentials cached for the
# duration of the script.  Homebrew cask installs call sudo internally, so
# this prevents repeated password prompts.
info "Requesting administrator privileges (you will only be prompted once)..."
sudo -v
# Keep-alive: refresh sudo timestamp every 60 s until this script exits.
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
# Ensure the keepalive loop is cleaned up on exit.
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
ok "Administrator privileges cached."
echo ""

# Ensure Homebrew is installed
if ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add brew to PATH for this session (Apple Silicon vs Intel)
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    ok "Homebrew installed."
else
    skip "Homebrew already installed."
fi

info "Updating Homebrew..."
brew update --quiet
ok "Homebrew updated."

# ── Homebrew Formulae ─────────────────────────────────────────────────────────

info "Installing Homebrew formulae..."
echo ""

ensure_formula git "git"
ensure_formula git-lfs "git LFS"
ensure_formula gh "GitHub CLI"
ensure_formula node "Node.js"
ensure_formula dotnet "dotnet SDK"
ensure_formula powershell "PowerShell"
ensure_formula openjdk@17 "OpenJDK 17"
ensure_formula oh-my-posh "oh-my-posh"
ensure_formula mas "Mac App Store CLI"
ensure_formula azure-cli "Azure CLI"

# git-lfs setup (idempotent)
if command -v git-lfs &>/dev/null; then
    git lfs install --skip-repo &>/dev/null
fi

echo ""

# ── Homebrew Casks (Core) ────────────────────────────────────────────────────

info "Installing core casks..."
echo ""

ensure_cask visual-studio-code "Visual Studio Code" "Visual Studio Code"
ensure_cask visual-studio-code@insiders "Visual Studio Code Insiders" "Visual Studio Code - Insiders"
ensure_cask github "GitHub Desktop" "GitHub Desktop"
ensure_cask docker "Docker Desktop" "Docker"
ensure_cask microsoft-edge "Microsoft Edge" "Microsoft Edge"
ensure_cask microsoft-teams "Microsoft Teams" "Microsoft Teams"
ensure_cask microsoft-outlook "Microsoft Outlook" "Microsoft Outlook"
ensure_cask microsoft-excel "Microsoft Excel" "Microsoft Excel"
ensure_cask microsoft-word "Microsoft Word" "Microsoft Word"
ensure_cask microsoft-powerpoint "Microsoft PowerPoint" "Microsoft PowerPoint"
ensure_cask microsoft-onenote "Microsoft OneNote" "Microsoft OneNote"
ensure_cask windows-app "Windows App" "Windows App"
ensure_cask logitune "Logi Tune" "Logi Tune"
ensure_cask github-copilot-for-xcode "GitHub Copilot for Xcode" "GitHub Copilot for Xcode"
ensure_cask spotify "Spotify" "Spotify"

echo ""

# ── Personal Casks ───────────────────────────────────────────────────────────

# Personal casks are always installed — both personal and work modes include them.
info "Installing personal casks..."
echo ""

ensure_cask steam "Steam" "Steam"
ensure_cask discord "Discord" "Discord"
ensure_cask signal "Signal" "Signal"
ensure_cask brave-browser "Brave Browser" "Brave Browser"
ensure_cask lm-studio "LM Studio" "LM Studio"
ensure_cask moonlight "Moonlight" "Moonlight"
ensure_cask comfyui "ComfyUI" "ComfyUI"
ensure_cask bitwarden "Bitwarden" "Bitwarden"
ensure_cask canva "Canva" "Canva"
ensure_cask parallels "Parallels Desktop" "Parallels Desktop"
ensure_cask android-studio "Android Studio" "Android Studio"
ensure_cask wifiman "WiFiman Desktop" "WiFiman Desktop"

# Ruby toolchain
ensure_formula chruby "chruby"
ensure_formula ruby-install "ruby-install"

echo ""

# ── Work-Only Packages ───────────────────────────────────────────────────────

if [[ "$MODE" == "work" ]]; then
    info "Installing work-only packages..."
    echo ""
    # Placeholder — add work-only packages here as needed.
    # Example: ensure_cask intune-company-portal "Intune Company Portal"
    skip "No work-only packages configured yet."
    echo ""
fi

# ── Extra Packages ───────────────────────────────────────────────────────────

if [[ ${#EXTRA_PACKAGES[@]} -gt 0 ]]; then
    info "Installing extra packages..."
    for pkg in "${EXTRA_PACKAGES[@]}"; do
        ensure_cask "$pkg" "$pkg"
    done
    echo ""
fi

# ── Xcode Command Line Tools ────────────────────────────────────────────────

info "Checking Xcode Command Line Tools..."
if xcode-select -p &>/dev/null; then
    skip "Xcode Command Line Tools already installed."
else
    info "  Installing Xcode Command Line Tools..."
    xcode-select --install 2>/dev/null || true
    warn "Xcode CLT install triggered. Complete the dialog, then re-run this script."
fi
echo ""

# ── GitHub Copilot CLI ───────────────────────────────────────────────────────

info "Ensuring GitHub Copilot CLI extension is installed..."
if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
        if gh extension list 2>/dev/null | grep -q 'gh-copilot'; then
            info "  Updating GitHub Copilot CLI extension..."
            gh extension upgrade github/gh-copilot &>/dev/null && ok "GitHub Copilot CLI extension is up to date." || warn "Failed to upgrade Copilot CLI extension."
        else
            info "  Installing GitHub Copilot CLI extension..."
            gh extension install github/gh-copilot &>/dev/null && ok "GitHub Copilot CLI extension installed." || warn "Failed to install Copilot CLI extension."
        fi
    else
        warn "GitHub CLI is not authenticated. Run 'gh auth login' first."
    fi
else
    warn "GitHub CLI (gh) not found. Copilot CLI extension setup skipped."
fi
echo ""

# ── Nerd Font ────────────────────────────────────────────────────────────────

info "Installing Nerd Font '$NERD_FONT'..."
if command -v oh-my-posh &>/dev/null; then
    # Check if font is already installed by looking in the system and user font dirs
    font_pattern=$(echo "$NERD_FONT" | sed 's/\([a-z]\)\([A-Z]\)/\1.*\2/g')
    if find ~/Library/Fonts /Library/Fonts -iname "*${NERD_FONT}*NerdFont*" -print -quit 2>/dev/null | grep -q .; then
        skip "$NERD_FONT Nerd Font already installed."
    else
        oh-my-posh font install "$NERD_FONT" && ok "$NERD_FONT Nerd Font installed." || warn "Failed to install $NERD_FONT Nerd Font."
    fi
else
    warn "oh-my-posh not found. Nerd Font installation skipped."
fi
echo ""

# ── VS Code Extensions ──────────────────────────────────────────────────────

VSCODE_EXTENSIONS=(
    "ms-azuretools.vscode-azureresourcegroups|Azure Resources"
    "ms-azuretools.vscode-bicep|Bicep"
    "github.copilot|GitHub Copilot"
    "github.copilot-chat|GitHub Copilot Chat"
    "ms-azuretools.vscode-azure-github-copilot|GitHub Copilot for Azure"
    "ms-windows-ai-studio.windows-ai-studio|AI Toolkit for VS Code"
    "ms-security.ms-sentinel|Microsoft Sentinel"
)

for editor in code code-insiders; do
    if ! command -v "$editor" &>/dev/null; then
        info "Skipping $editor extensions ($editor not found on PATH)."
        continue
    fi

    info "Installing VS Code extensions ($editor)..."
    for entry in "${VSCODE_EXTENSIONS[@]}"; do
        ext_id="${entry%%|*}"
        ext_name="${entry##*|}"
        ensure_vscode_ext "$editor" "$ext_id" "$ext_name"
    done
    echo ""
done

# ── PowerShell Modules ───────────────────────────────────────────────────────

# Only modules known to work on macOS are included.
PS_MODULES=(
    "Microsoft.Graph|Microsoft Graph"
    "Az|Azure PowerShell"
    "ExchangeOnlineManagement|Exchange Online Management"
    "MicrosoftTeams|Microsoft Teams"
    "PnP.PowerShell|PnP PowerShell (SharePoint / M365)"
    "MicrosoftPowerBIMgmt|Power BI Management"
    "Microsoft365DSC|Microsoft 365 DSC"
    "Microsoft.Graph.Intune|Microsoft Graph Intune"
    "MSAL.PS|MSAL.PS (token acquisition)"
)

if command -v pwsh &>/dev/null; then
    info "Installing PowerShell modules..."
    for entry in "${PS_MODULES[@]}"; do
        mod_name="${entry%%|*}"
        mod_desc="${entry##*|}"
        info "  Checking $mod_desc ($mod_name)..."
        if pwsh -NoProfile -Command "if (Get-Module -ListAvailable -Name '$mod_name') { exit 0 } else { exit 1 }" 2>/dev/null; then
            skip "$mod_name already installed."
        else
            pwsh -NoProfile -Command "Install-Module -Name '$mod_name' -Scope CurrentUser -Force -AcceptLicense -ErrorAction SilentlyContinue" 2>/dev/null \
                && ok "$mod_name installed." \
                || warn "Failed to install $mod_name (may not be available on macOS)."
        fi
    done
    echo ""
else
    warn "PowerShell (pwsh) not found. Module installation skipped."
fi

# ── oh-my-posh Configuration ────────────────────────────────────────────────

MANAGED_DIR="$HOME/.config/altered-carbon"
OMP_ZSH_FILE="$MANAGED_DIR/omp.zsh"
OMP_PWSH_FILE="$MANAGED_DIR/omp-profile.ps1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_DIR="$HOME/.config/oh-my-posh/themes"

mkdir -p "$MANAGED_DIR" "$THEME_DIR"

# Copy theme from repo if available, otherwise download it
REPO_THEME="$SCRIPT_DIR/${OMP_THEME}.omp.json"
DEST_THEME="$THEME_DIR/${OMP_THEME}.omp.json"

if [[ -f "$REPO_THEME" ]]; then
    cp "$REPO_THEME" "$DEST_THEME"
    ok "Copied $OMP_THEME theme from repo to $DEST_THEME"
elif [[ -f "$DEST_THEME" ]]; then
    skip "$OMP_THEME theme already exists at $DEST_THEME"
else
    info "Downloading $OMP_THEME theme..."
    curl -fsSL "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/${OMP_THEME}.omp.json" -o "$DEST_THEME" \
        && ok "$OMP_THEME theme downloaded." \
        || warn "Failed to download $OMP_THEME theme. oh-my-posh will use its default."
fi

# Write managed zsh config (sourced by ~/.zshrc)
info "Configuring oh-my-posh for zsh..."
cat > "$OMP_ZSH_FILE" <<'ZSHEOF'
# ── oh-my-posh (managed by altered-carbon) ───────────────────────────────────
if command -v oh-my-posh &>/dev/null; then
    _omp_theme="__THEME_DIR__/__OMP_THEME__.omp.json"
    if [[ -f "$_omp_theme" ]]; then
        eval "$(oh-my-posh init zsh --config "$_omp_theme")"
    else
        eval "$(oh-my-posh init zsh)"
    fi
    unset _omp_theme
fi
# ── end oh-my-posh ───────────────────────────────────────────────────────────
ZSHEOF
# Replace placeholders
sed -i '' "s|__THEME_DIR__|$THEME_DIR|g" "$OMP_ZSH_FILE"
sed -i '' "s|__OMP_THEME__|$OMP_THEME|g" "$OMP_ZSH_FILE"
ok "oh-my-posh zsh config written to $OMP_ZSH_FILE"

# Add source line to ~/.zshrc if not already present
ZSHRC="$HOME/.zshrc"
SOURCE_LINE="# altered-carbon: oh-my-posh"
if [[ -f "$ZSHRC" ]] && grep -qF "$SOURCE_LINE" "$ZSHRC"; then
    skip "oh-my-posh source line already in ~/.zshrc"
else
    {
        echo ""
        echo "$SOURCE_LINE"
        echo "[ -f \"$OMP_ZSH_FILE\" ] && source \"$OMP_ZSH_FILE\""
    } >> "$ZSHRC"
    ok "Added oh-my-posh source line to ~/.zshrc"
fi

# Write managed PowerShell profile config
if command -v pwsh &>/dev/null; then
    info "Configuring oh-my-posh for PowerShell..."
    cat > "$OMP_PWSH_FILE" <<PSEOF
# ── oh-my-posh (managed by altered-carbon) ───────────────────────────────────
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    \$_ompConfig = '$DEST_THEME'
    if (Test-Path \$_ompConfig) {
        oh-my-posh init pwsh --config \$_ompConfig | Invoke-Expression
    } else {
        oh-my-posh init pwsh | Invoke-Expression
    }
}
# ── end oh-my-posh ───────────────────────────────────────────────────────────
PSEOF
    ok "oh-my-posh PowerShell config written to $OMP_PWSH_FILE"

    # Add source line to PowerShell profile if not already present
    PS_PROFILE=$(pwsh -NoProfile -Command 'Write-Output $PROFILE' 2>/dev/null)
    if [[ -n "$PS_PROFILE" ]]; then
        PS_PROFILE_DIR=$(dirname "$PS_PROFILE")
        mkdir -p "$PS_PROFILE_DIR"

        if [[ -f "$PS_PROFILE" ]] && grep -qF "altered-carbon" "$PS_PROFILE"; then
            skip "oh-my-posh source line already in PowerShell profile."
        else
            {
                echo ""
                echo "# altered-carbon: oh-my-posh"
                echo ". '$OMP_PWSH_FILE'"
            } >> "$PS_PROFILE"
            ok "Added oh-my-posh source line to $PS_PROFILE"
        fi
    fi
fi
echo ""

# ── Finder Configuration ────────────────────────────────────────────────────

info "Configuring Finder..."

# Show all file extensions
defaults write NSGlobalDomain AppleShowAllExtensions -bool true

# Show hidden files
defaults write com.apple.finder AppleShowAllFiles -bool true

# Show path bar at bottom of Finder
defaults write com.apple.finder ShowPathbar -bool true

# Show status bar
defaults write com.apple.finder ShowStatusBar -bool true

# Use list view by default
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"

# Keep folders on top when sorting by name
defaults write com.apple.finder _FXSortFoldersFirst -bool true

# Restart Finder to apply
killall Finder 2>/dev/null || true
ok "Finder configured (extensions, hidden files, path bar, status bar)."
echo ""

# ── VS Code Font Configuration ──────────────────────────────────────────────

info "Configuring VS Code editor font..."

FONT_FACE_MONO="${NERD_FONT} Nerd Font Mono"

for settings_dir in \
    "$HOME/Library/Application Support/Code/User" \
    "$HOME/Library/Application Support/Code - Insiders/User"; do

    label="VS Code"
    [[ "$settings_dir" == *"Insiders"* ]] && label="VS Code Insiders"
    settings_file="$settings_dir/settings.json"

    if [[ ! -d "$settings_dir" ]]; then
        skip "$label settings directory not found."
        continue
    fi

    if [[ ! -f "$settings_file" ]]; then
        mkdir -p "$settings_dir"
        echo '{}' > "$settings_file"
    fi

    # Use python to safely update JSON (available on macOS by default)
    python3 -c "
import json, sys
path = sys.argv[1]
font = sys.argv[2]
with open(path, 'r') as f:
    data = json.load(f)
data['editor.fontFamily'] = f\"'{font}', Menlo, Monaco, 'Courier New', monospace\"
with open(path, 'w') as f:
    json.dump(data, f, indent=4)
" "$settings_file" "$FONT_FACE_MONO" \
        && ok "$label font set to $FONT_FACE_MONO." \
        || warn "Failed to configure $label font."
done
echo ""

# ── Verification Summary ────────────────────────────────────────────────────

info "Post-install verification summary..."
echo ""

verify() {
    local label="$1"
    local cmd="$2"
    shift 2
    local version_args=("$@")
    [[ ${#version_args[@]} -eq 0 ]] && version_args=("--version")

    if command -v "$cmd" &>/dev/null; then
        local ver
        ver=$("$cmd" "${version_args[@]}" 2>/dev/null | head -1)
        printf "${GREEN}  [OK]${NC} %-30s %s\n" "$label" "$ver"
    else
        printf "${YELLOW}  [MISSING]${NC} %-30s\n" "$label"
    fi
}

verify "git" git
verify "git LFS" git-lfs
verify "GitHub CLI" gh
verify "Node.js" node
verify "npm" npm
verify "dotnet" dotnet
verify "PowerShell" pwsh
verify "Java" java "-version"
verify "oh-my-posh" oh-my-posh
verify "Docker" docker
verify "Azure CLI" az "--version"
verify "Ruby" ruby "--version"

# GitHub Copilot CLI
if command -v gh &>/dev/null && gh extension list 2>/dev/null | grep -q 'gh-copilot'; then
    printf "${GREEN}  [OK]${NC} %-30s %s\n" "GitHub Copilot CLI" "gh extension installed"
else
    printf "${YELLOW}  [MISSING]${NC} %-30s\n" "GitHub Copilot CLI"
fi

# VS Code extensions
for editor in code code-insiders; do
    if command -v "$editor" &>/dev/null; then
        label="VS Code"
        [[ "$editor" == "code-insiders" ]] && label="VS Code Insiders"
        printf "${GREEN}  [OK]${NC} %-30s %s\n" "$label" "CLI available"

        installed=$("$editor" --list-extensions 2>/dev/null)
        for ext_entry in "${VSCODE_EXTENSIONS[@]}"; do
            ext_id="${ext_entry%%|*}"
            ext_name="${ext_entry##*|}"
            if echo "$installed" | grep -qi "^${ext_id}$"; then
                printf "${GREEN}  [OK]${NC}   %-28s %s\n" "$ext_name" "$ext_id"
            else
                printf "${YELLOW}  [MISSING]${NC}   %-28s %s\n" "$ext_name" "$ext_id"
            fi
        done
    fi
done

echo ""
printf "${GREEN}Setup complete.${NC}\n"
