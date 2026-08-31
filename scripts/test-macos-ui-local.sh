#!/bin/bash
#
# Build and run the fork-only Standalone Mac Catalyst UI test with the same
# ad-hoc signing overlay used by rootshell-macos. This script deliberately
# keeps every local signing accommodation out of the zmx/upstream branches.
#
# Usage:
#   scripts/test-macos-ui-local.sh [--clean]
#
# Optional environment:
#   ROOTSHELL_REPO                checkout to test (default: this script's repo)
#   ROOTSHELL_MACOS_BRANCH        overlay ref (default: origin/macos-local-dev)
#   ROOTSHELL_MACOS_BASE          overlay merge-base ref (default: main)
#   ROOTSHELL_UI_TEST_DERIVED_DATA derived-data directory
#   ROOTSHELL_UI_TEST_DESTINATION xcodebuild destination
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${ROOTSHELL_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# The focused zmx tests need an SSH endpoint, but the endpoint must never
# outlive the test process. Keep the fixture wrapper outside the build/test
# implementation so an interrupted xcodebuild still reaches its cleanup
# trap. Callers that already own a fixture can opt out and provide an env
# file (the fixture coordinator exports the same variables).
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
            "$SCRIPT_DIR/test-macos-ui-local.sh" "$@" || fixture_status=$?
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

BRANCH="${ROOTSHELL_MACOS_BRANCH:-origin/macos-local-dev}"
BASE="${ROOTSHELL_MACOS_BASE:-main}"
SCHEME="rootshell-Standalone-UITests"
CONFIG="DebugStandalone"
DESTINATION="${ROOTSHELL_UI_TEST_DESTINATION:-platform=macOS,variant=Mac Catalyst,arch=arm64}"
DERIVED="${ROOTSHELL_UI_TEST_DERIVED_DATA:-$REPO/.derivedData/mac-ui-tests}"
HOST_ENTITLEMENTS="Configuration/LocalUITestHost.entitlements"
TEST_ENTITLEMENTS="Configuration/LocalUITests.entitlements"
TEST_HOST_BUNDLE_ID="com.kk2.rootshell.localuitesthost"
TEST_HELPER_BUNDLE_ID="com.kk2.rootshell.localuitesthelper"
PRODUCTS="$DERIVED/Build/Products/$CONFIG-maccatalyst"
APP="$PRODUCTS/rootshell.app"
UI_TEST_RUN_DIRECTORY=""
LSREGISTER_PATH=""
TEST_HOST_REGISTERED=0

cd "$REPO"
git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "$REPO is not a git repository" >&2
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --clean)
            echo "==> removing $DERIVED"
            rm -rf "$DERIVED"
            ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

git fetch --quiet origin macos-local-dev 2>/dev/null || true
git rev-parse --verify --quiet "$BRANCH" >/dev/null || {
    echo "cannot resolve $BRANCH -- fetch it first" >&2
    exit 1
}

OVERLAY_FILES=()
while IFS= read -r file; do
    [ -n "$file" ] && OVERLAY_FILES+=("$file")
done < <(git diff --name-only "$BASE...$BRANCH")
[ "${#OVERLAY_FILES[@]}" -gt 0 ] || {
    echo "$BRANCH adds nothing over $BASE" >&2
    exit 1
}

RESTORE_CHECKOUT=()
RESTORE_DELETE=()

# Share the launcher lock: the overlay is present while a build runs, so two
# local build/test invocations must never try to apply or remove it together.
LOCK="$(git rev-parse --git-dir)/rootshell-macos.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    holder=$(cat "$LOCK/pid" 2>/dev/null || echo "")
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        echo "a rootshell-macos build is already running (pid $holder)." >&2
        exit 1
    fi
    echo "found a stale rootshell-macos lock; recovering it" >&2
    rm -rf "$LOCK"
    mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
LOCK_HELD=1

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    if [ "$TEST_HOST_REGISTERED" -eq 1 ]; then
        echo "==> unregistering test host from LaunchServices"
        "$LSREGISTER_PATH" -u "$APP" >/dev/null 2>&1 || true
    fi
    cleanup_test_helpers
    echo "==> removing macOS overlay"
    if [ "${#RESTORE_DELETE[@]}" -gt 0 ]; then
        rm -f "${RESTORE_DELETE[@]}"
    fi
    if [ "${#RESTORE_CHECKOUT[@]}" -gt 0 ]; then
        git checkout -- "${RESTORE_CHECKOUT[@]}"
    fi
    for file in "${RESTORE_DELETE[@]}"; do
        directory=$(dirname "$file")
        [ "$directory" = "." ] || rmdir "$directory" 2>/dev/null || true
    done
    if [ "${LOCK_HELD:-0}" = "1" ]; then
        rm -rf "$LOCK"
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM HUP

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

for file in "${OVERLAY_FILES[@]}"; do
    if git ls-files --error-unmatch "$file" >/dev/null 2>&1; then
        if ! git diff --quiet -- "$file"; then
            echo "refusing: '$file' has uncommitted changes and is an overlay file" >&2
            exit 1
        fi
        RESTORE_CHECKOUT+=("$file")
    elif [ -e "$file" ]; then
        echo "refusing: '$file' already exists but is not tracked here" >&2
        echo "run rootshell-macos --cleanup after inspecting any stranded overlay" >&2
        exit 1
    else
        RESTORE_DELETE+=("$file")
    fi
done

echo "==> overlaying ${#OVERLAY_FILES[@]} file(s) from $BRANCH"
for file in "${OVERLAY_FILES[@]}"; do
    mkdir -p "$(dirname "$file")"
    git show "$BRANCH:$file" > "$file"
done

[ -f "$HOST_ENTITLEMENTS" ] || {
    echo "missing fork-only $HOST_ENTITLEMENTS" >&2
    exit 1
}
[ -f "$TEST_ENTITLEMENTS" ] || {
    echo "missing fork-only $TEST_ENTITLEMENTS" >&2
    exit 1
}

# The local-development helper normally trusts the production host identifier.
# Teach this temporary build to read the expected identifier from its own
# Info.plist; cleanup restores the overlaid source after the run.
HELPER_TRUST_SOURCE="rootshell-helper/Sources/SocketCommandServer.swift"
HELPER_TRUST_LITERAL='private static let appIdentifier = "com.kk2.rootshell"'
grep -Fq "$HELPER_TRUST_LITERAL" "$HELPER_TRUST_SOURCE" || {
    echo "cannot find the helper trust identifier in $HELPER_TRUST_SOURCE" >&2
    exit 1
}
perl -0pi -e \
    's/private static let appIdentifier = "com\.kk2\.rootshell"/private static let appIdentifier = Bundle.main.object(forInfoDictionaryKey: "RootShellTrustedAppIdentifier") as? String ?? "com.kk2.rootshell"/' \
    "$HELPER_TRUST_SOURCE"

echo "==> building for testing: $SCHEME / $CONFIG"
xcodebuild \
    -quiet \
    -project rootshell.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_DEBUG_DYLIB=NO \
    build-for-testing

[ -d "$APP" ] || {
    echo "build produced no app at $APP" >&2
    exit 1
}


# This test host must not share an identity with either an installed rootshell
# or an ordinary local build. The helper reads the same identifier at runtime
# when validating the connecting peer's audit token.
HOST_INFO="$APP/Contents/Info.plist"
HELPER_INFO="$APP/Contents/Helpers/rootshell-helper.app/Contents/Info.plist"
[ -f "$HOST_INFO" ] && [ -f "$HELPER_INFO" ] || {
    echo "built app is missing host or helper Info.plist" >&2
    exit 1
}

# The fork only needs a local helper. Remove bundled services that have no
# role in these tests before they can be launched with their production
# identities or privacy metadata.
for unused_plugin in \
    "$APP/Contents/PlugIns/PushNotificationService.appex" \
    "$APP/Contents/PlugIns/CoreWLANPlugin.bundle"
do
    [ ! -e "$unused_plugin" ] || rm -rf "$unused_plugin"
done

plutil -replace CFBundleIdentifier -string "$TEST_HOST_BUNDLE_ID" "$HOST_INFO"
plutil -replace CFBundleIdentifier -string "$TEST_HELPER_BUNDLE_ID" "$HELPER_INFO"
for production_key in RootshellAppGroup RootshellKeychainAccessGroup; do
    plutil -remove "$production_key" "$HOST_INFO" 2>/dev/null || true
done
if plutil -extract RootShellTrustedAppIdentifier raw "$HELPER_INFO" >/dev/null 2>&1; then
    plutil -replace RootShellTrustedAppIdentifier -string "$TEST_HOST_BUNDLE_ID" "$HELPER_INFO"
else
    plutil -insert RootShellTrustedAppIdentifier -string "$TEST_HOST_BUNDLE_ID" "$HELPER_INFO"
fi

sign_host_app() {
    local bundle="$1"

    find "$bundle/Contents/Frameworks" -name '*.dylib' -print0 2>/dev/null \
        | xargs -0 -r -I{} codesign --force --sign - --timestamp=none '{}'
    for framework in "$bundle"/Contents/Frameworks/*.framework; do
        [ -e "$framework" ] || continue
        codesign --force --sign - --timestamp=none --deep "$framework"
    done
    for plugin in "$bundle"/Contents/PlugIns/*; do
        [ -e "$plugin" ] || continue
        codesign --force --sign - --timestamp=none "$plugin"
    done
    for helper in "$bundle"/Contents/Helpers/*.app; do
        [ -e "$helper" ] || continue
        codesign --force --sign - --timestamp=none --entitlements "$HOST_ENTITLEMENTS" "$helper"
    done
    codesign --force --sign - --timestamp=none --entitlements "$HOST_ENTITLEMENTS" "$bundle"
}

echo "==> ad-hoc signing host and helper"
sign_host_app "$APP"
codesign --verify --deep --strict "$APP"
[ "$(plutil -extract CFBundleIdentifier raw "$HOST_INFO")" = "$TEST_HOST_BUNDLE_ID" ] || {
    echo "test host bundle identifier was not applied" >&2
    exit 1
}
[ "$(plutil -extract CFBundleIdentifier raw "$HELPER_INFO")" = "$TEST_HELPER_BUNDLE_ID" ] || {
    echo "test helper bundle identifier was not applied" >&2
    exit 1
}
for production_key in RootshellAppGroup RootshellKeychainAccessGroup; do
    if plutil -extract "$production_key" raw "$HOST_INFO" >/dev/null 2>&1; then
        echo "test host still contains production $production_key metadata" >&2
        exit 1
    fi
done

# The artifact should contain neither production executable identities nor
# production app-group metadata. Inspect every executable nested bundle, not
# just the outer app, so future embeds cannot silently reintroduce TCC prompts.
while IFS= read -r -d '' nested_info; do
    nested_identifier="$(plutil -extract CFBundleIdentifier raw "$nested_info" 2>/dev/null || true)"
    case "$nested_identifier" in
        com.kk2.*)
            echo "production bundle identifier remains in $nested_info: $nested_identifier" >&2
            exit 1
            ;;
    esac
    if plutil -p "$nested_info" | grep -Fq 'group.com.kk2'; then
        echo "production app-group metadata remains in $nested_info" >&2
        exit 1
    fi
done < <(find "$APP/Contents" -type f -path '*/Contents/Info.plist' -print0)

# The exact Mac Catalyst UI-test runner layout is generated by Xcode. On
# current Xcode it is one or both of *.xctest and *-Runner.app / *.xctrunner.
# Sign every generated candidate after the host so test-without-building never
# sees an unsigned product. -depth ensures a nested test bundle is signed
# before its runner container.
TEST_ARTIFACTS=0
while IFS= read -r -d '' artifact; do
    TEST_ARTIFACTS=1
    echo "==> ad-hoc signing test artifact: $artifact"
    codesign --force --sign - --timestamp=none --deep \
        --entitlements "$TEST_ENTITLEMENTS" "$artifact"
    codesign --verify --deep --strict "$artifact"
done < <(find "$DERIVED/Build/Products" -depth -type d \( \
    -name '*.xctest' -o -name '*.xctrunner' -o -name '*-Runner.app' \
\) -print0)

[ "$TEST_ARTIFACTS" -eq 1 ] || {
    echo "build-for-testing produced no UI test artifact; inspect $DERIVED/Build/Products" >&2
    exit 1
}

XCTESTRUN="$(find "$DERIVED/Build/Products" -name '*.xctestrun' -print -quit)"
[ -n "$XCTESTRUN" ] || {
    echo "build-for-testing produced no .xctestrun file; inspect $DERIVED/Build/Products" >&2
    exit 1
}

# Xcode 26 currently writes the UI target app path without the Catalyst product
# suffix even though every dependent-product entry uses it. Keep the correction
# next to the generated artifact rather than changing the upstream app target.
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

# One private parent per scripted invocation lets the EXIT trap clean up only
# this suite's children after an interrupted test process. It is intentionally
# supplied through XCTest metadata, not inherited from the developer shell.
UI_TEST_RUN_DIRECTORY="$(mktemp -d /private/tmp/rootshell-zmx-xcui-run.XXXXXX)"
chmod 700 "$UI_TEST_RUN_DIRECTORY"
plutil -insert \
    "rootshellStandaloneUITests.EnvironmentVariables.ROOTSHELL_UI_TEST_RUN_DIRECTORY" \
    -string "$UI_TEST_RUN_DIRECTORY" \
    "$XCTESTRUN"

# Register the disposable, signed host before resetting TCC. This makes the
# bundle visible to privacy services without ever touching the production app.
for lsregister_candidate in \
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    /System/Library/PrivateFrameworks/LaunchServices.framework/Support/lsregister
do
    if [ -x "$lsregister_candidate" ]; then
        LSREGISTER_PATH="$lsregister_candidate"
        break
    fi
done
[ -n "$LSREGISTER_PATH" ] || {
    echo "could not find the system lsregister utility" >&2
    exit 1
}
[ "$(plutil -extract CFBundleIdentifier raw "$HOST_INFO")" = "$TEST_HOST_BUNDLE_ID" ] || {
    echo "refusing to register app with unexpected bundle identifier" >&2
    exit 1
}
echo "==> registering test host with LaunchServices: $APP"
TEST_HOST_REGISTERED=1
"$LSREGISTER_PATH" -f "$APP" >/dev/null

reset_test_host_tcc_grants() {
    local macos_version macos_major

    echo "==> resetting privacy grants for test host: $TEST_HOST_BUNDLE_ID"
    /usr/bin/tccutil reset SystemPolicyDocumentsFolder "$TEST_HOST_BUNDLE_ID"

    # SystemPolicyAppData is available starting with macOS 14. On older hosts,
    # skip only this unsupported service; failures from sw_vers or tccutil on
    # supported hosts remain fatal so permission/setup errors are not hidden.
    macos_version="$(/usr/bin/sw_vers -productVersion)" || {
        echo "could not determine macOS version for SystemPolicyAppData reset" >&2
        return 1
    }
    macos_major="${macos_version%%.*}"
    case "$macos_major" in
        ''|*[!0-9]*)
            echo "invalid macOS product version: $macos_version" >&2
            return 1
            ;;
    esac
    if [ "$macos_major" -ge 14 ]; then
        /usr/bin/tccutil reset SystemPolicyAppData "$TEST_HOST_BUNDLE_ID"
    else
        echo "    SystemPolicyAppData unsupported on macOS $macos_version; skipping"
    fi
}

reset_test_host_tcc_grants
echo "==> testing without rebuilding: $XCTESTRUN"
xcodebuild \
    -quiet \
    test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED"
