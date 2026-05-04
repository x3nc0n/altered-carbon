#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/altered-carbon-mac.sh"
TEST_SANDBOX_ROOT="$TESTS_DIR/.sandbox/altered-carbon-mac-tests.$$"
APP_SYSTEM_DIR="$TEST_SANDBOX_ROOT/system-applications"
APP_USER_DIR="$TEST_SANDBOX_ROOT/home/Applications"

SKIP_PACKAGES=()
APP_EXISTS_LOCATION=""
BREW_LIST_CASK_STATUS=1
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

    if [[ "$1" == "list" && "${2:-}" == "--cask" ]]; then
        return "$BREW_LIST_CASK_STATUS"
    fi

    if [[ "$1" == "install" && "${2:-}" == "--cask" ]]; then
        return "$BREW_INSTALL_STATUS"
    fi

    printf 'Unexpected brew invocation in %s: %s\n' "$CURRENT_TEST" "$*" >&2
    return 99
}

load_mac_helpers() {
    local helper_source

    helper_source="$(python3 - "$SOURCE_SCRIPT" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
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

    assert_array_empty BREW_CALLS "ensure_cask should not invoke brew when app_exists finds the bundle"
    assert_array_contains "skip:Firefox already installed (found in /Applications)." EVENTS "ensure_cask should report the app bundle location when skipping"
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
    assert_eq "1" "${#BREW_CALLS[@]}" "ensure_cask should fall through to brew list when app_name is empty"
    assert_eq "list --cask firefox" "${BREW_CALLS[0]}" "ensure_cask should check brew list when app_name is empty"
}

test_ensure_cask_checks_brew_when_bundle_is_missing() {
    BREW_LIST_CASK_STATUS=0

    ensure_cask "google-chrome" "Google Chrome" "Google Chrome"

    assert_eq "1" "${#BREW_CALLS[@]}" "ensure_cask should fall through to brew list when the app bundle is missing"
    assert_eq "list --cask google-chrome" "${BREW_CALLS[0]}" "ensure_cask should query brew list after app_exists misses"
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
    )
    local test_name

    for test_name in "${tests[@]}"; do
        CURRENT_TEST="$test_name"
        reset_test_state
        "$test_name"
        printf 'ok - %s\n' "$test_name"
    done

    printf '\n%d tests passed\n' "${#tests[@]}"
}

main "$@"
