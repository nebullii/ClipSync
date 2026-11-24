#!/bin/bash
# ClipSync build driver.
#
# Usage: scripts/build.sh <command>
#   bootstrap       check Xcode, install XcodeGen, generate the project
#   core-test       swift test in Packages/ClipCore
#   mac             build ClipSyncMac (Debug) into build/DerivedData
#   ios             build ClipSyncIOS (Debug) for the iOS Simulator (unsigned)
#   all             core-test + mac + ios
#   run-mac         build (if needed) and launch the Mac app with the test hooks
#                   CLIPSYNC_UITEST=1 CLIPSYNC_STATUS_FILE=1 CLIPSYNC_SHOW_PANEL=1
#   stop-mac        quit the Mac app started from build/
#   ios-sim-run     build, install and launch the iOS app on an available iPhone simulator
#   screenshot-sim  save a screenshot of the booted simulator to build/screenshots/
#
# Every command writes build/logs/<command>.log (full output) and
# build/logs/<command>.summary (exit code + error lines).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
LOG_DIR="$BUILD_DIR/logs"
DERIVED="$BUILD_DIR/DerivedData"
PROJECT="$ROOT/ClipSync.xcodeproj"
MAC_APP="$DERIVED/Build/Products/Debug/ClipSync.app"
IOS_APP="$DERIVED/Build/Products/Debug-iphonesimulator/ClipSync.app"
IOS_BUNDLE_ID="com.thingbits.clipsync.ios"

mkdir -p "$LOG_DIR"

usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

# write_summary <name> <exit code> <log file>
write_summary() {
    local name="$1"
    local code="$2"
    local log="$3"
    local summary="$LOG_DIR/$name.summary"
    {
        echo "command: $name"
        echo "exit_code: $code"
        echo "finished: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "log: $log"
        echo "--- errors ---"
        if [ -f "$log" ]; then
            grep -E "error:|\*\* BUILD FAILED \*\*|\*\* TEST FAILED \*\*|: failed - |Test Case .* failed|fatal error|command not found" "$log" | head -n 200
        fi
    } > "$summary"
    echo "==> $name finished with exit code $code (summary: $summary)"
}

ensure_project() {
    if command -v xcodegen >/dev/null 2>&1; then
        # Always regenerate: new source files only appear in the project after generation.
        xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" || return 1
    elif [ ! -d "$PROJECT" ]; then
        echo "error: ClipSync.xcodeproj is missing and xcodegen is not installed; run scripts/build.sh bootstrap" >&2
        return 1
    fi
    return 0
}

do_bootstrap() {
    "$ROOT/scripts/bootstrap.sh"
}

do_core_test() {
    cd "$ROOT/Packages/ClipCore" || return 1
    swift test
}

do_mac() {
    ensure_project || return 1
    xcodebuild \
        -project "$PROJECT" \
        -scheme ClipSyncMac \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "$DERIVED" \
        -skipPackagePluginValidation \
        -skipMacroValidation \
        build
}

do_ios() {
    ensure_project || return 1
    xcodebuild \
        -project "$PROJECT" \
        -scheme ClipSyncIOS \
        -configuration Debug \
        -destination "generic/platform=iOS Simulator" \
        -derivedDataPath "$DERIVED" \
        -skipPackagePluginValidation \
        -skipMacroValidation \
        CODE_SIGNING_ALLOWED=NO \
        build
}

do_all() {
    local result=0
    run_logged core-test do_core_test || result=1
    run_logged mac do_mac || result=1
    run_logged ios do_ios || result=1
    return $result
}

MAC_BINARY="$MAC_APP/Contents/MacOS/ClipSync"

# Launches the binary inside the .app directly (not via `open`, which would drop the
# environment) with the Mac services engineer's test hooks (macOS/App/LaunchOptions.swift):
#   CLIPSYNC_UITEST=1       in-memory store + isolated, wiped settings; no onboarding
#   CLIPSYNC_STATUS_FILE=1  ~/Library/Application Support/ClipSync/status.json after each capture
#   CLIPSYNC_SHOW_PANEL=1   shows the panel ~1 s after launch
# The app's own stdout/stderr are appended to build/logs/run-mac.log.
do_run_mac() {
    # Always (incrementally) rebuild so the E2E test never runs a stale binary.
    do_mac || return 1
    if [ ! -x "$MAC_BINARY" ]; then
        echo "error: $MAC_BINARY not found after building" >&2
        return 1
    fi
    do_stop_mac
    # E2E hooks (macOS/App/E2E/E2EDriver.swift): status files, command channel and
    # window snapshots in build/e2e, driven by scripts/e2e-mac.sh below.
    local e2e_dir="$BUILD_DIR/e2e"
    rm -rf "$e2e_dir"
    mkdir -p "$e2e_dir"
    echo "==> launching $MAC_BINARY (CLIPSYNC_UITEST=1 CLIPSYNC_STATUS_FILE=1 CLIPSYNC_SHOW_PANEL=1 CLIPSYNC_E2E_DIR=$e2e_dir)"
    CLIPSYNC_UITEST=1 CLIPSYNC_STATUS_FILE=1 CLIPSYNC_SHOW_PANEL=1 CLIPSYNC_E2E_DIR="$e2e_dir" \
        nohup "$MAC_BINARY" >> "$LOG_DIR/run-mac.log" 2>&1 < /dev/null &
    local pid=$!
    sleep 2
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "error: ClipSync exited right after launch (see $LOG_DIR/run-mac.log)" >&2
        return 1
    fi
    echo "==> ClipSync running (pid $pid)"
    if [ "${CLIPSYNC_SKIP_E2E:-0}" = "1" ]; then
        echo "==> CLIPSYNC_SKIP_E2E=1: skipping the Mac E2E test"
        return 0
    fi
    # End-to-end test; results in build/e2e/results.json + report.md. The app is left
    # running afterwards (stop-mac quits it). run-mac's exit code reports the launch
    # (and whether the app survived the test), not the test verdict.
    echo "==> running scripts/e2e-mac.sh (results: $e2e_dir/results.json)"
    CLIPSYNC_E2E_DIR="$e2e_dir" /bin/bash "$ROOT/scripts/e2e-mac.sh" "$pid"
    local e2e_code=$?
    echo "==> e2e-mac.sh finished with exit code $e2e_code ($(grep -E '"(passed|failed|skipped)"' "$e2e_dir/results.json" 2>/dev/null | tr -d ' \n'))"
    if kill -0 "$pid" 2>/dev/null; then
        echo "==> ClipSync still running (pid $pid)"
        return 0
    fi
    echo "error: ClipSync is no longer running after the E2E test (crash? see $LOG_DIR/run-mac.log)" >&2
    return 1
}

do_stop_mac() {
    if pgrep -f "$MAC_BINARY" >/dev/null 2>&1; then
        echo "==> stopping $MAC_APP"
        pkill -TERM -f "$MAC_BINARY"
        local waited=0
        while pgrep -f "$MAC_BINARY" >/dev/null 2>&1 && [ "$waited" -lt 10 ]; do
            sleep 0.5
            waited=$((waited + 1))
        done
        if pgrep -f "$MAC_BINARY" >/dev/null 2>&1; then
            echo "==> ClipSync did not quit after SIGTERM; sending SIGKILL"
            pkill -KILL -f "$MAC_BINARY"
            sleep 0.5
        fi
    else
        echo "==> ClipSync (from build/) is not running"
    fi
    return 0
}

# Prints the UDID of a booted simulator, else of the first available iPhone.
pick_simulator() {
    local udid
    udid="$(xcrun simctl list devices booted 2>/dev/null | grep -E "iPhone|iPad" | head -n 1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
    if [ -z "$udid" ]; then
        udid="$(xcrun simctl list devices available 2>/dev/null | grep -E "iPhone" | head -n 1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
    fi
    echo "$udid"
}

do_ios_sim_run() {
    do_ios || return 1
    local udid
    udid="$(pick_simulator)"
    if [ -z "$udid" ]; then
        echo "error: no available iPhone simulator found (install one in Xcode > Settings > Platforms)" >&2
        return 1
    fi
    echo "==> using simulator $udid"
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    open -a Simulator >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b || return 1
    xcrun simctl install "$udid" "$IOS_APP" || return 1
    xcrun simctl launch "$udid" "$IOS_BUNDLE_ID" -uitest-seed || return 1
    # End-to-end UI tests (build/e2e-ios/, build/logs/ios-ui-tests.*). The script relaunches
    # the app with -uitest-seed when done; its exit code is the xcodebuild test exit code.
    # CLIPSYNC_SKIP_E2E=1 skips them.
    if [ "${CLIPSYNC_SKIP_E2E:-0}" = "1" ]; then
        echo "==> CLIPSYNC_SKIP_E2E=1: skipping iOS UI tests"
        return 0
    fi
    sleep 2
    /bin/bash "$ROOT/scripts/e2e-ios.sh" "$udid"
}

do_screenshot_sim() {
    local dir="$BUILD_DIR/screenshots"
    mkdir -p "$dir"
    local file="$dir/sim-$(date '+%Y%m%d-%H%M%S').png"
    xcrun simctl io booted screenshot "$file" || return 1
    echo "==> screenshot saved: $file"
    cp "$file" "$dir/latest.png"
}

# run_logged <name> <function>: runs the function with output to build/logs/<name>.log
run_logged() {
    local name="$1"
    local fn="$2"
    local log="$LOG_DIR/$name.log"
    echo "==> $name (log: $log)"
    {
        echo "command: $name"
        echo "started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "root: $ROOT"
        echo
    } > "$log"
    ( "$fn" ) >> "$log" 2>&1
    local code=$?
    write_summary "$name" "$code" "$log"
    return $code
}

if [ $# -lt 1 ]; then
    usage
    exit 64
fi

COMMAND="$1"
case "$COMMAND" in
    bootstrap)      run_logged bootstrap do_bootstrap ;;
    core-test)      run_logged core-test do_core_test ;;
    mac)            run_logged mac do_mac ;;
    ios)            run_logged ios do_ios ;;
    all)
        do_all
        CODE=$?
        {
            echo "command: all"
            echo "exit_code: $CODE"
            echo "finished: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "--- parts ---"
            for part in core-test mac ios; do
                if [ -f "$LOG_DIR/$part.summary" ]; then
                    echo "$part: $(grep '^exit_code:' "$LOG_DIR/$part.summary")"
                fi
            done
            echo "--- errors ---"
            for part in core-test mac ios; do
                if [ -f "$LOG_DIR/$part.summary" ]; then
                    sed -n '/^--- errors ---$/,$p' "$LOG_DIR/$part.summary" | sed '1d' | sed "s/^/[$part] /"
                fi
            done
        } > "$LOG_DIR/all.summary"
        cat "$LOG_DIR/core-test.log" "$LOG_DIR/mac.log" "$LOG_DIR/ios.log" > "$LOG_DIR/all.log" 2>/dev/null
        echo "==> all finished with exit code $CODE (summary: $LOG_DIR/all.summary)"
        exit $CODE
        ;;
    run-mac)        run_logged run-mac do_run_mac ;;
    stop-mac)       run_logged stop-mac do_stop_mac ;;
    ios-sim-run)    run_logged ios-sim-run do_ios_sim_run ;;
    screenshot-sim) run_logged screenshot-sim do_screenshot_sim ;;
    -h|--help|help) usage; exit 0 ;;
    *)
        echo "error: unknown command '$COMMAND'" >&2
        usage
        exit 64
        ;;
esac
exit $?
