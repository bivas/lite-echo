import AppKit
import Foundation

/// Opens finished transcripts (the engine's .html output) in the default browser.
public enum TranscriptOpener {
    /// The URL when it is an existing .html file, else nil. Anything else (other schemes,
    /// other extensions, missing files, directories) is never handed to the system.
    public static func openableURL(_ url: URL, fileManager: FileManager = .default) -> URL? {
        guard url.isFileURL, url.pathExtension.lowercased() == "html" else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url
    }

    /// Opens `url` with `opener` if it passes `openableURL`. Returns whether it was opened.
    @discardableResult
    public static func open(_ url: URL, fileManager: FileManager = .default,
                            opener: (URL) -> Void = { NSWorkspace.shared.open($0) }) -> Bool {
        guard let safe = openableURL(url, fileManager: fileManager) else { return false }
        opener(safe)
        return true
    }
}
