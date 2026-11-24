# ClipSync security and privacy

ClipSync records what you copy. That can be anything: passwords someone forgot to mark,
addresses, private messages, API keys. This page says plainly what ClipSync does to protect
that history, what it does not do, and what every security setting does.

ClipSync does **not** encrypt your history itself. On disk it is protected by the operating
system: FileVault on the Mac, Data Protection on iPhone and iPad.

## What is protected, and against what

| Threat | Protection | Where |
|---|---|---|
| Someone using your unlocked Mac or iPhone for a moment, or looking over your shoulder | **App Lock** (off by default). While locked, the history panel / app shows only a lock screen. Touch ID, Face ID or Optic ID, with your Mac password or device passcode as the fallback. | Mac, iOS |
| Locked history reached some other way | While locked these are blocked: the menu-bar "recent items" list and its quick copy, ⌘1–9 and 1–9 paste shortcuts, Return / ⇧Return paste, ⌘C copy, Quick Look (Space), dragging cards out, search, and every Shortcuts / App Intents action that reads history ("Search ClipSync", "Copy Latest", "Copy Clip", clip pickers). Those actions fail with "ClipSync is locked." Saving new items ("Save Clipboard", "Save Text", the share sheet) still works while locked. | Mac, iOS |
| Walking away | ClipSync locks after the chosen time, and on the Mac also when the screen locks, the Mac or its display sleeps, or you switch users; on iOS when the device locks. The timeout uses a monotonic clock that keeps counting during sleep and ignores changes to the wall clock. | Mac, iOS |
| App-switcher snapshots | An opaque ClipSync cover replaces the window whenever the app is inactive or in the background, so the snapshot iOS takes never shows clips. | iOS |
| Screen sharing / recording | "Hide ClipSync from screen recording and screen sharing" (on by default) sets `NSWindow.sharingType = .none` on every ClipSync window, including the panel and its Quick Look preview. Most capture apps respect this; macOS does not guarantee it for every capture method. Menus are drawn by macOS and are **not** covered: the menu-bar menu (up to 5 recent item titles while unlocked) and right-click menus can appear in a recording. | Mac |
| Password managers | Copies marked by the source app as concealed, transient or auto-generated (`org.nspasteboard.*`), and the vendor markers `com.agilebits.onepassword`, `de.petermaurer.TransientPasteboardType`, `Pasteboard generator type`, `com.typeit4me.clipping`, `net.antelle.keeweb`, are never recorded. Copies from 1Password, Bitwarden, Dashlane, Enpass, KeePassXC, Keychain Access, LastPass, Passwords, Proton Pass and Strongbox are ignored by default. | Mac (iOS: share sheet / Shortcuts check the same markers) |
| Other user accounts on the same Mac | The data folder is created with owner-only permissions (folders 0700, files 0600), so other macOS users can't read it. | Mac, iOS |
| Network leakage | ClipSync makes no network requests of its own unless you turn something on: link previews are off by default, and iCloud sync is off unless you turn it on (and only exists in signed builds). There are no ClipSync servers, accounts, analytics or crash reporters. | Mac, iOS |
| Logs | ClipSync never writes clipboard content to the system log. It logs only counts, skip reasons and errors. | Mac |

## What is NOT protected

- **Malware or any app running as your user account.** It can read ClipSync's files (and
  the clipboard itself) directly. App Lock is an access gate inside ClipSync's own UI and
  Shortcuts actions. It is not encryption, and it can't stop other software.
- **Someone who knows your login password or passcode.** They can unlock ClipSync, just as
  they can unlock the device.
- **A Mac without FileVault.** Without FileVault the disk isn't encrypted, so anyone with
  physical access to the disk can read the history database. Turn FileVault on in System
  Settings › Privacy & Security › FileVault (Settings › Security has a button for this).
- **Backups.** Time Machine and other backup tools copy ClipSync's folder like the rest of
  your Library. On iOS, the history is part of device backups. Encrypt your backups if that
  matters to you. ClipSync does not exclude itself from backups.
- **iOS while unlocked once since restart.** To let the share sheet, Shortcuts and iCloud
  sync save clips while the device is locked, the store uses Data Protection class
  `completeUntilFirstUserAuthentication`. After a restart the files stay encrypted until
  the first unlock. After that, iOS can open them for ClipSync even while the device is
  locked. (`.complete` would break those background writes: SQLite would fail to open the
  database.)
- **Deleted items on disk.** Deleting items (or clearing history) removes the database
  rows and blob files. The database engine may keep fragments in free pages until it
  reuses them. FileVault / Data Protection still encrypts those.
- **Quick Look of copied HTML.** Pressing Space on a rich-text item copied from a web page
  hands its HTML to macOS Quick Look. Quick Look, not ClipSync, decides whether to load
  images that the HTML refers to. Nothing else in ClipSync renders HTML. Cards parse only RTF
  and plain text.
- **Capture while locked.** Capture keeps running while ClipSync is locked, and everything
  you copy is still saved. Use Pause Capture to stop recording.
- **Non-content actions while locked.** Someone at your unlocked Mac can still pause
  capture, clear history (after a confirmation) or open Settings while ClipSync is
  locked. None of these show clipboard content. Turning App Lock off needs authentication.
- **Devices with no passcode / password.** App Lock can't be turned on there. If the
  passcode is removed while App Lock is on, nobody can be verified any more, so ClipSync
  unlocks (with a message saying so) rather than locking you out of your own history.

## Where the data lives

- Mac, unsigned/Debug builds: `~/Library/Application Support/ClipSync/` (database, `Blobs/`
  for payloads over 256 KB, SwiftData external-storage files).
- Mac, signed builds: `~/Library/Group Containers/group.com.thingbits.clipsync/ClipSync/`.
- iOS: the App Group container's `ClipSync/` folder (shared with the share extension).
- Permissions are tightened at every launch and after the database opens
  (`StoreFileProtection.protectTree`). This is best effort, so a failure is ignored and
  never blocks the app. Blob files get 0600 when they are written.

## Settings and defaults

| Setting (key) | Default | Platform | Notes |
|---|---|---|---|
| App Lock (`clipsync.appLockEnabled`) | **Off** | Mac, iOS | Turning it on **and** off each require a successful authentication. Turning it on is refused (with a message) when the device has no password/passcode. Not changed by "reset to defaults". In `CLIPSYNC_UITEST` / `-uitest-seed` mode the settings are wiped, so it is off. |
| Lock after (`clipsync.lockTimeout`) | **After 5 minutes** | Mac, iOS | Immediately / 1 min / 5 min / 15 min / 1 hour, counted from when the history was last hidden (Mac panel closed, iOS app backgrounded) or used. "Immediately" locks as soon as it is hidden. |
| Hide ClipSync from screen recording and screen sharing (`clipsync.hideFromScreenCapture`) | **On** | Mac | Always off in `CLIPSYNC_UITEST` mode, because the E2E harness renders windows in-process. |
| Hide content in the app switcher (`clipsync.privacyCoverEnabled`) | **On** | iOS | Never shown in `-uitest-seed` mode. |
| Fetch link titles and icons — contacts the linked website (`clipsync.linkPreviewsEnabled`) | **Off** | Mac, iOS | The only network use apart from iCloud. With it off, `ClipStore.enrich` never calls the link fetcher (unit test `LinkPreviewGateTests`; E2E scenario `x` checks `linkFetchAttempts=0`). |
| Clear history when I quit ClipSync (`clipsync.clearHistoryOnQuit`) | **Off** | Mac | On a normal quit, deletes unpinned items with their blobs/thumbnails. Pinned and pinboard items are kept, as with Clear History. It doesn't run on a force quit or crash. With iCloud sync on, the deletion syncs. |
| Always ignore password managers (`ignoreRules.includeDefaults`) | **On** | Mac | See the list above. |
| iCloud sync (`clipsync.cloudSyncEnabled`) | Off (On only in a Signed build that can use CloudKit, until changed) | Mac, iOS | Unchanged by this pass. |

## How the test hooks are fenced off

- **Mac E2E driver** (`macOS/App/E2E/E2EDriver.swift`): the whole file is inside `#if DEBUG`,
  and so are its start call and property in `AppController`. Release and Signed builds
  contain no file-command channel. In a Debug build it starts only when **both**
  `CLIPSYNC_UITEST=1` and an absolute `CLIPSYNC_E2E_DIR` are set (`LaunchOptions`).
  `CLIPSYNC_UITEST=1` also swaps in an in-memory store and wiped settings, so the driver
  never sees real history.
- **Status file** (`StatusFileWriter`): enabled only in DEBUG builds and only with
  `CLIPSYNC_UITEST=1` **and** `CLIPSYNC_STATUS_FILE=1`. The `writeStatus()` call site is
  inside `#if DEBUG`. While locked it redacts captured text.
- **App Lock test hooks** (`AppLockController.enableForTesting()` /
  `unlockAndDisableForTesting()`): inside `#if DEBUG` in ClipCore. Only the E2E driver
  calls them, through the `lock` and `unlock-for-test` commands. While locked, the driver
  refuses every content command with "locked" and redacts item text in `status.kv` /
  `status.json`.
- `scripts/build.sh run-mac` always runs the E2E suite against the Debug build. With
  `signing.local` it builds Signed as usual, then also builds the unsigned Debug app for
  the E2E run.
- iOS has no driver. `-uitest-seed` gives an in-memory store and wiped settings (App Lock
  off, no privacy cover).
