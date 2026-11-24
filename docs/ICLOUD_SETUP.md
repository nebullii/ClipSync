# Turning on iCloud sync: owner checklist

ClipSync has no username or password. Your "login" is the Apple Account that is already
signed in to iCloud on each Mac, iPhone and iPad. ClipSync stores history in your own
private iCloud database; nothing goes to any other server.

**Where things stand today:** every build is unsigned, so iCloud cannot work yet. The app
says so in Settings › Sync on the Mac and in Settings › iCloud on iPhone ("iCloud not
available in this build"). Everything else works on each device by itself.

## 1. One-time setup (about 30 minutes, plus Apple's approval time)

1. **Join the Apple Developer Program** at developer.apple.com/programs (paid, yearly).
   Wait for the "Welcome" email. This can take from a few hours to a couple of days.
2. **Sign in to Xcode:** Xcode › Settings › Accounts › "+" › Apple ID, then sign in
   with the same Apple ID you used to enrol.
3. **Find your Team ID:** in the same Accounts screen, select your team. It is also
   shown at developer.apple.com › Account › Membership details. It is 10 letters and
   digits, for example `A1B2C3D4E5`.
4. **Put the Team ID in one file:** in the ClipSync folder, copy `signing.local.example`
   to `signing.local` and replace `XXXXXXXXXX` with your Team ID. That is the only
   setting. (The file stays on your Mac; it is never committed.)
5. **Build:** run `scripts/build.sh mac` and `scripts/build.sh ios` as usual. The log
   now says `signing mode: SIGNED`. On the first signed build, Xcode registers the app
   IDs, the App Group `group.com.thingbits.clipsync` and the iCloud container
   `iCloud.com.thingbits.clipsync` for your team. If the build stops with a signing
   or "container" error, open `ClipSync.xcodeproj`, pick the target, open Signing &
   Capabilities, select your team, and in the iCloud section tick
   `iCloud.com.thingbits.clipsync` (or press "+" to create it), then build again.
6. **macOS asks again for Accessibility:** a signed app counts as a new app. Allow
   ClipSync again in System Settings › Privacy & Security › Accessibility.

In a signed build, iCloud sync is **on by default** the first time ClipSync opens.
If you switched it off earlier, switch it on in Settings and relaunch ClipSync.

## 2. On every device

1. Sign in to iCloud with **the same Apple Account** on each device
   (Mac: System Settings › your name; iPhone: Settings › your name).
2. Make sure iCloud Drive is on for that account.
3. Open ClipSync › Settings. The iCloud row should be green: **"Syncing with iCloud"**.
   If it says "Relaunch to apply", relaunch ClipSync.

To run the iOS app on a real iPhone (not the Simulator), open `ClipSync.xcodeproj` in
Xcode, choose the `ClipSyncIOS` scheme, the **Signed** configuration
(Product › Scheme › Edit Scheme › Run › Build Configuration) and your iPhone, then Run.
The Simulator can also sync if you sign in to iCloud inside the Simulator's Settings app.

## 3. The test

1. On the Mac, copy a short, unique sentence (for example "sync test 1, Tuesday").
2. Open ClipSync on the iPhone and keep it open. Within about 10 seconds the sentence
   should appear at the top of History. Pull down to refresh if it does not.
3. Do it the other way: on the iPhone tap Paste in ClipSync, then check the Mac panel.
4. Pin an item on one device; it should show as pinned on the other.

The **first** sync on a new device can take several minutes. Later changes normally
arrive in seconds, but iCloud does not guarantee timing (Low Power Mode, poor networks
and a backgrounded iPhone all slow it down).

## 4. If it goes wrong

- **Nothing appears after 10 minutes:** check that both devices show the green
  "Syncing with iCloud" row, the same Apple Account, and a working network. Relaunch
  ClipSync on both. On the Mac, check Console.app for messages from "ClipSync" that
  mention CloudKit.
- **Items appear twice, or disappear:** stop testing and write down what you did. This
  is the project's go/no-go point: if SwiftData's automatic iCloud sync duplicates or
  drops items, the plan is to switch the sync layer to GRDB + CKSyncEngine
  (estimated 2 to 3 extra weeks). Nothing is lost locally in the meantime.
- **To go back to unsigned builds:** delete `signing.local` and build again.

## Known limits of this build (honest list)

- **Large items stay local:** payloads over 256 KB (most images, PDFs and files) are
  kept on the device that captured them; their row may sync without the content.
  Items over 20 MB never sync.
- **First sync is slow:** minutes, not seconds, for a new device or a big history.
- **CloudKit schema:** before TestFlight or the App Store, the iCloud database schema
  must be deployed from Development to Production in the CloudKit Console
  (icloud.developer.apple.com). Development builds use the Development environment, so
  history synced while testing does not carry over to App Store builds.
- **iCloud account state on iPhone** is checked with CloudKit only in signed builds;
  unsigned builds never call iCloud (doing so would crash), they only say it is unavailable.
- None of the iCloud code could be tested against real iCloud before enrolment.
