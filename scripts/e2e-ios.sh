#!/bin/bash
# ClipSync iOS end-to-end UI tests on the Simulator.
#
# Usage: scripts/e2e-ios.sh [simulator-udid]
#   Normally called by `scripts/build.sh ios-sim-run` after the app was built, installed
#   and launched. Without a UDID it uses the booted iPhone/iPad simulator, else the first
#   available iPhone (same rule as build.sh).
#
# Output (build/e2e-ios is wiped first):
#   build/e2e-ios/ios-ui-tests.mp4   screen recording of the whole run
#   build/e2e-ios/shots/*.png        screenshots taken by the tests
#   build/e2e-ios/result.xcresult    xcodebuild result bundle (attachments, metrics)
#   build/e2e-ios/results.json       per-test status + duration, totals, simulator, times
#   build/e2e-ios/report.md          readable report incl. failing tests and messages
#   build/logs/ios-ui-tests.log      full xcodebuild output
#   build/logs/ios-ui-tests.summary  exit code + failing tests + error lines
# Exit code: the exit code of `xcodebuild test`.
# Bash 3.2 compatible (macOS /bin/bash).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
LOG_DIR="$BUILD_DIR/logs"
E2E_DIR="$BUILD_DIR/e2e-ios"
SHOTS_DIR="$E2E_DIR/shots"
DERIVED="$BUILD_DIR/DerivedData"
PROJECT="$ROOT/ClipSync.xcodeproj"
LOG="$LOG_DIR/ios-ui-tests.log"
SUMMARY="$LOG_DIR/ios-ui-tests.summary"
VIDEO="$E2E_DIR/ios-ui-tests.mp4"
RESULT_BUNDLE="$E2E_DIR/result.xcresult"
RESULTS_JSON="$E2E_DIR/results.json"
REPORT_MD="$E2E_DIR/report.md"
IOS_BUNDLE_ID="com.thingbits.clipsync.ios"
SCHEME="ClipSyncIOS"
TEST_TARGET="ClipSyncIOSUITests"

mkdir -p "$LOG_DIR"
rm -rf "$E2E_DIR"
mkdir -p "$E2E_DIR" "$SHOTS_DIR"

now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

pick_simulator() {
    local udid
    udid="$(xcrun simctl list devices booted 2>/dev/null | grep -E "iPhone|iPad" | head -n 1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
    if [ -z "$udid" ]; then
        udid="$(xcrun simctl list devices available 2>/dev/null | grep -E "iPhone" | head -n 1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
    fi
    echo "$udid"
}

# json_escape <text>: prints the text as the inside of a JSON string.
json_escape() {
    printf '%s' "$1" | awk 'BEGIN { ORS = "" } {
        gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "");
        if (NR > 1) { printf "\\n" }
        printf "%s", $0
    }'
}

UDID="${1:-}"
if [ -z "$UDID" ]; then
    UDID="$(pick_simulator)"
fi
if [ -z "$UDID" ]; then
    echo "error: no iPhone simulator found for the UI tests" >&2
    exit 1
fi

# Simulator name + runtime from `simctl list devices`: "-- iOS 26.3 --" headers, then
# "    iPhone 17 Pro (UDID) (Booted)".
SIM_INFO="$(xcrun simctl list devices 2>/dev/null | awk -v id="$UDID" '
    /^-- / { runtime = $0; sub(/^-- /, "", runtime); sub(/ --$/, "", runtime); next }
    index($0, id) > 0 {
        name = $0
        sub(/^[ \t]+/, "", name)
        sub(/ \([0-9A-Fa-f-]+\).*$/, "", name)
        print name "|" runtime
        exit
    }')"
SIM_NAME="${SIM_INFO%%|*}"
SIM_RUNTIME="${SIM_INFO#*|}"
[ -z "$SIM_INFO" ] && SIM_NAME="unknown" && SIM_RUNTIME="unknown"

STARTED="$(now)"
START_EPOCH="$(date +%s)"
echo "==> iOS UI tests on $SIM_NAME ($SIM_RUNTIME) [$UDID]"
echo "==> log: $LOG"

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" || {
        echo "error: xcodegen generate failed" >&2
        exit 1
    }
fi

# Screen recording. Background jobs of a non-interactive bash ignore SIGINT, which is how
# recordVideo is told to finish the file, so reset SIGINT to default before exec'ing it.
REC_PID=""
if command -v perl >/dev/null 2>&1; then
    perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!"' \
        xcrun simctl io "$UDID" recordVideo --codec h264 --force "$VIDEO" > "$E2E_DIR/recordVideo.log" 2>&1 &
else
    xcrun simctl io "$UDID" recordVideo --codec h264 --force "$VIDEO" > "$E2E_DIR/recordVideo.log" 2>&1 &
fi
REC_PID=$!
sleep 2
if ! kill -0 "$REC_PID" 2>/dev/null; then
    echo "==> warning: screen recording did not start (see $E2E_DIR/recordVideo.log)"
    REC_PID=""
fi

stop_recording() {
    if [ -n "$REC_PID" ] && kill -0 "$REC_PID" 2>/dev/null; then
        kill -INT "$REC_PID" 2>/dev/null
        local waited=0
        while kill -0 "$REC_PID" 2>/dev/null && [ "$waited" -lt 30 ]; do
            sleep 0.5
            waited=$((waited + 1))
        done
        if kill -0 "$REC_PID" 2>/dev/null; then
            echo "==> warning: recordVideo ignored SIGINT for 15 s; sending SIGTERM (video may be unplayable)"
            kill -TERM "$REC_PID" 2>/dev/null
            sleep 1
        fi
        wait "$REC_PID" 2>/dev/null
    fi
    REC_PID=""
}
trap 'stop_recording' EXIT

{
    echo "command: ios-ui-tests"
    echo "started: $STARTED"
    echo "simulator: $SIM_NAME ($SIM_RUNTIME) $UDID"
    echo
} > "$LOG"

# TEST_RUNNER_<NAME> in xcodebuild's environment reaches the test runner as <NAME>.
TEST_RUNNER_CLIPSYNC_E2E_SHOTS="$SHOTS_DIR" xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -only-testing:"$TEST_TARGET" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 240 \
    -maximum-test-execution-time-allowance 420 \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO \
    >> "$LOG" 2>&1
TEST_CODE=$?

stop_recording
trap - EXIT

FINISHED="$(now)"
ELAPSED=$(( $(date +%s) - START_EPOCH ))

# ---- Parse the xcodebuild log ----------------------------------------------------------
# Classic:  Test Case '-[ClipSyncIOSUITests.ClipSyncIOSUITests test01_X]' passed (12.345 seconds).
# Newer:    Test case 'ClipSyncIOSUITests.test01_X()' passed on 'iPhone 17' (12.345 seconds)
# Errors:   /path/File.swift:42: error: -[ClipSyncIOSUITests.ClipSyncIOSUITests test02_X] : XCTAssertTrue failed - msg
# Output TSV: name <TAB> status <TAB> seconds <TAB> messages (" || "-joined); "-" = empty
# (tabs are IFS whitespace, so empty fields would collapse when read back).
TSV="$E2E_DIR/.tests.tsv"
awk -v q="'" '
function testname(s,    n) {
    n = s
    sub(/\(\)$/, "", n)
    sub(/\]$/, "", n)
    if (index(n, " ") > 0) { sub(/^.* /, "", n) }
    if (index(n, ".") > 0) { sub(/^.*\./, "", n) }
    return n
}
/Test [Cc]ase .* (passed|failed|skipped)/ {
    line = $0
    q1 = index(line, q)
    if (q1 == 0) next
    rest = substr(line, q1 + 1)
    q2 = index(rest, q)
    if (q2 == 0) next
    name = testname(substr(rest, 1, q2 - 1))
    after = substr(rest, q2 + 1)
    status = ""
    if (after ~ /^ passed/) status = "passed"
    else if (after ~ /^ failed/) status = "failed"
    else if (after ~ /^ skipped/) status = "skipped"
    if (status == "") next
    secs = ""
    if (match(after, /\(([0-9.]+) seconds\)/)) {
        secs = substr(after, RSTART + 1, RLENGTH - 1)
        sub(/ seconds\)$/, "", secs)
    }
    if (!(name in seen)) { seen[name] = 1; order[++count] = name }
    st[name] = status
    du[name] = secs
    next
}
/error: -\[/ || /: error: .*test[0-9]/ {
    line = $0
    if (match(line, /test[0-9][0-9]_[A-Za-z0-9_]+/)) {
        name = substr(line, RSTART, RLENGTH)
        msg = line
        if (index(msg, "] : ") > 0) { msg = substr(msg, index(msg, "] : ") + 4) }
        else { sub(/^.*error: /, "", msg) }
        gsub(/\t/, " ", msg)
        if (!(name in seen)) { seen[name] = 1; order[++count] = name; st[name] = "failed"; du[name] = "" }
        if (name in msgs) {
            if (index(msgs[name], msg) == 0) msgs[name] = msgs[name] " || " msg
        } else {
            msgs[name] = msg
        }
    }
}
END {
    for (i = 1; i <= count; i++) {
        n = order[i]
        s = du[n]; if (s == "") s = "-"
        m = msgs[n]; if (m == "") m = "-"
        printf "%s\t%s\t%s\t%s\n", n, st[n], s, m
    }
}' "$LOG" > "$TSV"

TOTAL=0; PASSED=0; FAILED=0; SKIPPED=0
while IFS="$(printf '\t')" read -r name status secs msg; do
    [ -z "$name" ] && continue
    TOTAL=$((TOTAL + 1))
    case "$status" in
        passed) PASSED=$((PASSED + 1)) ;;
        failed) FAILED=$((FAILED + 1)) ;;
        skipped) SKIPPED=$((SKIPPED + 1)) ;;
    esac
done < "$TSV"

# Error lines not tied to a test (build errors, launch failures, runner crashes).
OTHER_ERRORS="$E2E_DIR/.other-errors.txt"
grep -E "error:|\*\* TEST FAILED \*\*|\*\* BUILD FAILED \*\*|\*\* TEST EXECUTE FAILED \*\*|Testing failed:|Restarting after unexpected exit|crashed|Early unexpected exit|timed out" "$LOG" \
    | grep -vE "test[0-9][0-9]_" | head -n 60 > "$OTHER_ERRORS"

VIDEO_BYTES=0
[ -f "$VIDEO" ] && VIDEO_BYTES="$(wc -c < "$VIDEO" | tr -d ' ')"
SHOT_COUNT="$(ls "$SHOTS_DIR" 2>/dev/null | grep -c '\.png$')"

# Optional richer summary from the result bundle (Xcode 16+); never fatal.
if [ -d "$RESULT_BUNDLE" ]; then
    xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" > "$E2E_DIR/xcresult-summary.json" 2>/dev/null \
        || rm -f "$E2E_DIR/xcresult-summary.json"
fi

# ---- results.json ----------------------------------------------------------------------
{
    echo "{"
    echo "  \"suite\": \"$TEST_TARGET\","
    echo "  \"exit_code\": $TEST_CODE,"
    echo "  \"started\": \"$STARTED\","
    echo "  \"finished\": \"$FINISHED\","
    echo "  \"elapsed_seconds\": $ELAPSED,"
    echo "  \"simulator\": {\"name\": \"$(json_escape "$SIM_NAME")\", \"runtime\": \"$(json_escape "$SIM_RUNTIME")\", \"udid\": \"$UDID\"},"
    echo "  \"totals\": {\"total\": $TOTAL, \"passed\": $PASSED, \"failed\": $FAILED, \"skipped\": $SKIPPED},"
    echo "  \"artifacts\": {\"log\": \"build/logs/ios-ui-tests.log\", \"video\": \"build/e2e-ios/ios-ui-tests.mp4\", \"video_bytes\": $VIDEO_BYTES, \"shots_dir\": \"build/e2e-ios/shots\", \"shot_count\": $SHOT_COUNT, \"xcresult\": \"build/e2e-ios/result.xcresult\"},"
    echo "  \"tests\": ["
    first=1
    while IFS="$(printf '\t')" read -r name status secs msg; do
        [ -z "$name" ] && continue
        [ "$secs" = "-" ] && secs="null"
        [ "$msg" = "-" ] && msg=""
        if [ "$first" -eq 0 ]; then echo ","; fi
        first=0
        printf '    {"name": "%s", "status": "%s", "duration_seconds": %s, "messages": "%s"}' \
            "$(json_escape "$name")" "$status" "$secs" "$(json_escape "$msg")"
    done < "$TSV"
    echo
    echo "  ],"
    printf '  "other_errors": "%s"\n' "$(json_escape "$(cat "$OTHER_ERRORS")")"
    echo "}"
} > "$RESULTS_JSON"

# ---- report.md -------------------------------------------------------------------------
{
    if [ "$TEST_CODE" -eq 0 ]; then
        echo "# ClipSync iOS UI tests: PASSED"
    else
        echo "# ClipSync iOS UI tests: FAILED (exit $TEST_CODE)"
    fi
    echo
    echo "- Simulator: $SIM_NAME, $SIM_RUNTIME ($UDID)"
    echo "- Started: $STARTED"
    echo "- Finished: $FINISHED (${ELAPSED} s)"
    echo "- Totals: $TOTAL tests, $PASSED passed, $FAILED failed, $SKIPPED skipped"
    echo "- Video: build/e2e-ios/ios-ui-tests.mp4 ($VIDEO_BYTES bytes)"
    echo "- Screenshots: $SHOT_COUNT in build/e2e-ios/shots/"
    echo "- Result bundle: build/e2e-ios/result.xcresult; full log: build/logs/ios-ui-tests.log"
    echo
    echo "| Test | Result | Seconds |"
    echo "|---|---|---|"
    while IFS="$(printf '\t')" read -r name status secs msg; do
        [ -z "$name" ] && continue
        echo "| $name | $status | $secs |"
    done < "$TSV"
    if [ "$TOTAL" -eq 0 ]; then
        echo "| (no test results found in the log) | - | - |"
    fi
    echo
    if [ "$FAILED" -gt 0 ]; then
        echo "## Failures"
        echo
        while IFS="$(printf '\t')" read -r name status secs msg; do
            [ "$status" = "failed" ] || continue
            echo "### $name"
            echo
            if [ -n "$msg" ] && [ "$msg" != "-" ]; then
                printf '%s\n' "$msg" | awk '{ n = split($0, parts, / \|\| /); for (i = 1; i <= n; i++) print "- " parts[i] }'
            else
                echo "- (no assertion message found; see the log)"
            fi
            echo
        done < "$TSV"
    fi
    if [ -s "$OTHER_ERRORS" ]; then
        echo "## Other errors in the log"
        echo
        echo '```'
        cat "$OTHER_ERRORS"
        echo '```'
    fi
} > "$REPORT_MD"

# ---- summary (also echoed so build.sh's ios-sim-run.summary greps it) -------------------
{
    echo "command: ios-ui-tests"
    echo "exit_code: $TEST_CODE"
    echo "finished: $FINISHED"
    echo "simulator: $SIM_NAME ($SIM_RUNTIME)"
    echo "totals: $TOTAL total, $PASSED passed, $FAILED failed, $SKIPPED skipped"
    echo "log: $LOG"
    echo "report: $REPORT_MD"
    echo "--- failing tests ---"
    while IFS="$(printf '\t')" read -r name status secs msg; do
        [ "$status" = "failed" ] || continue
        [ "$msg" = "-" ] && msg="no assertion message in the log"
        echo "error: UI test failed: $name: $msg"
    done < "$TSV"
    echo "--- errors ---"
    cat "$OTHER_ERRORS"
} > "$SUMMARY"
cat "$SUMMARY"

# Leave the Simulator showing the app.
xcrun simctl terminate "$UDID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$IOS_BUNDLE_ID" -uitest-seed >/dev/null 2>&1 \
    || echo "==> warning: could not relaunch $IOS_BUNDLE_ID after the tests"

echo "==> iOS UI tests finished with exit code $TEST_CODE ($PASSED/$TOTAL passed; report: $REPORT_MD)"
exit $TEST_CODE
