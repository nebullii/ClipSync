# ClipSync — Integration notes (pre-first-build pass)

Written by the integration engineer after the Mac services, Mac panel and extensions work
landed, while the iOS engineer is still working in `iOS/` (nothing under `iOS/` was
modified). **Nothing here has been through a compiler**: this is a desk-checked pass
(Linux, no Swift toolchain). Every ClipCore change is additive: new members with defaults,
no renames, no removals, no changed signatures. The one representation change is
`AppSettings.shared`: it was a `static let` and is now a computed `static var` with the same
type and isolation, so every existing call site still reads the same.

---

## 1. What changed, per file

### ClipCore (Foundation-owned, additive)

| File | Change | Why |
|---|---|---|
| `Capture/ClipUTI.swift` | + `ClipUTI.fileURLList` (`com.thingbits.clipsync.file-url-list`), + `ClipUTI.ownWrite` (`com.thingbits.clipsync.own-write`) | Gap A1: both identifiers were private to Mac services. Both use `internalPrefix`, so `isInternal` is true: excluded from `pasteableRepresentations`, `pasteboardPayload(for:)`, the content hash and `SystemPasteboard.write`. |
| `Capture/ClipFileList.swift` (new) | `ClipFileList.encode/decode/decode(text:)/url(fromLine:)` + `ClipStore.fileURLs(for:)` | Gap A1: ONE pinned multi-file format (UTF-8, one absolute `file://` URL per line, `\n`, no trailing newline). The decoder is tolerant: file URLs, absolute paths, NUL / CRLF separators and plist `[String]` (legacy `NSFilenamesPboardType`). `store.fileURLs(for:)` reads `fileURLList`, then every `public.file-url` rep, then the paths in `plainText`. |
| `Capture/TypeNormalizer.swift` | `isStorable(ClipUTI.ownWrite) == false` | The own-write marker should never be stored as a representation, whichever reader picks it up. `fileURLList` stays storable on purpose. |
| `Store/StoreTypes.swift` | + `ClipFilter.kinds: Set<ClipKind>? = nil`, + `init(kinds:pinboardID:searchText:pinnedOnly:limit:offset:)` (where `kinds` has NO default, so overloads can't be ambiguous), + `allows(_:)` | Gap A2. `nil` means no restriction and `[]` matches nothing. If both `kind` and `kinds` are set, the filter uses their intersection. The existing `init(kind:...)` is untouched. |
| `Store/ClipStore.swift` | `fetchItems` honours `kinds`. A one-element set goes into the SQL predicate, through the existing `SearchEngine.predicate(kind:)`. A multi-kind set, like tokens 2…n, is filtered in memory by the new private `fetchFiltered`, which scans the sorted SQL result in batches (≥200) until it has `offset+limit` matches, so paging stays exact. The pinboard path also filters by `kinds`. | Gap A2. The single combined `#Predicate` was NOT made more complex. Before this change, multi-token searches fetched every row; now they are batched too. |
| `Search/SearchEngine.swift` | + `matches(_:kinds:)`, + `sqlKind(kind:kinds:)` | Gap A2: helpers for `@Query` users (iOS) and the store. |
| `Settings/AppSettings.swift` | `shared` is now a lazily created computed property. + `setShared(_:)`, + `ephemeral(suiteName:)` (wipes, then uses an isolated suite; never `.standard`, never the App Group suite), + `allKeys`. Doc comment for `plainTextByDefault` changed to the ⇧↩ decision. | Gap A5. Mirrors `ClipStore.setShared`. |
| `Intents/SystemPasteboard.swift` | The AppKit reader skips `ClipUTI.isInternal` types | So "Save Clipboard" on the Mac never stores ClipSync's own marker. |
| `Tests/ClipCoreTests/IntegrationTests.swift` (new) | Tests for `kinds` union and exact paging, the `ClipFileList` round trip and tolerant decode, `store.fileURLs` (including share-extension style contents-only drafts), and `AppSettings.ephemeral` / `setShared` | |

### Mac services (`macOS/App`, `macOS/Services`)

| File | Change | Why |
|---|---|---|
| `Services/PasteboardReader.swift` | Multi-file copies store `ClipFileList.encode(urls)` under `ClipUTI.fileURLList` (it previously hand-joined absolute strings) | A1: one format. |
| `Services/PasteboardWriter.swift` | `PasteboardMarkers.ownWrite/fileURLList` now alias the `ClipUTI` constants. `fileURLs(for:)` delegates to `store.fileURLs(for:)`. The private `urls(fromLines:)` was removed. | A1. |
| `App/AppController.swift` | UI-test path: `AppSettings.setShared(AppSettings.ephemeral(suiteName: "com.thingbits.clipsync.uitest"))` runs before the in-memory store is created, and the store uses those settings. `.clipSyncOpenSettings` handles `userInfo["tab"]`. | A5, A4. |
| `App/ClipSyncAppIntents.swift` (new) | `ClipSyncAppIntentsPackage: AppIntentsPackage` that includes `ClipCoreAppIntentsPackage` | A6. |
| `App/Settings/GeneralSettingsTab.swift` | Footnote changed to "In the panel, ⇧↩ always pastes as plain text." | A3. |
| 8 files that log through `ServicesLog` | + `import os` | `Logger`'s `privacy:` interpolation should not depend on transitive member visibility. Cheap insurance. |

### Mac panel (`macOS/Panel`)

| File | Change | Why |
|---|---|---|
| `PanelViewModel.swift` | `PanelKindFilter.kind` was replaced by `kinds` (Text = text + richText, Files = file + pdf, the others single). `makeFilter` uses `ClipFilter(kinds:...)`. ↩/⌘N paste uses `wantsPlainText(shiftHeld:settings:) = shiftHeld || plainTextByDefault`. | A2, A3. `kind` was only used inside this file. |
| `ThumbnailLoader.swift` | `PanelFileList` keeps its per-item cache and now just calls `store.fileURLs(for:)`. The format-guessing parser was removed. | A1. Multi-file cards now show every file; before, only the first one appeared because the list rep is internal. |
| `QuickLookSupport.swift` | `.file` items without any URL (iOS share-extension drafts carry the file BYTES under the file's own UTI plus a title) now Quick Look / drag the exported bytes instead of a .txt holding the title | Share-extension check. The card itself was already fine: the title is shown as the fallback, and the footer reads "File · <size>". |
| `ClipCardView.swift`, `PinboardTabsView.swift`, `PanelRootView.swift` | Accessibility-trait / pin-title ternaries are computed in a `let` before the long modifier chains | Lowers type-checker load ("unable to type-check this expression in reasonable time"). |

### Shared / build

| File | Change |
|---|---|
| `macOS/Shared/MacContracts.swift` | Documents `userInfo["tab"]` on `.clipSyncOpenSettings`. + `enum ClipSyncNotificationKey { static let settingsTab = "tab" }` (additive). |
| `project.yml` | Share extension `NSExtensionActivationRule`: + `NSExtensionActivationSupportsFileWithMaxCount: 10`, + `NSExtensionActivationSupportsAttachmentsWithMaxCount: 10`. Re-validated with `python3 yaml.safe_load`. The generated `SupportingFiles/ClipSyncShare/Info.plist` was mirrored and validated with `plistlib`; xcodegen regenerates it anyway. |
| `scripts/build.sh` | `run-mac` launches `ClipSync.app/Contents/MacOS/ClipSync` directly in the background with `CLIPSYNC_UITEST=1 CLIPSYNC_STATUS_FILE=1 CLIPSYNC_SHOW_PANEL=1` (`nohup`, stdin `/dev/null`, output appended to `build/logs/run-mac.log`, liveness check after 2 s). The old `open` call dropped the environment. `stop-mac` sends SIGTERM, waits up to 5 s, then SIGKILL. Checked with `bash -n`. `scripts/watch.sh` and its allow-list are unchanged. |
| `docs/API.md` | §2 ClipUTI + ClipFileList + isStorable, §3 `fileURLs(for:)` + `ClipFilter.kinds`, §4 SearchEngine helpers, §5 AppSettings setShared/ephemeral, §7 intents package, §8 ⇧↩ wording + settings tab key. |

---

## 2. Pinned decisions

- **Multi-file format:** `ClipUTI.fileURLList` = `ClipFileList.encode(urls)`. The Mac reader also keeps
  the first URL as `public.file-url` and all paths as `plainText`. Everyone reads with `store.fileURLs(for:)`.
- **⇧↩:** always pastes as plain text. ↩ follows `plainTextByDefault`. The same holds for ⌘⇧1…9.
- **Kind chips:** All · Text (text + rich text) · Links · Images · Files (files + PDFs) · Colors.
- **Settings deep link:** `NotificationCenter.default.post(name: .clipSyncOpenSettings, object: nil,
  userInfo: [ClipSyncNotificationKey.settingsTab: "privacy"])`.
- **UI-test mode (`CLIPSYNC_UITEST=1`):** in-memory store plus `AppSettings.ephemeral(suiteName:
  "com.thingbits.clipsync.uitest")`. That suite is wiped at every launch. Its plist
  (`~/Library/Preferences/com.thingbits.clipsync.uitest.plist`) can exist between runs, but it
  never holds user data.

---

## 3. Known limitations (not fixed, by design or out of scope)

1. **Main-thread cost of big copies (services gap 3):** confirmed off-main are pasteboard
   reading (`PasteboardReader.read` on a serial utility queue), RTF → text, and the dedup
   SHA-256 (`draft.contentHash = ContentHasher.hash(draft)` in the reader). These still run on
   the main actor inside `ClipStore.ingest`:
   - the SHA-256 that names the blob file (`BlobStore.write`)
   - the blob file write for payloads over 256 KB
   - the SwiftData save

   `ClipStore.enrich` also reads blob bytes on main before handing them to the off-main
   thumbnail/OCR work. A 50–200 MB image can therefore cause a visible hitch. Ingest was NOT
   redesigned. Future fix: an off-main `BlobStore.write` before the main-actor ingest, with
   the draft carrying a pre-written blob name.
2. A multi-kind filter (Text / Files chips) scans SQL rows in batches. That is cheap at the
   panel's page size (60), but it is O(history) for a selective chip with very few matches in
   a 20k-item history.
3. iOS share-extension `.file` items carry bytes, not URLs. On the Mac they paste as that
   UTI's data and Quick Look the exported bytes. They are not real Finder files.
4. App Shortcuts (`ClipSyncShortcuts: AppShortcutsProvider`) live in the ClipCore static
   library. Apple documents App Shortcuts for the main app bundle. If metadata extraction
   warns or Shortcuts shows no phrases, move that provider into each app target (see #4 in
   the failure list below).
5. KeyboardShortcuts stores the user's shortcut in `UserDefaults.standard`, which UI-test mode
   does not isolate. It only affects the hotkey, not capture or the ignore list.
6. `run-mac` always starts in UI-test mode (in-memory history). Use Xcode or `open` for a
   normal run.

---

## 4. iOS App Intents snippet (to add as `iOS/App/ClipSyncAppIntents.swift` once the iOS engineer is done)

Identical to `macOS/App/ClipSyncAppIntents.swift`:

```swift
// App Intents discovery for the app target (integration pass, Step A of the
// extensions engineer's plan in ClipCore/Intents/ClipSyncShortcuts.swift).
//
// The intents, ClipEntity and the AppShortcutsProvider are compiled into the static
// ClipCore library. Xcode's "Extract App Intents Metadata" step only sees them when the
// app target declares an AppIntentsPackage that includes ClipCore's package.
// If Shortcuts still lists nothing after a build, fall back to thin wrapper intents in
// this target that call ClipIntentRunner (see docs/INTEGRATION_NOTES.md).

import AppIntents
import ClipCore

struct ClipSyncAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        return [ClipCoreAppIntentsPackage.self]
    }
}
```

Other optional iOS follow-ups:
- `HistoryViewModel` can replace its "fetch each kind and merge" workaround with
  `ClipFilter(kinds: [...], ...)`.
- `.file` items should be read with `store.fileURLs(for:)`.

---

## 5. Likely first-compile failures and exact fallbacks

Ranked by my estimate of likelihood. None is known to fail; each fallback is the boring form.

1. **`CardStripPanel` Quick Look overrides** (`macOS/Panel/PanelController.swift`, the three
   `nonisolated override func …PreviewPanelControl`). Risk: an isolation mismatch with the
   SDK's `NSObject (QLPreviewPanelController)` category. **Fallback:** delete the three
   overrides (and the comment above them). In `toggleQuickLook()`, replace
   `if preview.dataSource == nil { preview.dataSource = quickLookSource }` with the
   unconditional `preview.dataSource = quickLookSource`. In `closeQuickLook()`, add
   `preview.dataSource = nil` after `orderOut`. Quick Look keeps working; at most it logs a
   "no controller" console message.
2. **Combined `#Predicate` in `SearchEngine.predicate(kind:pinnedOnly:firstToken:)`.** Risk:
   macro type-check failure, or a SwiftData runtime "unsupported predicate" from the
   constant-Bool `||` terms. **Fallback:** replace the body after the `let`s with explicit
   branches:
   ```swift
   switch (filterByKind, onlyPinned, filterByToken) {
   case (false, false, false): return #Predicate<ClipItem> { _ in true }
   case (true,  false, false): return #Predicate<ClipItem> { $0.kindRaw == kindRaw }
   case (false, true,  false): return #Predicate<ClipItem> { $0.isPinned == true }
   case (true,  true,  false): return #Predicate<ClipItem> { $0.kindRaw == kindRaw && $0.isPinned == true }
   case (false, false, true):  return #Predicate<ClipItem> { $0.searchText.localizedStandardContains(token) }
   case (true,  false, true):  return #Predicate<ClipItem> { $0.kindRaw == kindRaw && $0.searchText.localizedStandardContains(token) }
   case (false, true,  true):  return #Predicate<ClipItem> { $0.isPinned == true && $0.searchText.localizedStandardContains(token) }
   case (true,  true,  true):  return #Predicate<ClipItem> { $0.kindRaw == kindRaw && $0.isPinned == true && $0.searchText.localizedStandardContains(token) }
   }
   ```
   If `localizedStandardContains` is the problem, use `$0.searchText.contains(token)`
   (`searchText` is already folded).
3. **`PanelThumbnailDecoder.decode(_:maxPixelSize:on:)`** (`ThumbnailLoader.swift`). Risk: a
   "sending"/Sendable error for the non-Sendable `NSImage` passed to `resume(returning:)` or
   returned across actors. **Fallback:** add
   `final class PanelImageBox: @unchecked Sendable { let image: NSImage?; init(_ i: NSImage?) { image = i } }`,
   make the continuation `CheckedContinuation<PanelImageBox, Never>`, resume with
   `PanelImageBox(image)`, and return `box.image`. Decode to `CGImage` inside the operation
   and build the `NSImage` on the main actor if needed.
4. **App Intents metadata / `AppShortcutsProvider` inside ClipCore.** Risk: the
   `appintentsmetadataprocessor` complains, or a duplicate-provider error appears once an app
   target adds its own provider. **Fallback:** wrap `ClipSyncShortcuts` in
   `#if CLIPCORE_APP_SHORTCUTS … #endif` (it is not referenced elsewhere) and paste the same
   struct, without `public`, into `macOS/App/ClipSyncAppIntents.swift` (and later the iOS file).
5. **`KeyCodeResolver`** (`macOS/Services/PasteService.swift`, Carbon `TIS`/`UCKeyTranslate`).
   **Fallback:** replace
   `let keyCode = KeyCodeResolver.keyCode(forCharacter: "v") ?? CGKeyCode(kVK_ANSI_V)` with
   `let keyCode = CGKeyCode(kVK_ANSI_V)` and delete the `KeyCodeResolver` enum. Keep
   `import Carbon.HIToolbox` for `kVK_ANSI_V`.
6. **`ClipEntity: Transferable`** (`ClipItemEntity.swift`). Risk: the `ProxyRepresentation`
   closure's `@Sendable` requirement or an AppEntity/Transferable interplay. **Fallback:**
   delete the whole `extension ClipEntity: Transferable { … }`. Shortcuts still exposes the
   `Text` property; only automatic text coercion is lost. Also drop `import CoreTransferable`.
7. **`ClipEntity` `@Property` + `Sendable`.** Risk: an `EntityProperty` Sendable diagnostic
   (should be a warning in Swift 5 mode). **Fallback:** change the declaration to
   `public struct ClipEntity: AppEntity, Identifiable, @unchecked Sendable`.
8. **`CardStripPanel.init(contentRect:)`.** Risk: if the SDK requires it, "'required'
   initializer 'init(coder:)' must be provided". **Fallback:** add
   `required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }`. Add it ONLY
   if the compiler asks: if it is unavailable, adding it is itself an error.
9. **Combine sinks / KeyboardShortcuts closures calling main-actor methods**
   (`AppController.observeSettings`, `LaunchAtLoginController.start`, the `PanelViewModel`
   init sinks, `HotkeyController`). Risk: "call to main actor-isolated instance method in a
   synchronous nonisolated context" if a closure is inferred nonisolated. **Fallback:** wrap
   each sink body as `{ [weak self] _ in MainActor.assumeIsolated { self?.runNow() } }`
   (they all receive on the main run loop / main queue). For the hotkey:
   `KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak environment] in MainActor.assumeIsolated { environment?.panel.toggle() } }`.
10. **`LinkPreviewFetcher.fetchLinkMetadata`.** Risk: `@Sendable` annotation syntax on the LP
    completion closure, or a `Task { @MainActor in … }` capture of a non-Sendable
    `LPMetadataProvider`. **Fallback:** drop `@Sendable` from
    `{ @Sendable metadata, error in`. If capture errors appear, replace the method body with
    the async API:
    `let provider = LPMetadataProvider(); provider.timeout = timeout; guard let m = try? await provider.startFetchingMetadata(for: url) else { return nil }; return FetchedLink(title: m.title, iconProvider: m.iconProvider, imageProvider: m.imageProvider)`,
    and mark `fetchLinkMetadata` `@MainActor`.

Lower-probability items I checked and believe are fine:
- `ModelConfiguration(_:schema:url:cloudKitDatabase:)` and `(_:schema:isStoredInMemoryOnly:cloudKitDatabase:)` labels
- `ModelContainer(for:configurations:)` (variadic)
- `SecTaskCreateFromSelf(nil)` → `SecTask?` and `SecTaskCopyValueForEntitlement(_, CFString, nil)`
- stored `id: UUID` on `@Model`, and `@Attribute(.externalStorage)` with a default
- `CGPDFDocument.unlockWithPassword("")` (String → `UnsafePointer<CChar>` bridging)
- `MediaServices.live()` vs `env.store.media = .live()`
- KeyboardShortcuts 2.4.x APIs, checked against the 2.4.0 sources:
  - `Name(_:default:)`
  - `onKeyUp(for:action:)`
  - `getShortcut(for:)`
  - `Recorder(_:name:)`
  - `Shortcut.description`, which is `@MainActor` and only used in a SwiftUI `View`
- `store.$revision` (declared `@Published public private(set)`)
- `@Published` assigned before `super.init()` in `AccessibilityPermission`
