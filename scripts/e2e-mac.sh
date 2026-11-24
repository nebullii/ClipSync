#!/bin/bash
# ClipSync macOS end-to-end test.
#
# Called by `scripts/build.sh run-mac` right after the app was launched with
#     CLIPSYNC_UITEST=1 CLIPSYNC_STATUS_FILE=1 CLIPSYNC_SHOW_PANEL=1 CLIPSYNC_E2E_DIR=<repo>/build/e2e
# Can also be run by hand against such a running instance:  scripts/e2e-mac.sh [pid]
#
# Talks to the app's E2E driver (macOS/App/E2E/E2EDriver.swift) only through files:
#   build/e2e/commands/NNNN-<name>.cmd  → .ok / .err   (commands)
#   build/e2e/status.kv / status.json                  (state)
#   build/e2e/shots/*.png                              (in-process window renders)
# Results: build/e2e/results.json, build/e2e/report.md, build/e2e/e2e.log,
#          build/e2e/commands.log
#
# bash 3.2, macOS tools only (pbcopy, pbpaste, osascript, swift/swiftc, open, ps, perl).
# Never aborts on a failing scenario; every wait is bounded. Exit: 0 = no FAIL, 1 = FAIL(s).
# The user's clipboard TEXT is saved first (outside build/) and restored at the end.
# While this runs, do not use the Mac: clicks hide the panel and copies get captured.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E2E="${CLIPSYNC_E2E_DIR:-$ROOT/build/e2e}"
CMD_DIR="$E2E/commands"
SHOTS="$E2E/shots"
TOOLS="$E2E/tools"
KV="$E2E/status.kv"
JSON="$E2E/status.json"
RESULTS="$E2E/results.json"
REPORT="$E2E/report.md"
LOG="$E2E/e2e.log"
CMDLOG="$E2E/commands.log"
MAC_APP="$ROOT/build/DerivedData/Build/Products/Debug/ClipSync.app"
APP_PID="${1:-}"

mkdir -p "$CMD_DIR" "$SHOTS" "$TOOLS"
: > "$LOG"
: > "$CMDLOG"

RUN_ID="$(date +%H%M%S)$$"
UNIQ="zqx${RUN_ID}"
TEXT_A="ClipSync e2e alpha ${UNIQ}"
FILLER="ClipSync e2e filler ${RUN_ID}"
LINK="https://example.com/clipsync-e2e/${RUN_ID}"
COLOR="#14B8A6"
RICH_TOKEN="rtf${RUN_ID}"
RICH_TEXT="ClipSync e2e rich ${RICH_TOKEN}"
FILE_A="/tmp/cse2e-a-${RUN_ID}.txt"
FILE_B="/tmp/cse2e-b-${RUN_ID}.txt"
SECRET_C="cs-secret-${RUN_ID}-concealed"
SECRET_T="cs-secret-${RUN_ID}-transient"
AFTER_C="ClipSync e2e after concealed ${RUN_ID}"
AFTER_T="ClipSync e2e after transient ${RUN_ID}"
PAUSED_TEXT="ClipSync e2e paused ${RUN_ID}"
SEED_TAG="sd${RUN_ID}"
LOCKED_TEXT="ClipSync e2e locked ${RUN_ID}"
LINK_NOFETCH="https://example.com/clipsync-e2e-nofetch/${RUN_ID}"
REDACTED="<redacted>"
TARGET_DOC="$E2E/paste-target.txt"
TARGET_NAME="paste-target.txt"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

if /usr/bin/perl -MTime::HiRes -e 1 >/dev/null 2>&1; then
    now_ms() { /usr/bin/perl -MTime::HiRes=time -e 'printf("%d\n", time() * 1000)'; }
else
    now_ms() { echo "$(( $(date +%s) * 1000 ))"; }
fi

iso_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log() {
    local line
    line="[$(date '+%H:%M:%S')] $*"
    echo "$line"
    echo "$line" >> "$LOG"
}

# num <value> → the value if it is an integer, else 0
num() {
    case "$1" in
        ''|*[!0-9-]*) echo 0 ;;
        *) echo "$1" ;;
    esac
}

# lt <a> <b>: true when a < b (floats)
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) < (b + 0)) }'; }

# avg of numbers on stdin
avg() { awk '{ s += $1; n++ } END { if (n > 0) printf("%.2f", s / n); else print "0" }'; }

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# kv <key> → value from status.kv (escaped form: \n for newlines), empty if missing
kv() {
    [ -f "$KV" ] || return 0
    awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$KV" 2>/dev/null
}

kv_eq() { [ "$(kv "$1")" = "$2" ]; }
kv_ne() { [ "$(kv "$1")" != "$2" ]; }
kv_contains() {
    case "$(kv "$1")" in
        *"$2"*) return 0 ;;
    esac
    return 1
}
kv_icontains() {
    case "$(lower "$(kv "$1")")" in
        *"$(lower "$2")"*) return 0 ;;
    esac
    return 1
}
kv_not_contains() { ! kv_contains "$1" "$2"; }

# wait_until <timeout ms> <predicate command...>; sets WAIT_MS
WAIT_MS=0
wait_until() {
    local timeout="$1"
    shift
    local start now
    start="$(now_ms)"
    while :; do
        if "$@"; then
            WAIT_MS=$(( $(now_ms) - start ))
            return 0
        fi
        now="$(now_ms)"
        if [ $(( now - start )) -ge "$timeout" ]; then
            WAIT_MS=$(( now - start ))
            return 1
        fi
        sleep 0.1
    done
}

# run_with_timeout <seconds> <command...>: returns 124 on timeout
run_with_timeout() {
    local secs="$1"
    shift
    "$@" &
    local pid=$!
    local ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $(( secs * 10 )) ]; then
            kill -TERM "$pid" 2>/dev/null
            sleep 0.3
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1
        ticks=$(( ticks + 1 ))
    done
    wait "$pid"
}

# Index (0-9) of the newest-items entry whose plainText equals $1, or empty.
item_index_of() {
    local i=0
    while [ "$i" -lt 10 ]; do
        if [ "$(kv "items.$i.plainText")" = "$1" ]; then
            echo "$i"
            return 0
        fi
        i=$(( i + 1 ))
    done
    return 1
}

# One-line summary of status.kv, appended to FAIL details.
state() {
    if [ ! -f "$KV" ]; then
        echo "status.kv missing"
        return
    fi
    printf 'status{seq=%s locked=%s itemCount=%s paused=%s ax=%s panelVisible=%s visibleCards=%s selected=%s search="%s" filter=%s scope=%s front=%s pasteTarget=%s windows=%s newest=[%s|%s|pinned=%s] 2nd=[%s|%s] 3rd=[%s|%s] lastPaste=[%s|%s|plain=%s] lastCopy=[%s] hiddenAfter=[%s]}' \
        "$(kv seq)" "$(kv locked)" "$(kv itemCount)" "$(kv capturePaused)" "$(kv accessibilityGranted)" \
        "$(kv panelVisible)" "$(kv visibleCardCount)" "$(kv panelSelectedIndex)" "$(kv panelSearchText)" \
        "$(kv panelFilter)" "$(kv panelScope)" "$(kv frontmostApp)" "$(kv pasteTarget)" "$(kv openWindows)" \
        "$(kv items.0.kind)" "$(kv items.0.plainText)" "$(kv items.0.isPinned)" \
        "$(kv items.1.kind)" "$(kv items.1.plainText)" \
        "$(kv items.2.kind)" "$(kv items.2.plainText)" \
        "$(kv lastPaste.mode)" "$(kv lastPaste.text)" "$(kv lastPaste.asPlainText)" "$(kv lastCopy.text)" "$(kv panelHiddenAfterCommand)"
}

# send_cmd "<command line>" [timeout seconds, default 10]
# Sets CMD_STATUS (ok|err|timeout), CMD_RESULT, CMD_MS. Returns 0 only for ok.
CMD_SEQ=0
CMD_STATUS=""
CMD_RESULT=""
CMD_MS=0
send_cmd() {
    local line="$1"
    local timeout="${2:-10}"
    CMD_SEQ=$(( CMD_SEQ + 1 ))
    local word
    word="$(printf '%s' "${line%% *}" | tr -cd 'A-Za-z0-9-')"
    local base
    base="$(printf '%04d' "$CMD_SEQ")-${word}"
    printf '%s\n' "$line" > "$CMD_DIR/$base.tmp"
    mv "$CMD_DIR/$base.tmp" "$CMD_DIR/$base.cmd"
    local start deadline
    start="$(now_ms)"
    deadline=$(( start + timeout * 1000 ))
    while :; do
        if [ -f "$CMD_DIR/$base.ok" ]; then
            CMD_STATUS="ok"
            CMD_RESULT="$(head -n 1 "$CMD_DIR/$base.ok")"
            break
        fi
        if [ -f "$CMD_DIR/$base.err" ]; then
            CMD_STATUS="err"
            CMD_RESULT="$(head -n 1 "$CMD_DIR/$base.err")"
            break
        fi
        if [ "$(now_ms)" -ge "$deadline" ]; then
            CMD_STATUS="timeout"
            CMD_RESULT="no .ok/.err for '$line' after ${timeout}s (app hung, crashed, or E2E driver not active)"
            break
        fi
        sleep 0.05
    done
    CMD_MS=$(( $(now_ms) - start ))
    echo "[$(date '+%H:%M:%S')] $base [$CMD_STATUS ${CMD_MS}ms] $line -> $CMD_RESULT" >> "$CMDLOG"
    [ "$CMD_STATUS" = "ok" ]
}

# copy_text <text>: puts plain text on the general pasteboard
copy_text() { printf '%s' "$1" | pbcopy; }

app_alive() {
    [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null
}

# Shows the panel when status.kv says it is hidden.
ensure_panel() {
    if ! kv_eq panelVisible true; then
        send_cmd "show" >/dev/null
        wait_until 1000 kv_eq panelVisible true >/dev/null
    fi
    kv_eq panelVisible true
}

# restore_panel_state [setup command...]: makes sure the panel is visible. If it had to be
# shown again (show() resets search, filter and scope), re-sends the setup commands.
# Every scenario that needs the panel calls this instead of relying on earlier state.
restore_panel_state() {
    if kv_eq panelVisible true; then
        return 0
    fi
    log "panel is hidden (hidden after command: '$(kv panelHiddenAfterCommand)'); showing it again"
    ensure_panel || return 1
    if [ $# -gt 0 ]; then
        local c
        for c in "$@"; do
            send_cmd "$c" >/dev/null
        done
        sleep 0.3
    fi
    kv_eq panelVisible true
}

# ---------------------------------------------------------------------------
# Pasteboard helper tool (compiled once with swiftc; falls back to the swift interpreter)
# ---------------------------------------------------------------------------

PBTOOL_SRC="$TOOLS/pbtool.swift"
PBTOOL_BIN="$TOOLS/pbtool"

cat > "$PBTOOL_SRC" <<'SWIFT'
import AppKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: pbtool rtf|image|files|concealed|transient|types|changecount ...") }
let pasteboard = NSPasteboard.general

func writeItems(_ items: [NSPasteboardWriting]) {
    pasteboard.clearContents()
    if pasteboard.writeObjects(items) {
        print("ok changeCount=\(pasteboard.changeCount)")
    } else {
        fail("writeObjects failed")
    }
}

/// Keeps this (short-lived) writer process alive and its run loop turning for a moment,
/// so AppKit can hand every written item to the pasteboard server before exit.
/// "localItems" is THIS process's view; only a separate process shows what others see.
func settle() {
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    print("localItems=\(pasteboard.pasteboardItems?.count ?? 0)")
}

switch args[1] {
case "rtf":
    let text = args.count > 2 ? args[2] : "ClipSync rich text"
    let attributed = NSMutableAttributedString(string: text, attributes: [
        .font: NSFont.boldSystemFont(ofSize: 18),
        .foregroundColor: NSColor.systemRed
    ])
    let range = NSRange(location: 0, length: attributed.length)
    guard let rtf = try? attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
        fail("RTF encoding failed")
    }
    let item = NSPasteboardItem()
    _ = item.setData(rtf, forType: .rtf)
    _ = item.setString(text, forType: .string)
    writeItems([item])
case "image":
    let width = 400
    let height = 300
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { fail("bitmap allocation failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.65, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 120, y: 70, width: 160, height: 160)).fill()
    NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.1, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 20, y: 240, width: 360, height: 40)).fill()
    let label = args.count > 3 ? args[3] : "E2E"
    (label as NSString).draw(at: NSPoint(x: 24, y: 20), withAttributes: [
        .font: NSFont.boldSystemFont(ofSize: 28),
        .foregroundColor: NSColor.black
    ])
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG encoding failed") }
    if args.count > 2 {
        try? png.write(to: URL(fileURLWithPath: args[2]))
    }
    let item = NSPasteboardItem()
    _ = item.setData(png, forType: .png)
    writeItems([item])
case "files":
    // Like a Finder copy of several files: one pasteboard item per file, each carrying
    // its own public.file-url (written eagerly, so nothing depends on this process
    // staying alive to provide data later).
    let paths = Array(args.dropFirst(2))
    guard !paths.isEmpty else { fail("files needs paths") }
    var fileItems: [NSPasteboardItem] = []
    for path in paths {
        let item = NSPasteboardItem()
        _ = item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        fileItems.append(item)
    }
    writeItems(fileItems)
    settle()
case "files-nsurl":
    // The AppKit convenience path: writeObjects([NSURL, NSURL]).
    let urls = args.dropFirst(2).map { NSURL(fileURLWithPath: $0) }
    guard !urls.isEmpty else { fail("files-nsurl needs paths") }
    writeItems(Array(urls))
    settle()
case "concealed", "transient":
    guard args.count > 2 else { fail("\(args[1]) needs a string") }
    let marker = args[1] == "concealed" ? "org.nspasteboard.ConcealedType" : "org.nspasteboard.TransientType"
    let item = NSPasteboardItem()
    _ = item.setString(args[2], forType: .string)
    _ = item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
    writeItems([item])
case "types":
    for type in pasteboard.pasteboardItems?.first?.types ?? [] {
        print(type.rawValue)
    }
case "items":
    // Every pasteboard item: "item<i>: type type ..."
    let all = pasteboard.pasteboardItems ?? []
    for (index, item) in all.enumerated() {
        print("item\(index): " + item.types.map { $0.rawValue }.joined(separator: " "))
    }
case "fileurls":
    // One line per pasteboard item: its public.file-url (or "-").
    let all = pasteboard.pasteboardItems ?? []
    print("count=\(all.count)")
    for (index, item) in all.enumerated() {
        print("item\(index)=" + (item.string(forType: .fileURL) ?? "-"))
    }
case "changecount":
    print(pasteboard.changeCount)
default:
    fail("unknown subcommand \(args[1])")
}
SWIFT

build_pbtool() {
    rm -f "$PBTOOL_BIN"
    if command -v xcrun >/dev/null 2>&1; then
        run_with_timeout 120 xcrun swiftc -o "$PBTOOL_BIN" "$PBTOOL_SRC" >> "$LOG" 2>&1
    elif [ -x /usr/bin/swiftc ]; then
        run_with_timeout 120 /usr/bin/swiftc -o "$PBTOOL_BIN" "$PBTOOL_SRC" >> "$LOG" 2>&1
    fi
    if [ -x "$PBTOOL_BIN" ]; then
        log "pbtool compiled"
    else
        log "pbtool could not be compiled; using /usr/bin/swift interpreter (slower)"
    fi
}

pbtool() {
    if [ -x "$PBTOOL_BIN" ]; then
        run_with_timeout 20 "$PBTOOL_BIN" "$@"
    else
        run_with_timeout 90 /usr/bin/swift "$PBTOOL_SRC" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Scenario bookkeeping
# ---------------------------------------------------------------------------

N=0
SC_STATUS=""
SC_DETAIL=""
pass() { SC_STATUS="PASS"; SC_DETAIL="$*"; }
fail() { SC_STATUS="FAIL"; SC_DETAIL="$*"; }
skip() { SC_STATUS="SKIP"; SC_DETAIL="$*"; }

record() {
    # record <id> <name> <status> <detail> <ms>
    S_ID[$N]="$1"
    S_NAME[$N]="$2"
    S_STATUS[$N]="$3"
    S_DETAIL[$N]="$4"
    S_MS[$N]="$5"
    N=$(( N + 1 ))
    log "$3  [$1] $2 (${5}ms) — $4"
}

# run_scenario <id> <name> <function>
run_scenario() {
    local id="$1" name="$2" fn="$3"
    SC_STATUS="FAIL"
    SC_DETAIL="scenario did not set a result"
    local start
    start="$(now_ms)"
    if ! app_alive; then
        fail "ClipSync (pid ${APP_PID:-?}) is not running any more — crashed? See build/logs/run-mac.log"
    else
        "$fn"
    fi
    record "$id" "$name" "$SC_STATUS" "$SC_DETAIL" $(( $(now_ms) - start ))
}

# take_snapshot <name>: records its own scenario "shot-<name>"
take_snapshot() {
    local name="$1"
    local start
    start="$(now_ms)"
    if ! app_alive; then
        record "shot-$name" "snapshot $name" "FAIL" "app not running" 0
        return
    fi
    send_cmd "snapshot $name" 15
    local files
    files="$(cd "$SHOTS" && ls "$name"-*.png 2>/dev/null | tr '\n' ' ')"
    if [ "$CMD_STATUS" = "ok" ] && [ -n "$files" ]; then
        record "shot-$name" "snapshot $name" "PASS" "files: $files| $CMD_RESULT" $(( $(now_ms) - start ))
    else
        record "shot-$name" "snapshot $name" "FAIL" "expected shots/$name-<window>.png; command=$CMD_STATUS: $CMD_RESULT; files: ${files:-none} | $(state)" $(( $(now_ms) - start ))
    fi
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

sc_capture_text() {
    local before
    before="$(kv itemCount)"
    copy_text "$TEXT_A"
    if wait_until 5000 kv_eq items.0.plainText "$TEXT_A"; then
        local ms=$WAIT_MS kind
        kind="$(kv items.0.kind)"
        if [ "$ms" -le 2000 ] && [ "$kind" = "text" ]; then
            pass "newest item after ${ms}ms, kind=text, itemCount ${before}→$(kv itemCount)"
        else
            fail "expected newest kind=text within 2000ms; got kind=$kind after ${ms}ms | $(state)"
        fi
    else
        fail "expected newest item plainText='$TEXT_A' within 2000ms; nothing after ${WAIT_MS}ms | $(state)"
    fi
}

sc_dedup() {
    copy_text "$FILLER"
    if ! wait_until 5000 kv_eq items.0.plainText "$FILLER"; then
        fail "setup: filler text not captured within 5s | $(state)"
        return
    fi
    local count1 count2
    count1="$(kv itemCount)"
    copy_text "$TEXT_A"
    if ! wait_until 5000 kv_eq items.0.plainText "$TEXT_A"; then
        fail "expected the re-copied text to become newest again (bump) within 5s | $(state)"
        return
    fi
    sleep 0.3
    count2="$(kv itemCount)"
    if [ "$count1" = "$count2" ]; then
        pass "re-copy bumped existing item to newest; itemCount stayed $count2 (took ${WAIT_MS}ms)"
    else
        fail "expected itemCount unchanged ($count1) after copying a duplicate; got $count2 | $(state)"
    fi
}

sc_link() {
    copy_text "$LINK"
    if wait_until 5000 kv_eq items.0.plainText "$LINK"; then
        if kv_eq items.0.kind link; then
            pass "kind=link after ${WAIT_MS}ms"
        else
            fail "expected kind=link for '$LINK'; got kind=$(kv items.0.kind) | $(state)"
        fi
    else
        fail "expected newest plainText='$LINK' within 5s | $(state)"
    fi
}

sc_color() {
    copy_text "$COLOR"
    if wait_until 5000 kv_icontains items.0.plainText "14B8A6"; then
        if kv_eq items.0.kind color; then
            pass "kind=color after ${WAIT_MS}ms (plainText=$(kv items.0.plainText))"
        else
            fail "expected kind=color for '$COLOR'; got kind=$(kv items.0.kind) | $(state)"
        fi
    else
        fail "expected newest item containing '14B8A6' within 5s | $(state)"
    fi
}

sc_rich() {
    local out
    out="$(pbtool rtf "$RICH_TEXT" 2>&1)"
    if [ $? -ne 0 ]; then
        fail "could not write RTF to the pasteboard (pbtool: $out)"
        return
    fi
    if wait_until 5000 kv_contains items.0.plainText "$RICH_TOKEN"; then
        if kv_eq items.0.kind richText; then
            pass "kind=richText after ${WAIT_MS}ms"
        else
            fail "expected kind=richText for RTF+plain; got kind=$(kv items.0.kind) | $(state)"
        fi
    else
        fail "expected newest plainText containing '$RICH_TOKEN' within 5s (pbtool: $out) | $(state)"
    fi
}

sc_image() {
    local before out
    before="$(num "$(kv itemCount)")"
    out="$(pbtool image "$E2E/test-image.png" "E2E $RUN_ID" 2>&1)"
    if [ $? -ne 0 ]; then
        fail "could not write PNG to the pasteboard (pbtool: $out)"
        return
    fi
    if wait_until 8000 kv_eq items.0.kind image; then
        pass "kind=image after ${WAIT_MS}ms, itemCount ${before}→$(kv itemCount) (thumbnail: see shot-04-images)"
    else
        fail "expected newest kind=image within 8s after writing a 400x300 PNG (itemCount before=$before) | $(state)"
    fi
}

# fileurl_count <pbtool fileurls output>: number of items carrying a public.file-url
fileurl_count() {
    printf '%s\n' "$1" | tr ';' '\n' | grep -c '^item[0-9]*=file:'
}

# check_files_item <writer output>: newest item must be kind=file naming both files.
# Where a file is lost is decided from three views of the pasteboard:
#   writer      : pbtool's own process (localItems=, not authoritative for others)
#   separate    : a NEW pbtool process right after the write (what other apps see)
#   ClipSync    : the app's own NSPasteboard.general (driver command pb-items)
check_files_item() {
    local out="$1"
    local separate separate_count app_view
    separate="$(pbtool fileurls 2>&1 | tr '\n' ';')"
    separate_count="$(fileurl_count "$separate")"
    send_cmd "pb-items" >/dev/null
    app_view="$CMD_RESULT"
    local views="writer: ${out}; separate process: ${separate}; ClipSync: ${app_view}"
    if ! wait_until 5000 kv_eq items.0.kind file; then
        fail "expected newest kind=file within 5s ($views) | $(state)"
        return
    fi
    sleep 0.3
    local text title a b
    text="$(kv items.0.plainText)"
    title="$(kv items.0.title)"
    # Compare by file name: /tmp is a symlink to /private/tmp.
    a="$(basename "$FILE_A")"
    b="$(basename "$FILE_B")"
    case "$text" in
        *"$a"*"$b"*|*"$b"*"$a"*)
            case "$title" in
                *"+ 1 more"*)
                    pass "kind=file after ${WAIT_MS}ms; title='${title}'; plainText lists both files ($views)"
                    ;;
                *)
                    fail "plainText lists both files but title='${title}' (expected '<first> + 1 more'); $views | $(state)"
                    ;;
            esac
            ;;
        *)
            if [ "$separate_count" -lt 2 ]; then
                fail "TEST WRITER, not the reader: right after pbtool wrote 2 file items, a separate process sees only ${separate_count} item(s) with public.file-url, so no reader can capture both. Captured title='${title}' plainText='${text}'; $views | $(state)"
            else
                fail "PRODUCT READER: other processes see 2 file items but the capture has title='${title}' plainText='${text}' (expected both $a and $b); $views | $(state)"
            fi
            ;;
    esac
}

sc_files() {
    echo "ClipSync e2e file A" > "$FILE_A"
    echo "ClipSync e2e file B" > "$FILE_B"
    local out
    out="$(pbtool files "$FILE_A" "$FILE_B" 2>&1 | tr '\n' ' ')"
    case "$out" in
        ok*) ;;
        *) fail "could not write file URLs (pbtool: $out)"; return ;;
    esac
    check_files_item "$out"
}

# Same two files written with writeObjects([NSURL, NSURL]). Copies a filler first so the
# re-copy is a dedup bump that moves the file item back to the top.
sc_files_nsurl() {
    copy_text "$FILLER files"
    wait_until 5000 kv_eq items.0.plainText "$FILLER files"
    local out
    out="$(pbtool files-nsurl "$FILE_A" "$FILE_B" 2>&1 | tr '\n' ' ')"
    case "$out" in
        ok*) ;;
        *) fail "could not write NSURLs (pbtool: $out)"; return ;;
    esac
    check_files_item "$out"
}

# g3: the two-file item written back by ClipSync (a long-running app) must give other
# apps 2 pasteboard items, each with a public.file-url, naming both files.
sc_files_roundtrip() {
    restore_panel_state || { fail "panel not visible | $(state)"; return; }
    local seeded=""
    send_cmd "select-kind file"
    send_cmd "item-files"
    case "$CMD_RESULT" in
        *"count=2 "*) ;;
        *)
            # Capture lost a file (see g/g2): seed a correct two-file item so the
            # store -> writer half is still tested. Clearly labelled.
            send_cmd "seed-files $FILE_A $FILE_B"
            seeded="SEEDED two-file item via ClipStore ($CMD_STATUS $CMD_RESULT) because the captured item does not hold 2 URLs; "
            restore_panel_state
            send_cmd "select-kind file"
            send_cmd "item-files"
            ;;
    esac
    local store_view="$CMD_RESULT"
    if ! send_cmd "copy"; then
        fail "${seeded}copy command: $CMD_STATUS $CMD_RESULT | $(state)"
        return
    fi
    sleep 0.5
    local separate count a b
    separate="$(pbtool fileurls 2>&1 | tr '\n' ';')"
    count="$(fileurl_count "$separate")"
    a="$(basename "$FILE_A")"
    b="$(basename "$FILE_B")"
    case "$separate" in
        *"$a"*"$b"*|*"$b"*"$a"*)
            if [ "$count" -eq 2 ]; then
                pass "${seeded}store: ${store_view}; after copy other processes see 2 items with public.file-url naming both files ($separate)"
                return
            fi
            ;;
    esac
    fail "${seeded}expected 2 pasteboard items with public.file-url naming $a and $b after copy; separate process sees: ${separate} (store: ${store_view}) | $(state)"
}

# sc_marker <concealed|transient> <secret> <follow-up text>
sc_marker() {
    local which="$1" secret="$2" after="$3"
    local before out
    before="$(num "$(kv itemCount)")"
    out="$(pbtool "$which" "$secret" 2>&1)"
    if [ $? -ne 0 ]; then
        fail "could not write the $which string (pbtool: $out)"
        return
    fi
    sleep 1.5   # ≥ 3 monitor polls
    local mid
    mid="$(num "$(kv itemCount)")"
    # Prove the monitor is alive: a normal copy right after must be captured.
    copy_text "$after"
    local alive="no"
    if wait_until 5000 kv_eq items.0.plainText "$after"; then alive="yes"; fi
    sleep 0.3
    local final leaked="no"
    final="$(num "$(kv itemCount)")"
    if grep -qF "$secret" "$KV" "$JSON" 2>/dev/null; then leaked="yes"; fi
    if [ "$mid" -eq "$before" ] && [ "$leaked" = "no" ] && [ "$alive" = "yes" ] && [ "$final" -eq $(( before + 1 )) ]; then
        pass "$which string not captured (itemCount ${before}→$mid), absent from status files; follow-up copy captured ($final)"
    else
        fail "expected: itemCount unchanged after $which write (${before}→$mid), secret absent from status files (leaked=$leaked), follow-up copy captured (alive=$alive, itemCount=$final, expected $(( before + 1 ))) | $(state)"
    fi
}
sc_concealed() { sc_marker concealed "$SECRET_C" "$AFTER_C"; }
sc_transient() { sc_marker transient "$SECRET_T" "$AFTER_T"; }

sc_pause() {
    if ! send_cmd "pause-capture"; then
        fail "pause-capture command: $CMD_STATUS $CMD_RESULT | $(state)"
        return
    fi
    wait_until 1000 kv_eq capturePaused true
    local before mid
    before="$(num "$(kv itemCount)")"
    copy_text "$PAUSED_TEXT"
    sleep 1.5
    mid="$(num "$(kv itemCount)")"
    local leaked="no"
    if grep -qF "$PAUSED_TEXT" "$KV" 2>/dev/null; then leaked="yes"; fi
    if ! send_cmd "resume-capture"; then
        fail "resume-capture command: $CMD_STATUS $CMD_RESULT | $(state)"
        return
    fi
    wait_until 1000 kv_eq capturePaused false
    copy_text "$PAUSED_TEXT"
    local resumed="no"
    if wait_until 5000 kv_eq items.0.plainText "$PAUSED_TEXT"; then resumed="yes"; fi
    if [ "$mid" -eq "$before" ] && [ "$leaked" = "no" ] && [ "$resumed" = "yes" ]; then
        pass "while paused nothing was captured (itemCount ${before}→$mid); after resume the copy was captured in ${WAIT_MS}ms"
    else
        fail "expected: no capture while paused (itemCount ${before}→$mid, text in status=$leaked), capture after resume (resumed=$resumed) | $(state)"
    fi
}

SHOW_MS_FIRST=""
sc_panel_show() {
    send_cmd "hide" >/dev/null
    wait_until 1000 kv_eq panelVisible false >/dev/null
    if ! send_cmd "show"; then
        fail "show command: $CMD_STATUS $CMD_RESULT | $(state)"
        return
    fi
    local roundtrip=$CMD_MS
    if wait_until 300 kv_eq panelVisible true; then
        SHOW_MS_FIRST="$(kv lastShowDurationMs)"
        if lt "$SHOW_MS_FIRST" 0; then
            pass "panelVisible=true ${WAIT_MS}ms after the command was processed; show() duration not reported (lastShowDurationMs=$SHOW_MS_FIRST); command round trip ${roundtrip}ms (includes ≤200ms polling)"
        else
            pass "panelVisible=true ${WAIT_MS}ms after the command was processed; show() took ${SHOW_MS_FIRST}ms in-app; command round trip ${roundtrip}ms (includes ≤200ms polling)"
        fi
    else
        fail "expected panelVisible=true within 300ms of the show command being processed ($CMD_RESULT) | $(state)"
    fi
}

visible_one_with() {
    kv_eq visibleCardCount 1 && kv_contains rows.0.text "$1"
}

sc_search() {
    ensure_panel || { fail "panel not visible before search | $(state)"; return; }
    send_cmd "search $UNIQ"
    if wait_until 2000 visible_one_with "$UNIQ"; then
        pass "1 visible card containing '$UNIQ' after ${WAIT_MS}ms (in-app search round trip $(kv lastSearchRoundTripMs)ms, includes 120ms debounce)"
    else
        fail "expected visibleCardCount=1 with rows.0.text containing '$UNIQ' within 2s; got visibleCardCount=$(kv visibleCardCount) rows.0.text='$(kv rows.0.text)' | $(state)"
    fi
}

sc_navigation() {
    ensure_panel || { fail "panel not visible | $(state)"; return; }
    local count
    count="$(num "$(kv visibleCardCount)")"
    if [ "$count" -lt 3 ]; then
        fail "need ≥3 visible cards for navigation, have $count | $(state)"
        return
    fi
    send_cmd "select 0"
    send_cmd "move-right"
    send_cmd "move-right"
    if wait_until 1000 kv_eq panelSelectedIndex 2; then
        pass "select 0 + move-right×2 → selectedIndex 2 (selected: $(kv selected.kind) '$(kv selected.text)')"
    else
        fail "expected panelSelectedIndex=2; got $(kv panelSelectedIndex) (last command: $CMD_RESULT) | $(state)"
    fi
}

pb_equals() { [ "$(pbpaste)" = "$1" ]; }

sc_copy() {
    ensure_panel || { fail "panel not visible | $(state)"; return; }
    if ! send_cmd "select-text $TEXT_A"; then
        fail "could not select the text item: $CMD_RESULT | $(state)"
        return
    fi
    local before
    before="$(num "$(kv itemCount)")"
    if ! send_cmd "copy"; then
        fail "copy command: $CMD_STATUS $CMD_RESULT | $(state)"
        return
    fi
    local got="no"
    if wait_until 2000 pb_equals "$TEXT_A"; then got="yes"; fi
    sleep 1.3   # ≥ 3 monitor polls: an own write must NOT be re-captured
    local after newest
    after="$(num "$(kv itemCount)")"
    newest="$(kv items.0.plainText)"
    if [ "$got" = "yes" ] && [ "$after" -eq "$before" ] && [ "$newest" = "$TEXT_A" ]; then
        pass "pbpaste == original text; item is newest (markUsed); itemCount stayed $after; panelVisible=$(kv panelVisible)"
    else
        fail "expected pbpaste='$TEXT_A' (got '$(pbpaste | head -c 80)'), itemCount unchanged (${before}→$after), newest='$TEXT_A' (got '$newest') | $(state)"
    fi
}

sc_pinboard() {
    restore_panel_state || { fail "panel not visible | $(state)"; return; }
    send_cmd "select-text $TEXT_A" || { fail "select-text: $CMD_RESULT | $(state)"; return; }
    send_cmd "pin"
    local pinResult="$CMD_STATUS $CMD_RESULT"
    sleep 0.3
    local idx pinned=""
    idx="$(item_index_of "$TEXT_A")"
    if [ -n "$idx" ]; then pinned="$(kv "items.$idx.isPinned")"; fi
    send_cmd "create-pinboard Work"
    local createResult="$CMD_STATUS $CMD_RESULT"
    wait_until 1000 kv_contains pinboards "Work"
    send_cmd "select-text $TEXT_A"
    send_cmd "add-to-pinboard Work"
    local addResult="$CMD_STATUS $CMD_RESULT"
    send_cmd "open-pinboard Work"
    local ok_board="no"
    if wait_until 1500 visible_one_with "$UNIQ"; then ok_board="yes"; fi
    restore_panel_state "open-pinboard Work"
    wait_until 1500 visible_one_with "$UNIQ"
    take_snapshot "03-pinboard"
    send_cmd "open-history"
    wait_until 1000 kv_eq panelScope history
    if [ "$pinned" = "true" ] && [ "$ok_board" = "yes" ]; then
        pass "item pinned (items.$idx.isPinned=true); pinboard 'Work' created; open-pinboard shows 1 card; back to history (scope=$(kv panelScope))"
    else
        fail "expected isPinned=true (got '${pinned:-item not in newest 10}', pin: $pinResult), pinboard Work with 1 visible card (create: $createResult; add: $addResult; visible=$(kv visibleCardCount) scope=$(kv panelScope) rows.0='$(kv rows.0.text)') | $(state)"
    fi
}

sc_delete() {
    restore_panel_state || { fail "panel not visible | $(state)"; return; }
    if ! send_cmd "select-text $LINK"; then
        fail "could not select the link item to delete: $CMD_RESULT | $(state)"
        return
    fi
    local before
    before="$(num "$(kv itemCount)")"
    send_cmd "delete"
    if wait_until 2000 kv_eq itemCount "$(( before - 1 ))"; then
        if grep -qF "$LINK" "$KV" 2>/dev/null; then
            fail "itemCount decreased but the deleted link is still listed in status.kv | $(state)"
        else
            pass "deleted the link item: itemCount ${before}→$(kv itemCount) ($CMD_RESULT)"
        fi
    else
        fail "expected itemCount $(( before - 1 )) after delete; got $(kv itemCount) ($CMD_STATUS $CMD_RESULT) | $(state)"
    fi
}

only_images_visible() {
    local kinds
    kinds="$(kv visibleKinds)"
    [ -n "$kinds" ] || return 1
    [ -z "$(printf '%s' "$kinds" | tr ',' '\n' | grep -v '^image$')" ]
}

sc_filters() {
    restore_panel_state || { fail "panel not visible | $(state)"; return; }
    send_cmd "filter images"
    if wait_until 1500 only_images_visible; then
        pass "filter images → $(kv visibleCardCount) card(s), all kind=image"
    else
        fail "expected only image cards (≥1) with filter=images; visibleKinds='$(kv visibleKinds)' filter=$(kv panelFilter) ($CMD_STATUS $CMD_RESULT) | $(state)"
    fi
    restore_panel_state "filter images"
    wait_until 1500 only_images_visible
    take_snapshot "04-images"
    send_cmd "filter all"
    wait_until 1000 kv_eq panelFilter all
}

TEXTEDIT_READY="no"
TEXTEDIT_DIAG=""
TEXTEDIT_BUG=""

# Frontmost app according to the OS (lsappinfo needs no permission), for cross-checks.
os_front_app() {
    local asn
    asn="$(run_with_timeout 5 lsappinfo front 2>/dev/null)"
    [ -n "$asn" ] || return 0
    run_with_timeout 5 lsappinfo info -only bundleid "$asn" 2>/dev/null \
        | sed -n 's/.*"CFBundleIdentifier"="\([^"]*\)".*/\1/p' | head -n 1
}

textedit_is_target() {
    kv_eq frontmostApp "com.apple.TextEdit" && kv_eq pasteTarget "com.apple.TextEdit"
}

# Records what the OS and ClipSync each think is frontmost, and classifies a mismatch.
textedit_diagnose() {
    local os_front app_front target previous
    os_front="$(os_front_app)"
    app_front="$(kv frontmostApp)"
    target="$(kv pasteTarget)"
    previous="$(kv trackerPreviousApp)"
    TEXTEDIT_DIAG="OS frontmost (lsappinfo)=${os_front:-?}, ClipSync frontmostApp=${app_front}, pasteTarget=${target}, trackerPreviousApp=${previous}"
    TEXTEDIT_BUG=""
    if [ "$app_front" = "com.apple.TextEdit" ] && [ "$target" != "com.apple.TextEdit" ]; then
        TEXTEDIT_BUG="PRODUCT BUG (FrontmostAppTracker): frontmostApp is TextEdit but pasteTarget is '${target}'"
    elif [ "$os_front" = "com.apple.TextEdit" ] && [ "$app_front" != "com.apple.TextEdit" ]; then
        TEXTEDIT_BUG="PRODUCT BUG (ClipSync does not see activations): the OS says TextEdit is frontmost, ClipSync still reports '${app_front}'"
    fi
}

# Opens the target document and waits until TextEdit is frontmost AND the paste target,
# stable for 1 s. Retries the activation (macOS may hand activation back to the previously
# active app when a background process asks for it).
textedit_activate() {
    local attempt=1
    while [ "$attempt" -le 3 ]; do
        open -a TextEdit "$TARGET_DOC" >> "$LOG" 2>&1
        if wait_until 5000 textedit_is_target; then
            sleep 1
            if textedit_is_target; then
                textedit_diagnose
                log "TextEdit is frontmost and the paste target (attempt $attempt; ${TEXTEDIT_DIAG})"
                return 0
            fi
        fi
        textedit_diagnose
        log "attempt $attempt: TextEdit is not (stably) the paste target: ${TEXTEDIT_DIAG}"
        attempt=$(( attempt + 1 ))
    done
    return 1
}

textedit_setup() {
    : > "$TARGET_DOC"
    send_cmd "hide" >/dev/null
    if textedit_activate; then
        TEXTEDIT_READY="yes"
    fi
}

# Shows the panel while TextEdit is the paste target. Returns 1 when TextEdit is not the
# target (re-activates once first). Sets TEXTEDIT_BUG when show() changed the target.
show_over_textedit() {
    if ! textedit_is_target; then
        send_cmd "hide" >/dev/null
        textedit_activate || return 1
    fi
    send_cmd "show" >/dev/null
    wait_until 1000 kv_eq panelVisible true || return 1
    sleep 0.3
    if ! kv_eq pasteTarget "com.apple.TextEdit"; then
        textedit_diagnose
        TEXTEDIT_BUG="PRODUCT BUG: showing the non-activating panel changed the paste target to '$(kv pasteTarget)' (${TEXTEDIT_DIAG})"
        return 1
    fi
    return 0
}

ax_granted_now() {
    send_cmd "status" >/dev/null
    kv_eq accessibilityGranted true
}

no_textedit_reason() {
    if [ -n "$TEXTEDIT_BUG" ]; then
        echo "${TEXTEDIT_BUG}; ${TEXTEDIT_DIAG}"
    else
        echo "TextEdit could not be made the frontmost app and paste target within 3 attempts (${TEXTEDIT_DIAG}); not pasting so that no keystroke goes to another app"
    fi
}

# n: needs no Accessibility to verify the pasteboard. Runs when TextEdit is the target,
# or when Accessibility is off (then paste is copy-only and no keystroke is sent anywhere).
sc_paste_plain() {
    local where="TextEdit"
    if [ "$TEXTEDIT_READY" != "yes" ] || ! show_over_textedit; then
        if [ -n "$TEXTEDIT_BUG" ]; then
            fail "$(no_textedit_reason) | $(state)"
            return
        fi
        if ax_granted_now; then
            skip "$(no_textedit_reason)"
            return
        fi
        where="no target (Accessibility off: copy-only, no keystroke)"
        restore_panel_state || { fail "panel not visible | $(state)"; return; }
    fi
    if ! send_cmd "select-kind richText"; then
        fail "no rich text card to select: $CMD_RESULT | $(state)"
        return
    fi
    send_cmd "paste-plain"
    local result="$CMD_STATUS $CMD_RESULT"
    wait_until 1000 kv_eq lastPaste.asPlainText true
    local types text
    types="$(pbtool items 2>&1 | tr '\n' ' ')"
    text="$(pbpaste)"
    sleep 1
    case " $types " in
        *" public.rtf "*)
            fail "expected no public.rtf after paste-plain; pasteboard: $types ($result) | $(state)"
            ;;
        *" public.utf8-plain-text "*)
            case "$text" in
                *"$RICH_TOKEN"*)
                    pass "pasteboard has plain text only ($types); mode=$(kv lastPaste.mode) asPlainText=$(kv lastPaste.asPlainText); target: $where"
                    ;;
                *)
                    fail "plain text on pasteboard is '${text}', expected it to contain '${RICH_TOKEN}' ($types) | $(state)"
                    ;;
            esac
            ;;
        *)
            fail "expected public.utf8-plain-text on the pasteboard after paste-plain; pasteboard: $types ($result) | $(state)"
            ;;
    esac
}

AX_STEP="System Settings > Privacy & Security > Accessibility: switch on \"ClipSync\" if it is listed (at the end of every E2E run without Accessibility the app asks macOS to add it, so it should be listed after the first run), otherwise switch on \"Terminal\" (run-mac starts ClipSync as a child of the Terminal that runs scripts/watch.sh, so macOS may attribute the permission to Terminal). Each rebuild changes the ad-hoc signature: remove ClipSync from the list with the minus button and run run-mac again."
AUTOMATION_STEP="System Settings > Privacy & Security > Automation > Terminal: switch on TextEdit (or answer OK to the 'Terminal wants to control TextEdit' prompt), then run run-mac again."

read_textedit_doc() {
    run_with_timeout 15 osascript \
        -e "tell application \"TextEdit\"" \
        -e "if (count of (every document whose name is \"$TARGET_NAME\")) > 0 then" \
        -e "return text of (first document whose name is \"$TARGET_NAME\")" \
        -e "else" \
        -e "return text of front document" \
        -e "end if" \
        -e "end tell" 2>&1
}

# o: real ⌘V into TextEdit. Needs Accessibility and TextEdit as the paste target.
sc_paste_real() {
    if ! ax_granted_now; then
        skip "Accessibility not granted (accessibilityGranted=false), so ClipSync cannot send ⌘V; the copy-only fallback is tested in o2. To enable: $AX_STEP"
        return
    fi
    if [ "$TEXTEDIT_READY" != "yes" ] || ! show_over_textedit; then
        if [ -n "$TEXTEDIT_BUG" ]; then
            fail "$(no_textedit_reason) | $(state)"
        else
            skip "$(no_textedit_reason)"
        fi
        return
    fi
    if ! send_cmd "select-text $TEXT_A"; then
        fail "could not select the text item: $CMD_RESULT | $(state)"
        return
    fi
    send_cmd "paste"
    local result="$CMD_STATUS $CMD_RESULT"
    wait_until 1500 kv_contains lastPaste.text "$UNIQ"
    local mode
    mode="$(kv lastPaste.mode)"
    if [ "$mode" != "paste" ]; then
        fail "expected lastPaste.mode=paste with Accessibility granted; got '${mode}' ($result) | $(state)"
        return
    fi
    sleep 1.2   # the keystroke goes out 80-250 ms after the paste; give TextEdit time
    local doc rc
    doc="$(read_textedit_doc)"
    rc=$?
    if [ $rc -ne 0 ]; then
        skip "the keystroke was sent (mode=paste) but osascript could not read the TextEdit document (exit $rc: $(printf '%s' "$doc" | head -c 160)). Most likely Automation permission is missing. To enable: $AUTOMATION_STEP"
        return
    fi
    case "$doc" in
        *"$TEXT_A"*)
            pass "TextEdit document contains the pasted text (mode=paste, document length ${#doc})"
            ;;
        *)
            fail "expected TextEdit document to contain '${TEXT_A}'; document text: '$(printf '%s' "$doc" | head -c 160)' (mode=$mode) | $(state)"
            ;;
    esac
}

# o2: without Accessibility, paste must fall back to copy-only. Safe anywhere: no keystroke.
sc_paste_fallback() {
    if ax_granted_now; then
        skip "Accessibility is granted, so the copy-only fallback cannot be exercised in this run"
        return
    fi
    restore_panel_state || { fail "panel not visible | $(state)"; return; }
    if ! send_cmd "select-text $TEXT_A"; then
        fail "could not select the text item: $CMD_RESULT | $(state)"
        return
    fi
    send_cmd "paste"
    local result="$CMD_STATUS $CMD_RESULT"
    wait_until 1500 kv_contains lastPaste.text "$UNIQ"
    local mode got="no"
    mode="$(kv lastPaste.mode)"
    if wait_until 2000 pb_equals "$TEXT_A"; then got="yes"; fi
    if [ "$mode" = "copyOnly" ] && [ "$got" = "yes" ]; then
        pass "lastPaste.mode=copyOnly, lastPaste.text='$(kv lastPaste.text)', pbpaste equals the item text, panelVisible=$(kv panelVisible)"
    else
        fail "expected lastPaste.mode=copyOnly and pbpaste='${TEXT_A}'; got mode='${mode}', pbpaste='$(pbpaste | head -c 80)' ($result) | $(state)"
    fi
}

# v: copying an image must offer image data to other apps and never ClipSync-internal
# representations (thumbnails, file lists, ...). The own-write marker is intentional.
sc_image_copy_types() {
    restore_panel_state || { fail "panel not visible | $(state)"; return; }
    if ! send_cmd "select-kind image"; then
        fail "no image card to select: $CMD_RESULT | $(state)"
        return
    fi
    if ! send_cmd "copy"; then
        fail "copy command: $CMD_STATUS $CMD_RESULT | $(state)"
        return
    fi
    sleep 0.3
    local types
    types="$(pbtool items 2>&1 | tr '\n' ' ')"
    local leaked
    leaked="$(printf '%s' "$types" | tr ' ' '\n' | grep '^com\.thingbits\.clipsync\.' | grep -v '^com\.thingbits\.clipsync\.own-write$' | tr '\n' ' ')"
    case " $types " in
        *" public.png "*|*" public.tiff "*)
            if [ -n "$leaked" ]; then
                fail "internal ClipSync types leaked to the pasteboard: ${leaked}(all: $types) | $(state)"
            else
                pass "pasteboard offers image data and no internal representations ($types; own-write marker is intentional)"
            fi
            ;;
        *)
            fail "expected public.png or public.tiff on the pasteboard after copying the image item; got: $types | $(state)"
            ;;
    esac
}

textedit_cleanup() {
    [ "$TEXTEDIT_READY" = "yes" ] || return 0
    local out
    out="$(run_with_timeout 10 osascript -e "tell application \"TextEdit\" to close (every document whose name is \"$TARGET_NAME\") saving no" 2>&1)"
    log "TextEdit cleanup (close $TARGET_NAME without saving): exit $? $out"
}

sc_scale() {
    send_cmd "hide" >/dev/null
    local before
    before="$(num "$(kv itemCount)")"
    if ! send_cmd "seed 2000 $SEED_TAG" 300; then
        fail "seed command: $CMD_STATUS $CMD_RESULT | $(state)"
        return
    fi
    local seedResult="$CMD_RESULT"
    sleep 0.5
    local after
    after="$(num "$(kv itemCount)")"
    send_cmd "show" >/dev/null
    wait_until 1000 kv_eq panelVisible true
    local show1
    show1="$(kv lastShowDurationMs)"
    send_cmd "hide" >/dev/null
    send_cmd "show" >/dev/null
    wait_until 1000 kv_eq panelVisible true
    local show2
    show2="$(kv lastShowDurationMs)"
    local token="${SEED_TAG}s1234e"
    send_cmd "search $token"
    local found="no"
    if wait_until 3000 visible_one_with "$token"; then found="yes"; fi
    local searchWall=$WAIT_MS
    local searchMs searchSource="in-app"
    searchMs="$(kv lastSearchRoundTripMs)"
    if [ -z "$searchMs" ] || lt "$searchMs" 0; then
        # The app did not report a measurement: use the (pessimistic) script-observed time.
        searchMs="$searchWall"
        searchSource="script-observed (app reported none)"
    fi
    send_cmd "clear-search" >/dev/null
    send_cmd "hide" >/dev/null
    local metrics="SEEDED (ClipStore.ingest, not pasteboard): $seedResult; itemCount ${before}→$after; show after seeding ${show1}ms, again ${show2}ms (threshold <100); search '$token' ${searchMs}ms [$searchSource] incl. 120ms debounce (threshold <300), found=$found, script-observed ${searchWall}ms"
    if [ "$after" -lt $(( before + 2000 )) ]; then
        fail "expected itemCount ≥ $(( before + 2000 )) after seeding; $metrics | $(state)"
    elif [ "$found" != "yes" ]; then
        fail "expected exactly 1 card for '$token'; got visibleCardCount=$(kv visibleCardCount) rows.0='$(kv rows.0.text)'; $metrics"
    elif lt "$show1" 0 || ! lt "$show1" 100; then
        fail "show latency not < 100ms; $metrics"
    elif lt "$searchMs" 0 || ! lt "$searchMs" 300; then
        fail "search round trip not < 300ms; $metrics"
    else
        pass "$metrics"
    fi
}

sc_windows() {
    send_cmd "open-settings"
    local settings="no" onboarding="no"
    if wait_until 3000 kv_contains openWindows settings; then settings="yes"; fi
    sleep 0.5
    take_snapshot "05-settings"
    send_cmd "open-onboarding"
    if wait_until 3000 kv_contains openWindows onboarding; then onboarding="yes"; fi
    sleep 0.5
    take_snapshot "06-onboarding"
    send_cmd "close-windows"
    local closeResult="$CMD_RESULT"
    wait_until 2000 kv_eq openWindows ""
    if [ "$settings" = "yes" ] && [ "$onboarding" = "yes" ]; then
        pass "settings and onboarding windows opened and closed ($closeResult; openWindows now '$(kv openWindows)')"
    else
        fail "expected openWindows to include settings (got $settings) and onboarding (got $onboarding); openWindows='$(kv openWindows)' | $(state)"
    fi
}

# ---------------------------------------------------------------------------
# Security: App Lock (driver commands `lock` / `unlock-for-test`, DEBUG + UITEST only)
# and the link-preview network gate.
# ---------------------------------------------------------------------------

item_count_above() { [ "$(num "$(kv itemCount)")" -gt "$1" ]; }
cards_visible() { [ "$(num "$(kv visibleCardCount)")" -gt 0 ]; }

# w1: `lock` → status locked=true, appLockEnabled=true, item text redacted.
sc_lock() {
    send_cmd "hide" >/dev/null
    if ! send_cmd "lock"; then
        fail "lock command: $CMD_STATUS $CMD_RESULT | $(state)"
        return
    fi
    if ! wait_until 2000 kv_eq locked true; then
        fail "expected locked=true within 2s of 'lock' ($CMD_RESULT) | $(state)"
        return
    fi
    if kv_eq appLockEnabled true && kv_eq itemsRedacted true && kv_eq items.0.plainText "$REDACTED"; then
        pass "locked=true after ${WAIT_MS}ms; appLockEnabled=true; items redacted (items.0.plainText='$(kv items.0.plainText)', lastCapturedTextPrefix='$(kv lastCapturedTextPrefix)'); windowsHiddenFromCapture=$(kv windowsHiddenFromCapture) (off in test mode by design)"
    else
        fail "locked=true but appLockEnabled=$(kv appLockEnabled) itemsRedacted=$(kv itemsRedacted) items.0.plainText='$(kv items.0.plainText)' | $(state)"
    fi
}

# w2: the hotkey path (show) still opens the panel while locked, but it renders no cards.
sc_locked_panel() {
    if ! kv_eq locked true; then
        fail "precondition: ClipSync is not locked (did w1 fail?) | $(state)"
        return
    fi
    send_cmd "show"
    if ! wait_until 1000 kv_eq panelVisible true; then
        fail "panel did not open while locked: $CMD_STATUS $CMD_RESULT | $(state)"
        return
    fi
    sleep 0.4
    if kv_eq visibleCardCount 0 && kv_eq rows.0.text "" && kv_eq locked true; then
        pass "panel open while locked: visibleCardCount=0, no rows in status (lock screen only)"
    else
        fail "expected visibleCardCount=0 and no rows while locked; got visibleCardCount=$(kv visibleCardCount) rows.0.text='$(kv rows.0.text)' | $(state)"
    fi
}

# w3: every content command is refused with "locked"; the pasteboard is untouched.
sc_locked_refuses() {
    if ! kv_eq locked true; then
        fail "precondition: ClipSync is not locked | $(state)"
        return
    fi
    local pb_before results="" bad="" c
    pb_before="$(pbpaste)"
    for c in "select 0" "paste" "paste-plain" "copy" "search e2e" "delete"; do
        send_cmd "$c"
        results="$results [$c: $CMD_STATUS $CMD_RESULT]"
        if [ "$CMD_STATUS" != "err" ]; then
            bad="$bad '$c' status=$CMD_STATUS;"
            continue
        fi
        case "$CMD_RESULT" in
            *locked*) ;;
            *) bad="$bad '$c' result has no 'locked';" ;;
        esac
    done
    local pb_same="no"
    if [ "$(pbpaste)" = "$pb_before" ]; then pb_same="yes"; fi
    if [ -z "$bad" ] && [ "$pb_same" = "yes" ] && kv_eq visibleCardCount 0; then
        pass "all refused with 'locked'; pasteboard unchanged;$results"
    else
        fail "expected err + 'locked' for every command and an unchanged pasteboard (same=$pb_same); problems:$bad$results | $(state)"
    fi
}

# w4: capture keeps running while locked, but the status never exposes the new text.
sc_locked_capture() {
    if ! kv_eq locked true; then
        fail "precondition: ClipSync is not locked | $(state)"
        return
    fi
    local before
    before="$(num "$(kv itemCount)")"
    copy_text "$LOCKED_TEXT"
    if ! wait_until 5000 item_count_above "$before"; then
        fail "expected itemCount > $before within 5s (capture must continue while locked) | $(state)"
        return
    fi
    local ms=$WAIT_MS
    sleep 0.5
    local leaked="no"
    if grep -qF "$LOCKED_TEXT" "$KV" 2>/dev/null || grep -qF "$LOCKED_TEXT" "$JSON" 2>/dev/null; then
        leaked="yes"
    fi
    if [ "$leaked" = "no" ] && kv_eq items.0.plainText "$REDACTED" && kv_eq lastCapturedTextPrefix "$REDACTED" && kv_eq visibleCardCount 0; then
        pass "captured while locked after ${ms}ms (itemCount ${before}→$(kv itemCount)); text absent from status.kv/status.json; visibleCardCount=0"
    else
        fail "expected the copy to be captured but redacted: leaked=$leaked items.0.plainText='$(kv items.0.plainText)' lastCapturedTextPrefix='$(kv lastCapturedTextPrefix)' visibleCardCount=$(kv visibleCardCount) | $(state)"
    fi
}

# w5: `unlock-for-test` (test hook, no system prompt) brings the cards back.
sc_unlock_for_test() {
    if ! send_cmd "unlock-for-test"; then
        fail "unlock-for-test command: $CMD_STATUS $CMD_RESULT | $(state)"
        return
    fi
    if ! wait_until 2000 kv_eq locked false; then
        fail "expected locked=false after unlock-for-test ($CMD_RESULT) | $(state)"
        return
    fi
    restore_panel_state
    if wait_until 2000 cards_visible && wait_until 2000 kv_eq items.0.plainText "$LOCKED_TEXT"; then
        pass "unlocked: visibleCardCount=$(kv visibleCardCount); the item captured while locked is newest and readable again; appLockEnabled=$(kv appLockEnabled)"
    else
        fail "expected cards and items.0.plainText='$LOCKED_TEXT' after unlocking; got visibleCardCount=$(kv visibleCardCount) items.0.plainText='$(kv items.0.plainText)' | $(state)"
    fi
    send_cmd "hide" >/dev/null
}

# x: with link previews off (the default) copying a web link makes no fetch.
sc_no_link_fetch() {
    copy_text "$LINK_NOFETCH"
    if ! wait_until 5000 kv_eq items.0.plainText "$LINK_NOFETCH"; then
        fail "expected newest plainText='$LINK_NOFETCH' within 5s | $(state)"
        return
    fi
    sleep 1.5   # enrichment runs asynchronously after capture
    if kv_eq linkPreviewsEnabled false && kv_eq linkFetchAttempts 0 && kv_eq items.0.kind link; then
        pass "kind=link, linkPreviewsEnabled=false, linkFetchAttempts=0 (no network request for link previews this run)"
    else
        fail "expected linkPreviewsEnabled=false and linkFetchAttempts=0; got linkPreviewsEnabled=$(kv linkPreviewsEnabled) linkFetchAttempts=$(kv linkFetchAttempts) kind=$(kv items.0.kind) | $(state)"
    fi
}

# "M:SS.ss" or "H:MM:SS.ss" → seconds
cpu_seconds() {
    printf '%s' "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf("%.2f", s) }'
}

sc_idle_cpu() {
    send_cmd "hide" >/dev/null
    sleep 5
    local samples="" i=0 t0 t1
    t0="$(ps -o time= -p "$APP_PID" 2>/dev/null | tr -d ' ')"
    while [ "$i" -lt 10 ]; do
        samples="$samples $(ps -o %cpu= -p "$APP_PID" 2>/dev/null | tr -d ' ')"
        sleep 1
        i=$(( i + 1 ))
    done
    t1="$(ps -o time= -p "$APP_PID" 2>/dev/null | tr -d ' ')"
    if [ -z "$(printf '%s' "$samples" | tr -d ' ')" ]; then
        fail "ps returned no %cpu samples for pid $APP_PID"
        return
    fi
    local average delta
    average="$(printf '%s\n' $samples | avg)"
    delta="$(awk -v a="$(cpu_seconds "$t0")" -v b="$(cpu_seconds "$t1")" 'BEGIN { printf("%.2f", (b - a) * 10) }')"
    local detail="ps %cpu samples:$samples → average ${average}% (CPU time ${t0}→${t1} ≈ ${delta}% over 10 s); debug build, panel hidden. The plan's 0.5% target applies to release builds."
    if lt "$average" 2; then
        pass "$detail"
    else
        fail "expected average < 2%; $detail"
    fi
}

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

json_str() {
    printf '%s' "$1" \
        | tr '\t\r' '  ' \
        | tr -d '\001-\010\013\014\016-\037' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | awk 'BEGIN { ORS = "" } NR > 1 { print "\\n" } { print }'
}

md_cell() {
    printf '%s' "$1" | tr '\n\r\t' '   ' | sed -e 's/|/\\|/g'
}

STARTED_AT="$(iso_now)"
RESULTS_WRITTEN="no"
write_results() {
    local finished passed=0 failed=0 skipped=0 i=0
    finished="$(iso_now)"
    while [ "$i" -lt "$N" ]; do
        case "${S_STATUS[$i]}" in
            PASS) passed=$(( passed + 1 )) ;;
            FAIL) failed=$(( failed + 1 )) ;;
            *) skipped=$(( skipped + 1 )) ;;
        esac
        i=$(( i + 1 ))
    done
    local appVersion macVersion
    appVersion="$(kv appVersion)"
    macVersion="$(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"

    {
        echo "{"
        echo "  \"passed\": $passed,"
        echo "  \"failed\": $failed,"
        echo "  \"skipped\": $skipped,"
        echo "  \"appVersion\": \"$(json_str "${appVersion:-unknown}")\","
        echo "  \"macOSVersion\": \"$(json_str "$macVersion")\","
        echo "  \"startedAt\": \"$STARTED_AT\","
        echo "  \"finishedAt\": \"$finished\","
        echo "  \"runId\": \"$RUN_ID\","
        echo "  \"appPid\": \"$(json_str "${APP_PID:-}")\","
        echo "  \"accessibilityGranted\": \"$(json_str "$(kv accessibilityGranted)")\","
        echo "  \"scenarios\": ["
        i=0
        while [ "$i" -lt "$N" ]; do
            local sep=","
            if [ $(( i + 1 )) -eq "$N" ]; then sep=""; fi
            printf '    {"id": "%s", "name": "%s", "status": "%s", "detail": "%s", "ms": %s}%s\n' \
                "$(json_str "${S_ID[$i]}")" "$(json_str "${S_NAME[$i]}")" "${S_STATUS[$i]}" \
                "$(json_str "${S_DETAIL[$i]}")" "$(num "${S_MS[$i]}")" "$sep"
            i=$(( i + 1 ))
        done
        echo "  ]"
        echo "}"
    } > "$RESULTS.tmp" && mv "$RESULTS.tmp" "$RESULTS"

    {
        echo "# ClipSync macOS E2E report"
        echo
        echo "- Result: **$passed passed, $failed failed, $skipped skipped**"
        echo "- App: ${appVersion:-unknown} (pid ${APP_PID:-?}), macOS $macVersion"
        echo "- Run: $RUN_ID, $STARTED_AT → $finished"
        echo "- Accessibility granted: $(kv accessibilityGranted)"
        echo "- Files: results.json, status.json, status.kv, commands.log, e2e.log, shots/"
        echo
        echo "| id | scenario | status | ms | detail |"
        echo "|---|---|---|---|---|"
        i=0
        while [ "$i" -lt "$N" ]; do
            echo "| ${S_ID[$i]} | $(md_cell "${S_NAME[$i]}") | ${S_STATUS[$i]} | ${S_MS[$i]} | $(md_cell "${S_DETAIL[$i]}") |"
            i=$(( i + 1 ))
        done
        echo
        echo "## Failures"
        echo
        i=0
        local any="no"
        while [ "$i" -lt "$N" ]; do
            if [ "${S_STATUS[$i]}" = "FAIL" ]; then
                any="yes"
                echo "### ${S_ID[$i]} — ${S_NAME[$i]}"
                echo
                echo '```'
                echo "${S_DETAIL[$i]}"
                echo '```'
                echo
            fi
            i=$(( i + 1 ))
        done
        if [ "$any" = "no" ]; then echo "None."; echo; fi
        echo "## Not covered"
        echo
        echo "- Persistence across relaunch (UITEST mode uses an in-memory store)"
        echo "- iCloud sync"
        echo "- Global hotkey press (the test calls show/hide directly)"
        echo "- Real ⌘V without Accessibility (impossible by design: paste falls back to copy-only, see o2)"
        echo "- Quick Look"
        echo
        echo "## Snapshots"
        echo
        (cd "$SHOTS" 2>/dev/null && ls *.png 2>/dev/null) | while read -r f; do
            echo "- shots/$f"
        done
        echo
        echo "## Final status.json"
        echo
        echo '```json'
        cat "$JSON" 2>/dev/null
        echo '```'
    } > "$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"

    RESULTS_WRITTEN="yes"
    FINAL_FAILED=$failed
    log "results: $passed passed, $failed failed, $skipped skipped → $RESULTS"
}

# ---------------------------------------------------------------------------
# Clipboard save / restore (text only, best effort; never stored under build/)
# ---------------------------------------------------------------------------

SAVED_CLIP="$(mktemp /tmp/clipsync-e2e-clip.XXXXXX 2>/dev/null || echo "")"
if [ -n "$SAVED_CLIP" ]; then
    pbpaste > "$SAVED_CLIP" 2>/dev/null
fi

restore_clipboard() {
    [ -n "$SAVED_CLIP" ] && [ -f "$SAVED_CLIP" ] || return 0
    if [ -s "$SAVED_CLIP" ]; then
        # Pause capture so the user's own clipboard text never enters the test store/status files.
        local paused="no"
        if app_alive && send_cmd "pause-capture" 5; then paused="yes"; fi
        pbcopy < "$SAVED_CLIP"
        if [ "$paused" = "yes" ]; then
            sleep 1.2
            send_cmd "resume-capture" 5 >/dev/null
        fi
        log "clipboard text restored (capture paused during restore: $paused)"
    fi
    rm -f "$SAVED_CLIP"
    SAVED_CLIP=""
}

FINAL_FAILED=0
finish() {
    restore_clipboard
    rm -f "$FILE_A" "$FILE_B"
    if [ "$RESULTS_WRITTEN" != "yes" ]; then
        write_results
    fi
}
trap finish EXIT
trap 'log "interrupted"; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "ClipSync E2E run $RUN_ID in $E2E"

if wait_until 15000 test -f "$KV"; then
    log "driver status file present after ${WAIT_MS}ms"
else
    record "driver" "E2E driver active" "FAIL" "status.kv never appeared in $E2E within 15s: the app was not launched with CLIPSYNC_UITEST=1 CLIPSYNC_E2E_DIR=$E2E, or the build does not contain macOS/App/E2E/E2EDriver.swift (regenerate the project), or it crashed (see build/logs/run-mac.log)" 15000
    exit 1
fi
if [ -z "$APP_PID" ]; then
    APP_PID="$(kv pid)"
fi
if send_cmd "ping" 10; then
    record "driver" "E2E driver active" "PASS" "pid $(kv pid), version $(kv appVersion), command round trip ${CMD_MS}ms, accessibilityGranted=$(kv accessibilityGranted)" "$CMD_MS"
else
    record "driver" "E2E driver active" "FAIL" "ping: $CMD_STATUS $CMD_RESULT" "$CMD_MS"
    exit 1
fi

build_pbtool
send_cmd "hide" >/dev/null
send_cmd "resume-capture" >/dev/null
sleep 0.5

run_scenario "a" "capture plain text" sc_capture_text
run_scenario "b" "dedup re-copy" sc_dedup
run_scenario "c" "link classification" sc_link
run_scenario "d" "color classification" sc_color
run_scenario "e" "rich text (RTF + plain)" sc_rich
run_scenario "f" "image (400x300 PNG)" sc_image
run_scenario "g" "files (two file URLs, Finder-style items)" sc_files
run_scenario "g2" "files (two file URLs via writeObjects NSURL)" sc_files_nsurl
run_scenario "g3" "files round trip (store -> PasteboardWriter -> 2 items)" sc_files_roundtrip
run_scenario "h" "password safety: ConcealedType" sc_concealed
run_scenario "h2" "password safety: TransientType" sc_transient
run_scenario "i" "pause / resume capture" sc_pause
run_scenario "j" "panel show" sc_panel_show
restore_panel_state
take_snapshot "01-panel"
run_scenario "k" "search" sc_search
restore_panel_state "search $UNIQ"
wait_until 2000 visible_one_with "$UNIQ"
take_snapshot "02-search"
send_cmd "clear-search" >/dev/null
wait_until 1000 kv_eq panelSearchText ""
run_scenario "l" "keyboard navigation" sc_navigation
run_scenario "m" "copy action (⌘C path)" sc_copy
run_scenario "p" "pin + pinboards" sc_pinboard
run_scenario "q" "delete selected" sc_delete
run_scenario "r" "kind filter: images" sc_filters
run_scenario "v" "copied image exposes no internal types" sc_image_copy_types
textedit_setup
run_scenario "n" "paste as plain text (⇧↩ path)" sc_paste_plain
run_scenario "o" "real paste into TextEdit (↩ path)" sc_paste_real
run_scenario "o2" "paste falls back to copy without Accessibility" sc_paste_fallback
textedit_cleanup
run_scenario "s" "scale: 2,000 seeded items" sc_scale
run_scenario "t" "settings + onboarding windows" sc_windows
run_scenario "w1" "app lock: lock command" sc_lock
run_scenario "w2" "app lock: panel shows no cards while locked" sc_locked_panel
take_snapshot "07-locked"
run_scenario "w3" "app lock: paste/copy/select refused while locked" sc_locked_refuses
run_scenario "w4" "app lock: capture continues, status redacted" sc_locked_capture
run_scenario "w5" "app lock: unlock-for-test restores content" sc_unlock_for_test
run_scenario "x" "link previews off: no fetch for a copied URL" sc_no_link_fetch
run_scenario "u" "idle CPU (panel hidden)" sc_idle_cpu

send_cmd "hide" >/dev/null
restore_clipboard
if ! ax_granted_now; then
    # Makes macOS add ClipSync to the Accessibility list (system dialog; done last on purpose).
    send_cmd "request-ax-prompt" 10
    log "Accessibility prompt: $CMD_STATUS $CMD_RESULT"
fi
write_results
if [ "$FINAL_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
