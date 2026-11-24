# ClipSync

A local-first clipboard manager for macOS and iOS. Copy as usual, press a hotkey, and your clipboard history slides up as a strip of cards you can search, pin and paste from.

Everything stays on your device. There are no accounts, no servers and no analytics.

## What it does

**Mac app (macOS 14 or later)**

- Saves what you copy: text, rich text, links, images, files, PDFs and colors.
- Press **Shift + Command + V** to open the history panel on the screen you are working on.
- Type to search, use the arrow keys to move, **Return** to paste into the app you were in, **Shift + Return** to paste as plain text.
- Pinboards for things you paste often.
- Never saves items from password managers (1Password, Bitwarden, Keychain Access) or anything apps mark as concealed. You can add your own ignored apps and pause capture.
- Settings for the hotkey, how long history is kept, and launch at login.

**iPhone and iPad app (iOS 17 or later)**

- History list or grid, search, filters, pinboards, swipe to pin or delete, tap to copy.
- A "Save clipboard" button, a Share Extension and Shortcuts actions. iOS does not let apps watch the clipboard in the background, so items are saved when you ask.

## Build it on your Mac

You need a Mac with **Xcode 16 or later** and [Homebrew](https://brew.sh).

```sh
git clone https://github.com/nebullii/ClipSync.git
cd ClipSync
./scripts/bootstrap.sh      # installs XcodeGen if needed and creates ClipSync.xcodeproj
./scripts/build.sh mac      # builds the Mac app into ./build
open build/DerivedData/Build/Products/Debug/ClipSync.app
```

Or open `ClipSync.xcodeproj` in Xcode, pick the **ClipSyncMac** scheme and press Run.

On first launch the app asks for **Accessibility** permission (System Settings > Privacy & Security > Accessibility). It needs this to paste into other apps for you. Without it, ClipSync still copies the item to your clipboard and you press Command + V yourself.

No Apple Developer account is needed for a local build. The app is signed to run on your own Mac only.

### iOS app

```sh
./scripts/build.sh ios          # builds for the iOS Simulator
./scripts/build.sh ios-sim-run  # installs, launches with sample data and runs the UI tests
```

Running on a real iPhone needs your own Apple ID selected as the team in Xcode.

## Tests

```sh
./scripts/build.sh core-test    # unit tests for the shared package
./scripts/build.sh run-mac      # launches the Mac app in test mode and runs the end-to-end scenarios
./scripts/build.sh ios-sim-run  # iOS UI tests in the Simulator
```

`run-mac` uses the real clipboard and opens TextEdit while it runs. It saves your clipboard text first and puts it back at the end. Results are written to `build/e2e/report.md`.

## Privacy and security

- History is stored only in your user account's Application Support folder.
- iCloud sync is included in the code but is **off**. It only works in a build signed with a paid Apple Developer team; see `docs/ICLOUD_SETUP.md` if you want it.
- The test hooks (`CLIPSYNC_UITEST`, `CLIPSYNC_E2E_DIR`) do nothing unless you set those environment variables yourself.

## Project layout

```
Packages/ClipCore   shared model, storage, search, capture rules, media, Shortcuts actions, unit tests
macOS/              menu bar app: clipboard monitor, panel, paste service, settings, onboarding
iOS/                iPhone and iPad app
ShareExtension/     iOS share sheet extension
iOSUITests/         iOS UI tests
scripts/            bootstrap, build and end-to-end test scripts
project.yml         XcodeGen project definition
```

## Status

This is an early build. Known gaps: no auto-update, no notarized download, iCloud sync untested on real devices.
