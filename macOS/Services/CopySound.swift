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

    /// Plays the named system sound (the default sound if the name is unknown).
    static func play(named name: String) {
        guard let sound = sound(named: name) ?? sound(named: AppSettings.defaultCopySoundName) else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    private static func sound(named name: String) -> NSSound? {
        if let cached = cache[name] { return cached }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return nil }
        cache[name] = sound
        return sound
    }
}
