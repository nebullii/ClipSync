# ClipSync iOS — integration notes

## iOS audit

I audited `iOS/` and `ShareExtension/` against `Packages/ClipCore/Sources` by reading the code. **No compiler has
checked any of it.** The first real check is `scripts/build.sh ios` (Xcode 16+, iOS Simulator, Swift 5 mode).

### Fixes

- `iOS/Views/History/ClipItemActions.swift:129-156`: rewrote `ClipImageTransfer` in a plainer form. The
  `DataRepresentation` closure now has an explicit `(ClipImageTransfer) async throws -> Data` signature. The store
  read moved out of a multi-statement `MainActor.run` closure that returned a tuple into
  `@MainActor static func imagePayload(for:) -> ClipDraft.Representation?`. The type is marked `Sendable`.
- `ShareExtension/ShareAttachmentLoader.swift:69,91,117,134,206,220`: every `ItemProviderLoader.loadItem` and
  `loadFile` `transform:` closure now spells out its type, e.g. `(NSSecureCoding?) -> String?` or
  `(URL) -> ShareLoadOutcome?`. The compiler no longer has to infer the generic `T` from a multi-statement closure.
- `ShareExtension/ShareViewController.swift:93-109`: unsigned builds now fail honestly.
  - Before creating any store, it checks `AppGroup.containerURL() == nil`. If there is no container, it saves
    nothing and shows "Can't reach ClipSync from here" with the reason.
  - It also refuses to save into an in-memory fallback store (`store.isInMemory`), which would lose the data.
  - Before: it saved into the extension's own Application Support store, which the app never reads, and showed
    "Saved to ClipSync".
- `ShareExtension/ShareViewController.swift:156`: removed the old "saved only inside the extension" note, which can
  no longer happen.
- `iOS/App/AppModel.swift:30,93` and `iOS/Views/History/HistoryScreen.swift:16`: `-uitest-seed` now sets the
  History layout to `list` through a shared key, `LaunchOptions.historyLayoutKey`. Rows are always
  `history.row.N`: on iPad, where the automatic layout would be the grid (`history.card.N`), and after an earlier
  run switched to the grid.
- `iOS/Services/ClipboardDraftBuilder.swift:111-114`: `loadData` now uses `ItemProviderLoader.loadData(...,
  timeout: 20)`. The old raw `withCheckedContinuation` waited forever if a paste provider stalled.
- `iOS/App/ClipSyncAppIntents.swift` (new): `ClipSyncAppIntentsPackage: AppIntentsPackage`, which includes
  `ClipCoreAppIntentsPackage`. That type exists and is `public` in `ClipCore/Intents/ClipSyncShortcuts.swift:16`.

### Checked and left unchanged

- **ClipCore references.** Every type, method, initializer label and enum case used by both targets matches a
  `public` declaration in ClipCore: `ClipStore`, `ClipFilter(kind:pinboardID:searchText:pinnedOnly:limit:offset:)`,
  `IngestResult` / `IngestRejection`, `ClipDraft`, `ClipUTI`, `ColorParser.components(fromHex:)`, `SearchEngine`,
  `ItemProviderLoader`, `ImageEncoding`, `AppGroup`, `AppSettings`, `RetentionPolicy` and `ClipConstants`.
- **Imports.** Every file has the imports it uses. `AppModel.swift` imports CoreData for
  `.NSPersistentStoreRemoteChange` and Combine for the sinks.
- **Name collisions.** No type name is declared twice in either target. No iOS type shadows a ClipCore public type.
  The iOS `ClipItem` extension members (`isAlive`, `visibleText`, `linkURL`, `linkHost`, `fileNames`,
  `looksLikeCode`, `metaLine`, `isMember(of:)`, …) do not clash with ClipCore's public `ClipItem` API.
  `ClipStore.isAlive` is a `private static` on `ClipStore` and cannot clash.
- **`PasteTargetView`.** These spellings match the UIKit API: `UIPasteControl(configuration:)`, `control.target =
  self`, `pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers:)`,
  `override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool` and
  `override func paste(itemProviders: [NSItemProvider])`.
- **Other SwiftUI patterns checked:**
  - `ForEach(Array(items.enumerated()), id: \.element.id) { index, item in }`
  - `.sheet(item:)` with `ClipItem`, whose `ID` is `UUID` from its own `id`
  - `List(selection: $SidebarItem?)`
  - `if case .pinboard(let id)? = selection`
  - every `.onChange(of:)` uses the two-parameter form
  - `.refreshable { await MainActor.run { … } }`
  - `Task { @MainActor [weak self] in … }`
- **Share extension.** It uses `extensionContext?.completeRequest(returningItems: [], completionHandler: nil)` and
  `cancelRequest(withError:)`, and embeds its UI with `UIHostingController` plus `addChild` / `didMove(toParent:)`.
- **App icon.** `AppIcon.appiconset/Contents.json` is a single-size icon: `universal`, `ios`, `1024x1024`,
  `AppIcon-1024.png`. PIL reads the PNG as 1024×1024, mode `RGB`, 8-bit, no alpha. No change needed.
- **Simulator seed path (`-uitest-seed`), read end to end:**
  - `ClipStore.makeShared(inMemory: true)` + `ClipStore.setShared`
  - settings in the private suite `com.thingbits.clipsync.uitest`, with `hasCompletedOnboarding = true` and the
    onboarding cover set to false
  - `media` left at `.noop`, so there is no network; the iCloud banner is hidden when `isUITest`
  - `SampleData` inserts 12 distinct drafts and 2 pinboards (Work, Design)
  - row 0 is "Meeting notes" (newest `lastUsedAt`)
- **Text/Files chips.** `HistoryViewModel` fetches each `ClipKind` separately and merges by `lastUsedAt`. It never
  sets a `kinds:` field, so adding `ClipFilter.kinds` later (additive, defaulted) changes nothing here.
