#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/altered-carbon-mac.sh"
PYTHON="${PYTHON:-python3}"
export PYTHONUTF8=1
TEST_SANDBOX_ROOT="$TESTS_DIR/.sandbox/altered-carbon-mac-tests.$$"
APP_SYSTEM_DIR="$TEST_SANDBOX_ROOT/system-applications"
APP_USER_DIR="$TEST_SANDBOX_ROOT/home/Applications"

SKIP_PACKAGES=()
APP_EXISTS_LOCATION=""
BREW_LIST_CASK_STATUS=1
BREW_OUTDATED_CASK_OUTPUT=""
BREW_INSTALL_STATUS=0
BREW_CALLS=()
EVENTS=()
CURRENT_TEST=""

cleanup() {
    rm -rf "$TEST_SANDBOX_ROOT"
}
trap cleanup EXIT

info() { EVENTS+=("info:$*"); }
skip() { EVENTS+=("skip:$*"); }
ok() { EVENTS+=("ok:$*"); }
warn() { EVENTS+=("warn:$*"); }
fail() { EVENTS+=("fail:$*"); }

brew() {
    BREW_CALLS+=("$*")

    if [[ "$1" == "list" && ( "${2:-}" == "--cask" || "${2:-}" == "--formula" ) ]]; then
        return "$BREW_LIST_CASK_STATUS"
    fi

    if [[ "$1" == "outdated" && "${2:-}" == "--quiet" && ( "${3:-}" == "--cask" || "${3:-}" == "--formula" ) ]]; then
        printf '%s' "$BREW_OUTDATED_CASK_OUTPUT"
        return 0
    fi

    if [[ "$1" == "install" || "$1" == "upgrade" ]]; then
        return "$BREW_INSTALL_STATUS"
    fi

    printf 'Unexpected brew invocation in %s: %s\n' "$CURRENT_TEST" "$*" >&2
    return 99
}

load_mac_helpers() {
    local helper_source

    helper_source="$("$PYTHON" - "$SOURCE_SCRIPT" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
start = text.index("is_skipped() {")
end = text.index("ensure_vscode_ext() {")
snippet = text[start:end]
snippet = snippet.replace('local system_app="/Applications/${app_name}.app"', 'local system_app="${APP_SYSTEM_DIR}/${app_name}.app"')
snippet = snippet.replace('local user_app="$HOME/Applications/${app_name}.app"', 'local user_app="${APP_USER_DIR}/${app_name}.app"')
print(snippet, end="")
PY
)"

    eval "$helper_source"
}

fail_test() {
    printf 'not ok - %s: %s\n' "$CURRENT_TEST" "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    [[ "$actual" == "$expected" ]] || fail_test "$message (expected: $expected, actual: $actual)"
}

assert_status() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    [[ "$actual" -eq "$expected" ]] || fail_test "$message (expected: $expected, actual: $actual)"
}

assert_array_empty() {
    local array_name="$1"
    local message="$2"
    local count

    eval "count=\${#$array_name[@]}"
    [[ "$count" -eq 0 ]] || fail_test "$message (actual count: $count)"
}

assert_array_contains() {
    local expected="$1"
    local array_name="$2"
    local message="$3"
    local item

    eval "for item in \"\${$array_name[@]}\"; do
        [[ \"\$item\" == \"$expected\" ]] && return 0
    done"

    fail_test "$message (missing: $expected)"
}

assert_array_not_contains() {
    local unexpected="$1"
    local array_name="$2"
    local message="$3"
    local item

    eval "for item in \"\${$array_name[@]}\"; do
        [[ \"\$item\" == \"$unexpected\" ]] && fail_test \"$message (found: $unexpected)\"
    done"
}

reset_test_state() {
    rm -rf "$TEST_SANDBOX_ROOT"
    mkdir -p "$APP_SYSTEM_DIR" "$APP_USER_DIR"

    SKIP_PACKAGES=()
    APP_EXISTS_LOCATION=""
    BREW_LIST_CASK_STATUS=1
    BREW_OUTDATED_CASK_OUTPUT=""
    BREW_INSTALL_STATUS=0
    BREW_CALLS=()
    EVENTS=()

    load_mac_helpers
}

test_app_exists_detects_system_application() {
    mkdir -p "$APP_SYSTEM_DIR/Orbit.app"

    app_exists "Orbit"
    local status=$?

    assert_status 0 "$status" "app_exists should succeed for apps in /Applications"
    assert_eq "/Applications" "$APP_EXISTS_LOCATION" "app_exists should report the system Applications location"
}

test_app_exists_detects_user_application() {
    mkdir -p "$APP_USER_DIR/Orbit.app"

    app_exists "Orbit"
    local status=$?

    assert_status 0 "$status" "app_exists should succeed for apps in ~/Applications"
    assert_eq "~/Applications" "$APP_EXISTS_LOCATION" "app_exists should report the user Applications location"
}

test_app_exists_clears_location_when_missing() {
    APP_EXISTS_LOCATION="stale"

    if app_exists "Missing App"; then
        local status=0
    else
        local status=$?
    fi

    assert_status 1 "$status" "app_exists should fail when the bundle does not exist"
    assert_eq "" "$APP_EXISTS_LOCATION" "app_exists should clear APP_EXISTS_LOCATION when the bundle is missing"
}

test_app_exists_resets_stale_state_between_calls() {
    mkdir -p "$APP_SYSTEM_DIR/Orbit.app"
    app_exists "Orbit"
    assert_eq "/Applications" "$APP_EXISTS_LOCATION" "app_exists should set the location on success"

    if app_exists "Missing App"; then
        local status=0
    else
        local status=$?
    fi

    assert_status 1 "$status" "app_exists should fail for a missing bundle after a successful lookup"
    assert_eq "" "$APP_EXISTS_LOCATION" "app_exists should reset stale APP_EXISTS_LOCATION values on each call"
}

test_ensure_cask_skips_install_when_app_bundle_exists() {
    mkdir -p "$APP_SYSTEM_DIR/Firefox.app"

    ensure_cask "firefox" "Firefox" "Firefox"

    assert_eq "1" "${#BREW_CALLS[@]}" "ensure_cask should check Homebrew ownership before app bundle detection"
    assert_eq "list --cask firefox" "${BREW_CALLS[0]}" "ensure_cask should check whether Homebrew manages the app"
    assert_array_contains "skip:Firefox already installed outside Homebrew (found in /Applications)." EVENTS "ensure_cask should report the app bundle location when skipping"
}

test_ensure_cask_checks_brew_when_app_name_is_empty() {
    local app_exists_called=0
    BREW_LIST_CASK_STATUS=0

    app_exists() {
        app_exists_called=1
        return 0
    }

    ensure_cask "firefox" "Firefox" ""

    assert_eq "0" "$app_exists_called" "ensure_cask should not call app_exists when app_name is empty"
    assert_eq "1" "${#BREW_CALLS[@]}" "ensure_cask should query Homebrew for an installed cask"
    assert_eq "list --cask firefox" "${BREW_CALLS[0]}" "ensure_cask should check brew list when app_name is empty"
}

test_ensure_cask_checks_brew_when_bundle_is_missing() {
    BREW_LIST_CASK_STATUS=0

    ensure_cask "google-chrome" "Google Chrome" "Google Chrome"

    assert_eq "1" "${#BREW_CALLS[@]}" "ensure_cask should query Homebrew for an installed cask"
    assert_eq "list --cask google-chrome" "${BREW_CALLS[0]}" "ensure_cask should query brew before app bundle detection"
    assert_eq "" "$APP_EXISTS_LOCATION" "ensure_cask should leave APP_EXISTS_LOCATION empty after a miss"
}

test_ensure_cask_respects_skip_before_app_detection() {
    local app_exists_called=0
    SKIP_PACKAGES=("firefox")

    app_exists() {
        app_exists_called=1
        return 0
    }

    ensure_cask "firefox" "Firefox" "Firefox"

    assert_eq "0" "$app_exists_called" "ensure_cask should honor --skip before calling app_exists"
    assert_array_empty BREW_CALLS "ensure_cask should not invoke brew for skipped casks"
    assert_array_contains "skip:Firefox (skipped by --skip)" EVENTS "ensure_cask should report skipped casks"
}

test_ensure_cask_upgrades_outdated_homebrew_owned_app() {
    BREW_LIST_CASK_STATUS=0
    BREW_OUTDATED_CASK_OUTPUT="firefox"
    mkdir -p "$APP_SYSTEM_DIR/Firefox.app"

    ensure_cask "firefox" "Firefox" "Firefox"

    assert_array_contains "upgrade --cask --greedy firefox" BREW_CALLS "Homebrew-owned apps must be upgraded even when their bundle exists"
    assert_array_contains "ok:Firefox upgraded." EVENTS "Successful cask upgrade must be reported"
}

test_ensure_formula_upgrades_outdated_package() {
    BREW_LIST_CASK_STATUS=0
    BREW_OUTDATED_CASK_OUTPUT="gh"

    ensure_formula "gh" "GitHub CLI"

    assert_array_contains "upgrade --formula gh" BREW_CALLS "Outdated formulae must be upgraded"
    assert_array_contains "ok:GitHub CLI upgraded." EVENTS "Successful formula upgrade must be reported"
}

test_install_stages_keep_github_cli_and_editor_copilot_without_standalone_cli() {
    local install_source call

    install_source="$("$PYTHON" - "$SOURCE_SCRIPT" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
start = text.index('info "Installing Homebrew formulae..."')
end = text.index("# ── Work-Only Packages", start)
print(text[start:end], end="")
PY
)"
    git() { EVENTS+=("git:$*"); }
    gh() { fail_test "installation must not invoke gh subcommands: $*"; }
    npm() { fail_test "core installation must not install npm packages: $*"; }
    copilot() { fail_test "installation must not invoke standalone Copilot: $*"; }

    eval "$install_source" >"$TEST_SANDBOX_ROOT/install-output"

    assert_array_contains "install gh" BREW_CALLS "GitHub CLI must still be installed"
    assert_array_contains "install --cask github-copilot-for-xcode" BREW_CALLS "Xcode Copilot must remain installed"
    assert_array_contains "install --cask visual-studio-code" BREW_CALLS "VS Code must remain installed"
    for call in "${BREW_CALLS[@]}"; do
        case "$call" in
            *" github-copilot-for-xcode") ;;
            *copilot*) fail_test "standalone Copilot package operation: $call" ;;
        esac
    done
}

test_verification_executes_github_cli_and_editor_checks_without_standalone_copilot() {
    local verification_source output
    local GREEN="" YELLOW="" NC=""
    local VSCODE_EXTENSIONS=("github.copilot-chat|GitHub Copilot Chat" "ms-azuretools.vscode-azure-github-copilot|GitHub Copilot for Azure")
    local calls_file="$TEST_SANDBOX_ROOT/verification-calls"
    : >"$calls_file"

    verification_source="$("$PYTHON" - "$SOURCE_SCRIPT" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
print(text[text.index("verify() {"):], end="")
PY
)"
    mock_version() { printf '%s\n' "$*" >>"$calls_file"; printf '1.2.3\n'; }
    git() { mock_version "git $*"; }
    git-lfs() { mock_version "git-lfs $*"; }
    gh() { mock_version "gh $*"; }
    node() { mock_version "node $*"; }
    npm() { mock_version "npm $*"; }
    dotnet() { mock_version "dotnet $*"; }
    pwsh() { mock_version "pwsh $*"; }
    java() { mock_version "java $*"; }
    oh-my-posh() { mock_version "oh-my-posh $*"; }
    docker() { mock_version "docker $*"; }
    az() { mock_version "az $*"; }
    ruby() { mock_version "ruby $*"; }
    copilot() { mock_version "copilot $*"; }
    code() { printf 'code %s\n' "$*" >>"$calls_file"; printf 'github.copilot-chat\nms-azuretools.vscode-azure-github-copilot\n'; }
    code-insiders() { printf 'code-insiders %s\n' "$*" >>"$calls_file"; printf 'github.copilot-chat\nms-azuretools.vscode-azure-github-copilot\n'; }

    eval "$verification_source" >"$TEST_SANDBOX_ROOT/verification-output"
    output="$(cat "$TEST_SANDBOX_ROOT/verification-output")"
    grep -qx 'gh --version' "$calls_file" || fail_test "GitHub CLI must be version-checked"
    grep -qx 'code --list-extensions' "$calls_file" || fail_test "VS Code must be checked"
    grep -qx 'code-insiders --list-extensions' "$calls_file" || fail_test "VS Code Insiders must be checked"
    if grep -Eq '^(copilot |gh (copilot|extension))' "$calls_file"; then
        fail_test "verification invoked standalone Copilot or legacy gh extension"
    fi
    [[ "$output" == *"GitHub CLI"*"1.2.3"* ]] || fail_test "GitHub CLI result must be reported"
    [[ "$output" == *"GitHub Copilot Chat"*"github.copilot-chat"* ]] || fail_test "current editor Copilot extension must be reported"
    [[ "$output" != *"built-in"* ]] || fail_test "editor verification must not claim synthetic built-in Copilot"
    [[ "$output" != *"Copilot CLI"* ]] || fail_test "standalone Copilot must not be reported"
}

test_no_standalone_copilot_management_anywhere_in_script() {
    "$PYTHON" - "$SOURCE_SCRIPT" <<'PY' || fail_test "standalone Copilot installation or presence probe remains"
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
patterns = (
    r"@github/copilot\b",
    r"\bgh\s+(?:copilot|extension)\b",
    r"\bcommand\s+-v\s+['\"]?copilot\b",
    r"\bensure_(?:formula|cask)\s+['\"]?(?:github-)?copilot(?:['\"\s]|$)",
    r"(?m)^\s*verify\s+.*(?:Copilot CLI|['\"]?copilot(?:['\"\s]|$))",
)
for pattern in patterns:
    if re.search(pattern, text, re.IGNORECASE):
        raise SystemExit("Forbidden standalone CLI pattern: " + pattern)
PY
}

mock_work_tools() {
    NPM_AVAILABLE=1
    NPM_READ_STATUS=0
    NPM_WRITE_STATUS=0
    AGENCY_AVAILABLE=0
    AGENCY_INSTALL_VISIBLE=0
    CURL_STATUS=0
    INSTALLER_STATUS=0
    WORK_CALLS_FILE="$TEST_SANDBOX_ROOT/work-calls"
    REGISTRY_FILE="$TEST_SANDBOX_ROOT/npm-registry"
    AGENCY_MARKER="$TEST_SANDBOX_ROOT/agency-installed"
    : >"$WORK_CALLS_FILE"
    printf '%s\n' 'https://registry.npmjs.org/' >"$REGISTRY_FILE"

    command() {
        if [[ "${1:-}" == "-v" ]]; then
            case "${2:-}" in
                npm) [[ "$NPM_AVAILABLE" -eq 1 ]] ;;
                agency) [[ "$AGENCY_AVAILABLE" -eq 1 || -f "$AGENCY_MARKER" ]] ;;
                *) fail_test "Unexpected command probe: $*" ;;
            esac
        else
            fail_test "Unexpected command invocation: $*"
        fi
    }
    npm() {
        printf 'npm %s\n' "$*" >>"$WORK_CALLS_FILE"
        case "$*" in
            "config get registry --location=user")
                local registry
                IFS= read -r registry <"$REGISTRY_FILE"
                printf '%s\n' "$registry"
                return "$NPM_READ_STATUS"
                ;;
            "config set registry https://packagefeedproxy.microsoft.io/npm/ --location=user")
                if [[ "$NPM_WRITE_STATUS" -eq 0 ]]; then
                    printf '%s\n' "$4" >"$REGISTRY_FILE"
                fi
                return "$NPM_WRITE_STATUS"
                ;;
            *) fail_test "Unexpected npm invocation: $*" ;;
        esac
    }
    curl() {
        printf 'curl %s\n' "$*" >>"$WORK_CALLS_FILE"
        [[ "$*" == "-sSfL https://aka.ms/InstallTool.sh" ]] || fail_test "Unexpected installer URL: $*"
        return "$CURL_STATUS"
    }
    sh() {
        printf 'sh %s\n' "$*" >>"$WORK_CALLS_FILE"
        [[ "$*" == "-s agency" ]] || fail_test "Unexpected installer arguments: $*"
        if [[ "$INSTALLER_STATUS" -eq 0 && "$AGENCY_INSTALL_VISIBLE" -eq 1 ]]; then
            : >"$AGENCY_MARKER"
        fi
        return "$INSTALLER_STATUS"
    }
}

assert_work_calls() {
    local expected="$1" actual
    actual="$(cat "$WORK_CALLS_FILE")"
    assert_eq "$expected" "$actual" "Work tooling command trace must match"
}

load_work_stage() {
    WORK_STAGE="$("$PYTHON" - "$SOURCE_SCRIPT" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
start = text.index("# ── Work-Only Packages")
end = text.index("# ── Extra Packages", start)
for name in ("configure_work_npm_registry", "install_agency"):
    calls = re.findall(r"(?m)^[ \t]*" + name + r"(?=\s|$)[^\n]*", text)
    assert len(calls) == 1, name + " must have exactly one invocation"
    assert re.search(r"\|\|\s+exit 1\s*$", calls[0]), name + " must propagate failure"
    assert calls[0] in text[start:end], name + " must remain in the Work-only stage"
print(text[start:end], end="")
PY
)" || fail_test "Could not isolate Work-only orchestration"
}

test_work_stage_skips_personal_and_runs_work_in_order() {
    mock_work_tools
    load_work_stage
    configure_work_npm_registry() { printf 'registry\n' >>"$WORK_CALLS_FILE"; }
    install_agency() { printf 'agency\n' >>"$WORK_CALLS_FILE"; }
    local MODE="personal"
    eval "$WORK_STAGE" >"$TEST_SANDBOX_ROOT/work-output"
    assert_work_calls ""
    MODE="work"
    eval "$WORK_STAGE" >"$TEST_SANDBOX_ROOT/work-output"
    assert_work_calls $'registry\nagency'
}

test_work_stage_stops_before_agency_when_registry_fails() {
    mock_work_tools
    load_work_stage
    local MODE="work" status
    NPM_READ_STATUS=17
    if ( eval "$WORK_STAGE" ) >"$TEST_SANDBOX_ROOT/work-output"; then status=0; else status=$?; fi
    assert_status 1 "$status" "Work stage must propagate registry failure"
    assert_work_calls "npm config get registry --location=user"
}

test_work_stage_propagates_agency_failure() {
    mock_work_tools
    load_work_stage
    local MODE="work" status
    printf '%s\n' 'https://packagefeedproxy.microsoft.io/npm/' >"$REGISTRY_FILE"
    INSTALLER_STATUS=23
    if ( eval "$WORK_STAGE" ) >"$TEST_SANDBOX_ROOT/work-output"; then status=0; else status=$?; fi
    assert_status 1 "$status" "Work stage must propagate installer failure"
}

test_work_registry_sets_user_registry_and_second_run_skips() {
    mock_work_tools
    configure_work_npm_registry
    configure_work_npm_registry
    assert_work_calls $'npm config get registry --location=user\nnpm config set registry https://packagefeedproxy.microsoft.io/npm/ --location=user\nnpm config get registry --location=user'
    assert_array_contains "ok:1ES npm feed registry configured for the current user." EVENTS "Registry update must report success"
    assert_array_contains "skip:1ES npm feed registry already configured." EVENTS "Repeated registry setup must skip the write"
}

test_work_registry_accepts_existing_registry_without_trailing_slash() {
    mock_work_tools
    printf '%s\n' 'https://packagefeedproxy.microsoft.io/npm' >"$REGISTRY_FILE"
    configure_work_npm_registry
    assert_work_calls "npm config get registry --location=user"
    assert_array_contains "skip:1ES npm feed registry already configured." EVENTS "Equivalent registry must skip"
}

test_work_registry_fails_when_npm_is_missing() {
    mock_work_tools
    NPM_AVAILABLE=0
    local status
    if configure_work_npm_registry; then status=0; else status=$?; fi
    assert_status 1 "$status" "Missing npm must fail"
    assert_work_calls ""
    assert_array_contains "fail:npm is required to configure the Work-only 1ES package feed." EVENTS "Missing npm must explain failure"
}

test_work_registry_read_failure_does_not_write() {
    mock_work_tools
    NPM_READ_STATUS=17
    local status
    if configure_work_npm_registry; then status=0; else status=$?; fi
    assert_status 1 "$status" "Nonzero registry read must fail"
    assert_work_calls "npm config get registry --location=user"
    assert_array_contains "fail:Could not read the npm registry configuration." EVENTS "Registry read failure must be reported"
}

test_work_registry_rejects_matching_output_from_failed_read() {
    mock_work_tools
    NPM_READ_STATUS=17
    printf '%s\n' 'https://packagefeedproxy.microsoft.io/npm/' >"$REGISTRY_FILE"
    local status
    if configure_work_npm_registry; then status=0; else status=$?; fi
    assert_status 1 "$status" "Matching output must not mask failed npm command"
    assert_eq "1" "${#EVENTS[@]}" "Failed read must not report success or skip"
    assert_array_contains "fail:Could not read the npm registry configuration." EVENTS "Registry read failure must be reported"
}

test_work_registry_write_failure_does_not_report_success() {
    mock_work_tools
    NPM_WRITE_STATUS=23
    local status
    if configure_work_npm_registry; then status=0; else status=$?; fi
    assert_status 1 "$status" "Nonzero registry write must fail"
    assert_work_calls $'npm config get registry --location=user\nnpm config set registry https://packagefeedproxy.microsoft.io/npm/ --location=user'
    assert_eq "1" "${#EVENTS[@]}" "Failed write must not report success"
    assert_array_contains "fail:Could not configure the 1ES npm feed." EVENTS "Registry write failure must be reported"
}

test_agency_skips_existing_command() {
    mock_work_tools
    AGENCY_AVAILABLE=1
    install_agency
    assert_work_calls ""
    assert_array_contains "skip:Agency already installed." EVENTS "Existing Agency must skip installation"
}

test_agency_reports_success_when_new_command_is_visible() {
    mock_work_tools
    AGENCY_INSTALL_VISIBLE=1
    install_agency
    grep -qx 'curl -sSfL https://aka.ms/InstallTool.sh' "$WORK_CALLS_FILE" || fail_test "Must download documented InstallTool"
    grep -qx 'sh -s agency' "$WORK_CALLS_FILE" || fail_test "Must request the Agency tool"
    assert_eq "2" "${#EVENTS[@]}" "Successful install must report only start and success"
    assert_array_contains "ok:Agency installed." EVENTS "New Agency command must report success"
}

test_agency_warns_to_restart_terminal_when_installed_command_is_not_on_path() {
    mock_work_tools
    local status
    if install_agency; then status=0; else status=$?; fi
    assert_status 0 "$status" "Successful installer with stale PATH must not fail"
    assert_array_contains "warn:Agency installer completed. Restart your terminal session to put agency on PATH before rerunning --work." EVENTS "Stale PATH must explain terminal restart"
    assert_eq "2" "${#EVENTS[@]}" "Missing command must report only start and terminal restart guidance"
}

test_agency_download_failure_is_not_masked_by_successful_installer() {
    mock_work_tools
    CURL_STATUS=22
    local status
    if install_agency; then status=0; else status=$?; fi
    assert_status 1 "$status" "pipefail must preserve download failure"
    assert_array_contains "fail:Agency installation failed. Check corporate access/authentication and rerun --work." EVENTS "Download failure must give actionable guidance"
    assert_eq "2" "${#EVENTS[@]}" "Failed download must not report success or terminal restart"
}

test_agency_installer_failure_does_not_report_success_or_restart() {
    mock_work_tools
    INSTALLER_STATUS=31
    local status
    if install_agency; then status=0; else status=$?; fi
    assert_status 1 "$status" "Nonzero installer must fail"
    assert_array_contains "fail:Agency installation failed. Check corporate access/authentication and rerun --work." EVENTS "Installer failure must give actionable guidance"
    assert_eq "2" "${#EVENTS[@]}" "Failed installer must not report success or terminal restart"
}

main() {
    local tests=(
        test_app_exists_detects_system_application
        test_app_exists_detects_user_application
        test_app_exists_clears_location_when_missing
        test_app_exists_resets_stale_state_between_calls
        test_ensure_cask_skips_install_when_app_bundle_exists
        test_ensure_cask_checks_brew_when_app_name_is_empty
        test_ensure_cask_checks_brew_when_bundle_is_missing
        test_ensure_cask_respects_skip_before_app_detection
        test_ensure_cask_upgrades_outdated_homebrew_owned_app
        test_ensure_formula_upgrades_outdated_package
        test_install_stages_keep_github_cli_and_editor_copilot_without_standalone_cli
        test_verification_executes_github_cli_and_editor_checks_without_standalone_copilot
        test_no_standalone_copilot_management_anywhere_in_script
        test_work_stage_skips_personal_and_runs_work_in_order
        test_work_stage_stops_before_agency_when_registry_fails
        test_work_stage_propagates_agency_failure
        test_work_registry_sets_user_registry_and_second_run_skips
        test_work_registry_accepts_existing_registry_without_trailing_slash
        test_work_registry_fails_when_npm_is_missing
        test_work_registry_read_failure_does_not_write
        test_work_registry_rejects_matching_output_from_failed_read
        test_work_registry_write_failure_does_not_report_success
        test_agency_skips_existing_command
        test_agency_reports_success_when_new_command_is_visible
        test_agency_warns_to_restart_terminal_when_installed_command_is_not_on_path
        test_agency_download_failure_is_not_masked_by_successful_installer
        test_agency_installer_failure_does_not_report_success_or_restart
    )
    local test_name

    for test_name in "${tests[@]}"; do
        CURRENT_TEST="$test_name"
        reset_test_state
        ( "$test_name" )
        printf 'ok - %s\n' "$test_name"
    done

    printf '\n%d tests passed\n' "${#tests[@]}"
}

main "$@"
