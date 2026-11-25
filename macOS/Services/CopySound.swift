import AppKit
import ClipCore

/// The built-in macOS alert sounds (System Settings › Sound) used for the copy sound.
@MainActor
enum CopySound {
    /// Sound names found in /System/Library/Sounds, sorted; falls back to the usual 14.
    static let availableNames: [String] = {
        let folder = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let names = files
            .filter { ["aiff", "aif", "caf", "wav"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
        return names.isEmpty
            ? ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
               "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
            : names
    }()

    private static var cache: [String: NSSound] = [:]
    private static var customSound: (path: String, sound: NSSound)?

    /// Plays the named system sound, or the user's file for `AppSettings.customCopySoundName`.
    /// Falls back to the default sound if the name or file can't be played.
    static func play(named name: String, customFilePath: String = "") {
        var chosen: NSSound?
        if name == AppSettings.customCopySoundName {
            chosen = custom(at: customFilePath)
        } else {
            chosen = sound(named: name)
        }
        guard let sound = chosen ?? sound(named: AppSettings.defaultCopySoundName) else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// Picker label for the user's file, e.g. "Custom: paste.m4a".
    static func customLabel(for path: String) -> String {
        return "Custom: " + URL(fileURLWithPath: path).lastPathComponent
    }

    /// Copies a user-chosen sound into ClipSync's own folder (so it keeps working if the
    /// original moves) and returns the copy. Throws if the file isn't playable audio.
    static func importFile(at source: URL) throws -> URL {
        guard NSSound(contentsOf: source, byReference: false) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("ClipSync/Sounds", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: old)
        }
        let dest = folder.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: dest)
        customSound = nil
        return dest
    }

    private static func custom(at path: String) -> NSSound? {
        guard !path.isEmpty else { return nil }
        if let cached = customSound, cached.path == path { return cached.sound }
        guard let sound = NSSound(contentsOf: URL(fileURLWithPath: path), byReference: false) else { return nil }
        customSound = (path, sound)
        return sound
    }

    private static func sound(named name: String) -> NSSound? {
        if let cached = cache[name] { return cached }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return nil }
        cache[name] = sound
        return sound
    }
}
