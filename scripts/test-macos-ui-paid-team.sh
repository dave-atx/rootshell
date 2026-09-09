#!/bin/bash
#
# Build and run the fork-only Standalone Mac Catalyst UI test signed with this
# checkout's own paid Apple Developer team, as configured by
# Configuration/DeveloperSettings.xcconfig (scripts/setup-dev-signing.sh).
#
# This is the counterpart to scripts/test-macos-ui-local.sh, which builds
# unsigned and then ad-hoc-signs a disposable copy under a rewritten bundle
# identifier. That is the right answer for a machine with no developer account;
# it is the wrong answer for one whose policy is "never ad-hoc sign, never strip
# entitlements". Here the app keeps its real signed identity, so:
#
#   - nothing is re-signed after the build, and no entitlements are removed;
#   - no bundle identifier is rewritten, so LaunchServices is never asked to
#     register a disposable app and no tccutil grant is reset;
#   - the test resolves its host from the test configuration's target-app path
#     (ROOTSHELL_UI_TEST_USE_TARGET_APP=1) rather than by identifier, so it
#     cannot accidentally drive some other copy of the same identifier.
#
# The app's own test-mode isolation is what keeps this safe to run against a
# real signed identity: ForkUITestConfiguration redirects the app group
# container, HOME, and every Documents-backed store into the private
# /private/tmp run directory created below, and installs its settings in
# UserDefaults' volatile argument domain rather than the persistent one.
#
# Usage:
#   scripts/test-macos-ui-paid-team.sh [--clean] [--only TEST]
#
#   --only TEST   run a single test, e.g.
#                 --only testDetachThenTabExposeReturnsToLocal
#
# Optional environment:
#   ROOTSHELL_REPO                 checkout to test (default: this script's repo)
#   ROOTSHELL_UI_TEST_DERIVED_DATA derived-data directory
#   ROOTSHELL_UI_TEST_DESTINATION  xcodebuild destination
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${ROOTSHELL_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# The zmx tests need an SSH endpoint, but the endpoint must never outlive the
# test process. Keep the fixture wrapper outside the build/test implementation
# so an interrupted xcodebuild still reaches its cleanup trap.
if [ "${ROOTSHELL_UI_FIXTURE_WRAPPED:-0}" != "1" ]; then
    fixture_env="${ROOTSHELL_UI_FIXTURE_ENV:-$(mktemp "${TMPDIR:-/tmp}/rootshell-zmx-ui.XXXXXX.env")}"
    fixture_env_owned=0
    if [ -z "${ROOTSHELL_UI_FIXTURE_ENV:-}" ]; then
        fixture_env_owned=1
    fi
    cleanup_fixture_env() {
        if [ "$fixture_env_owned" -eq 1 ]; then
            rm -f "$fixture_env"
        fi
    }
    trap cleanup_fixture_env EXIT INT TERM HUP
    fixture_status=0
    "$REPO/Tests/ZmxFixture/zmx-fixture.sh" run \
        --env-file "$fixture_env" -- \
        env ROOTSHELL_UI_FIXTURE_WRAPPED=1 \
            ROOTSHELL_UI_FIXTURE_ENV="$fixture_env" \
            "$SCRIPT_DIR/test-macos-ui-paid-team.sh" "$@" || fixture_status=$?
    trap - EXIT INT TERM HUP
    cleanup_fixture_env
    exit "$fixture_status"
fi

# Import the fixture coordinator's non-secret endpoint values into the test
# process. The private key is intentionally ignored by the UI tests; it is
# retained by the coordinator only for fixture setup and teardown.
if [ -n "${ROOTSHELL_UI_FIXTURE_ENV:-}" ] && [ -f "$ROOTSHELL_UI_FIXTURE_ENV" ]; then
    set -a
    . "$ROOTSHELL_UI_FIXTURE_ENV"
    set +a
fi

: "${ZMX_FIXTURE_STATE_DIR:?fixture did not provide ZMX_FIXTURE_STATE_DIR}"
: "${ZMX_FIXTURE_HOST:?fixture did not provide ZMX_FIXTURE_HOST}"
: "${ZMX_FIXTURE_PORT:?fixture did not provide ZMX_FIXTURE_PORT}"
: "${ZMX_FIXTURE_USERNAME:?fixture did not provide ZMX_FIXTURE_USERNAME}"
: "${ZMX_FIXTURE_SESSION_PREFIX:?fixture did not provide ZMX_FIXTURE_SESSION_PREFIX}"
"$REPO/Tests/ZmxFixture/zmx-fixture.sh" seed "$ZMX_FIXTURE_STATE_DIR" expose-a detach

SCHEME="rootshell-Standalone-UITests"
CONFIG="DebugStandalone"
DESTINATION="${ROOTSHELL_UI_TEST_DESTINATION:-platform=macOS,variant=Mac Catalyst,arch=arm64}"
DERIVED="${ROOTSHELL_UI_TEST_DERIVED_DATA:-$REPO/.derivedData/mac-ui-tests-paid-team}"
PRODUCTS="$DERIVED/Build/Products/$CONFIG-maccatalyst"
APP="$PRODUCTS/rootshell.app"
UI_TEST_RUN_DIRECTORY=""
ONLY_TEST=""

cd "$REPO"
git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "$REPO is not a git repository" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --clean)
            echo "==> removing $DERIVED"
            rm -rf "$DERIVED"
            shift
            ;;
        --only)
            ONLY_TEST="${2:?--only requires a test name}"
            shift 2
            ;;
        --only=*)
            ONLY_TEST="${1#*=}"
            shift
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# This script exists precisely because this checkout signs under its own team.
# Refuse rather than silently falling back to upstream's identity, which the
# developer here cannot sign for anyway.
SETTINGS="Configuration/DeveloperSettings.xcconfig"
[ -f "$SETTINGS" ] || {
    echo "missing $SETTINGS -- run scripts/setup-dev-signing.sh first," >&2
    echo "or use scripts/test-macos-ui-local.sh for an unsigned ad-hoc run" >&2
    exit 1
}

# Only helper PIDs that wrote a marker below this invocation's private run
# directory are eligible for cleanup. Before signaling, re-check their live
# command line includes that exact test socket directory. This is deliberately
# narrower than matching helpers by name or bundle identifier.
cleanup_test_helpers() {
    [ -n "$UI_TEST_RUN_DIRECTORY" ] && [ -d "$UI_TEST_RUN_DIRECTORY" ] || return
    local marker test_directory pid command deadline
    while IFS= read -r -d '' marker; do
        test_directory="$(dirname "$marker")"
        pid="$(tr -d '[:space:]' < "$marker" 2>/dev/null || true)"
        case "$pid" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$pid" -gt 1 ] || continue
        command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
        case "$command" in
            *"rootshell-helper --socket-directory $test_directory"*) ;;
            *) continue ;;
        esac
        kill -TERM "$pid" 2>/dev/null || true
        deadline=$((SECONDS + 2))
        while [ "$SECONDS" -lt "$deadline" ]; do
            command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
            case "$command" in
                *"rootshell-helper --socket-directory $test_directory"*) sleep 0.05 ;;
                *) break ;;
            esac
        done
        command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
        case "$command" in
            *"rootshell-helper --socket-directory $test_directory"*) kill -KILL "$pid" 2>/dev/null || true ;;
        esac
    done < <(find "$UI_TEST_RUN_DIRECTORY" -type f -name rootshell-helper.pid -print0 2>/dev/null)
    rm -rf "$UI_TEST_RUN_DIRECTORY"
}

# bash 3.2 (what /bin/bash is on macOS) runs the EXIT trap with $? == 0 after
# a fatal `set -u` unbound-variable error, so a trap that simply re-exits $?
# reports a hard failure as success. Require the script to have reached its own
# last line before a zero status is believed.
COMPLETED=0
cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    cleanup_test_helpers
    if [ "$status" -eq 0 ] && [ "$COMPLETED" -ne 1 ]; then
        echo "exited before completing; treating the reported success as a failure" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM HUP

echo "==> building for testing: $SCHEME / $CONFIG (signed, team $(sed -n 's/^ROOTSHELL_DEVELOPMENT_TEAM *= *//p' "$SETTINGS"))"
xcodebuild \
    -quiet \
    -project rootshell.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    ENABLE_DEBUG_DYLIB=NO \
    build-for-testing

[ -d "$APP" ] || {
    echo "build produced no app at $APP" >&2
    exit 1
}

# The point of this script: prove nothing ad-hoc slipped through. An ad-hoc
# signature has no team identifier, so a real team OU here is the check.
APP_TEAM="$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
EXPECTED_TEAM="$(sed -n 's/^ROOTSHELL_DEVELOPMENT_TEAM *= *//p' "$SETTINGS" | tr -d '[:space:]')"
[ -n "$EXPECTED_TEAM" ] || {
    echo "could not read ROOTSHELL_DEVELOPMENT_TEAM from $SETTINGS" >&2
    exit 1
}
[ "$APP_TEAM" = "$EXPECTED_TEAM" ] || {
    echo "built app is signed by '$APP_TEAM', expected '$EXPECTED_TEAM'" >&2
    exit 1
}
codesign --verify --deep --strict "$APP"
echo "==> app is signed by team $APP_TEAM: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

XCTESTRUN="$(find "$DERIVED/Build/Products" -name '*.xctestrun' -print -quit)"
[ -n "$XCTESTRUN" ] || {
    echo "build-for-testing produced no .xctestrun file; inspect $DERIVED/Build/Products" >&2
    exit 1
}

# Xcode 26 currently writes the UI target app path without the Catalyst product
# suffix even though every dependent-product entry uses it. Keep the correction
# next to the generated artifact rather than changing the upstream app target.
# This matters more here than in the ad-hoc runner: the test resolves its host
# through this path rather than by bundle identifier.
XCTESTRUN_TARGET_KEY="rootshellStandaloneUITests.UITargetAppPath"
plutil -replace "$XCTESTRUN_TARGET_KEY" \
    -string "__TESTROOT__/$CONFIG-maccatalyst/rootshell.app" \
    "$XCTESTRUN"

# xcodebuild does not forward arbitrary parent-process variables into the
# XCTest runner. Put only the non-secret UI endpoint contract into the
# generated test metadata; the coordinator's private key stays outside it.
for fixture_variable in \
    ZMX_FIXTURE_HOST \
    ZMX_FIXTURE_PORT \
    ZMX_FIXTURE_USERNAME \
    ZMX_FIXTURE_SESSION_PREFIX
do
    fixture_value="${!fixture_variable}"
    plutil -insert \
        "rootshellStandaloneUITests.EnvironmentVariables.$fixture_variable" \
        -string "$fixture_value" \
        "$XCTESTRUN"
done

# Resolve the host from UITargetAppPath above instead of by bundle identifier.
plutil -insert \
    "rootshellStandaloneUITests.EnvironmentVariables.ROOTSHELL_UI_TEST_USE_TARGET_APP" \
    -string "1" \
    "$XCTESTRUN"

# One private parent per scripted invocation lets the EXIT trap clean up only
# this suite's children after an interrupted test process. It is intentionally
# supplied through XCTest metadata, not inherited from the developer shell.
UI_TEST_RUN_DIRECTORY="$(mktemp -d /private/tmp/rootshell-zmx-xcui-run.XXXXXX)"
chmod 700 "$UI_TEST_RUN_DIRECTORY"
plutil -insert \
    "rootshellStandaloneUITests.EnvironmentVariables.ROOTSHELL_UI_TEST_RUN_DIRECTORY" \
    -string "$UI_TEST_RUN_DIRECTORY" \
    "$XCTESTRUN"

# /bin/bash on macOS is 3.2, where "${array[@]}" on an empty array is an
# unbound-variable error under `set -u`. Expand it through the +alternate form
# so no-filter stays the normal case.
ONLY_ARGS=()
if [ -n "$ONLY_TEST" ]; then
    ONLY_ARGS=(-only-testing:"rootshellStandaloneUITests/rootshellStandaloneUITests/$ONLY_TEST")
fi

echo "==> testing without rebuilding: $XCTESTRUN"

# caffeinate keeps idle sleep, display sleep and the screensaver from firing
# on their own for the life of the test run, which is the ordinary way an
# unattended Mac goes dark mid-suite. It does NOT prevent the failure actually
# observed on 2026-09-09: a Screen Sharing session ending calls
# SACLockScreenImmediate directly and locks the screen regardless of any
# caffeinate assertion. That case is only caught by the unified-log check
# below, which is why both exist.
TEST_START="$(date '+%Y-%m-%d %H:%M:%S')"
status=0
caffeinate -dimsu xcodebuild \
    -quiet \
    test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    ${ONLY_ARGS[@]+"${ONLY_ARGS[@]}"} || status=$?

# A locked session during the run voids the results regardless of what
# xcodebuild reported: every UI test after the lock fails on "Failed to
# activate application ... (current state: Running Background)" for reasons
# that say nothing about the code under test. Check the unified log for the
# lock itself rather than trusting xcodebuild's exit status alone -- this is
# what turned four false failures into hours of misdiagnosis on 2026-09-09.
# Run this after xcodebuild regardless of its outcome (both success and
# failure can be a void run), and never let a log-show hiccup here escalate
# into a hard failure of its own -- "could not determine" means "not detected".
# The predicate must be narrow enough to match only loginwindow actually
# raising the shield window. A first attempt matching any process whose
# message merely contained "shieldWindowRaised" cried wolf on the very next
# run: `distnoted` logs a line for every process that *registers* for the
# com.apple.shieldWindowRaised notification, and `log` itself logs its own
# argv -- so the predicate matched the command that was searching for it.
# Scoping to process == "loginwindow" and to the three messages a real lock
# emits (verified against the 2026-09-09 08:06 lock, and confirmed silent
# over a clean run) excludes both.
LOCK_LOG=""
if ! LOCK_LOG="$(/usr/bin/log show --start "$TEST_START" --style compact \
    --predicate 'process == "loginwindow" AND (eventMessage CONTAINS "SACLockScreenImmediate" OR eventMessage CONTAINS "raiseShieldWindowWithFade" OR eventMessage CONTAINS "setCGScreenLocked")' 2>/dev/null)"; then
    LOCK_LOG=""
    echo "note: could not query the unified log for a screen lock during the run (log show failed or is unavailable); treating as not detected" >&2
fi
# `log show` always prints a "Timestamp Ty Process[PID:TID]" header even when
# nothing matched, so a non-empty result is not a hit. Keep only real event
# lines, which begin with an ISO date. Prefer the SACLockScreenImmediate line
# when there is one: it is the only one naming the process that asked for the
# lock, which is what makes the Screen Sharing case self-diagnosing below.
LOCK_LINES="$(printf '%s\n' "$LOCK_LOG" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' || true)"
LOCK_LINE="$(printf '%s\n' "$LOCK_LINES" | grep -m1 'SACLockScreenImmediate' || true)"
if [ -z "$LOCK_LINE" ]; then
    LOCK_LINE="$(printf '%s\n' "$LOCK_LINES" | grep -m1 . || true)"
fi

if [ -n "$LOCK_LINE" ]; then
    {
        echo ""
        echo "############################################################"
        echo "# VOID RUN -- macOS session locked during this test run.  #"
        echo "# Results above (pass or fail) must NOT be interpreted.   #"
        echo "############################################################"
        echo "locked at: $LOCK_LINE"
        case "$LOCK_LINE" in
            *ScreensharingAgent*)
                echo "likely cause: a Screen Sharing session to this Mac ended, which locks"
                echo "the screen immediately. This suite drives real UI and must be run at"
                echo "the physical keyboard of an unlocked session, not over Screen Sharing."
                ;;
        esac
        echo "see docs/zmx-expose-perf/PROGRESS.md \"run hazards\" before treating any"
        echo "result from this run as a statement about the code under test."
    } >&2
    # A voided run is not a pass, even if xcodebuild itself returned 0. If
    # xcodebuild already failed, its own status is kept as-is.
    if [ "$status" -eq 0 ]; then
        status=1
    fi
fi

[ "$status" -eq 0 ] || exit "$status"

COMPLETED=1
