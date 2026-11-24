#!/bin/bash
# Checks the toolchain, installs XcodeGen if missing (Homebrew), generates ClipSync.xcodeproj.
# Usage: scripts/bootstrap.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

echo "==> ClipSync bootstrap in $ROOT"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild not found. Install Xcode 16+ from the App Store, then run:" >&2
    echo "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

if ! XCODE_VERSION="$(xcodebuild -version 2>&1)"; then
    echo "error: xcodebuild -version failed:" >&2
    echo "$XCODE_VERSION" >&2
    echo "       (Command Line Tools alone are not enough; select a full Xcode with xcode-select -s)" >&2
    exit 1
fi
echo "$XCODE_VERSION"

XCODE_MAJOR="$(echo "$XCODE_VERSION" | head -n 1 | sed -E 's/^Xcode ([0-9]+).*/\1/')"
case "$XCODE_MAJOR" in
    ''|*[!0-9]*) echo "warning: could not parse the Xcode version" ;;
    *)
        if [ "$XCODE_MAJOR" -lt 16 ]; then
            echo "error: Xcode 16 or newer is required (found $XCODE_MAJOR)." >&2
            exit 1
        fi
        ;;
esac

if ! command -v xcodegen >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "==> Installing XcodeGen with Homebrew"
        if ! brew install xcodegen; then
            echo "error: brew install xcodegen failed" >&2
            exit 1
        fi
    else
        echo "error: xcodegen is not installed and Homebrew is not available." >&2
        echo "       Install Homebrew (https://brew.sh) or XcodeGen (https://github.com/yonaskolb/XcodeGen)." >&2
        exit 1
    fi
fi
echo "==> $(xcodegen --version 2>&1 | head -n 1)"

echo "==> xcodegen generate"
if ! xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"; then
    echo "error: xcodegen generate failed" >&2
    exit 1
fi

echo "==> Done. Open ClipSync.xcodeproj, or run scripts/build.sh all"
exit 0
