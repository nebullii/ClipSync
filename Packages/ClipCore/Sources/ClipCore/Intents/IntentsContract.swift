// CONTRACT — this folder is owned by the extensions engineer (App Intents).
//
// Implemented files:
//   ClipIntentRunner.swift      — testable store logic + ClipIntentError (all intents call this)
//   SystemPasteboard.swift      — UIPasteboard / NSPasteboard read + write
//   ClipItemEntity.swift        — ClipEntity (AppEntity, typealias ClipItemEntity) + ClipEntityQuery
//   SaveClipboardIntent.swift   — SaveClipboardIntent, SaveTextIntent
//   SearchClipsIntent.swift     — SearchClipsIntent → [ClipEntity]
//   CopyLatestIntent.swift      — CopyLatestIntent, CopyClipIntent
//   ClipSyncShortcuts.swift     — ClipCoreAppIntentsPackage + AppShortcutsProvider
//
// Rules: store work runs on the main actor (`@MainActor func perform()`), pasteboard
// code is wrapped in `#if canImport(UIKit)` / `#if canImport(AppKit)`.
