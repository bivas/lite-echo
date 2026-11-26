import Foundation

/// Which kind of build this is. `scripts/build-app.sh` writes `LiteEchoFlavor` into Info.plist:
/// local builds are `dev` ("LiteEcho Dev", its own bundle id), release builds from CI are `release`.
///
/// A dev build runs next to an installed release without either one taking over the other:
/// different bundle id, settings, queue, engine, keychain item and command name. The models and
/// uv's download cache are shared, so a dev build doesn't download 1.6 GB of models again.
public enum AppFlavor: String, Sendable {
    case release, dev

    public static let infoKey = "LiteEchoFlavor"

    /// The flavor of the running app. Anything but an explicit "dev" is a release, so tests and
    /// tools without an Info.plist behave like the release.
    public static var current: AppFlavor {
        from(infoValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
    }

    public static func from(infoValue: String?) -> AppFlavor {
        infoValue == AppFlavor.dev.rawValue ? .dev : .release
    }

    public var displayName: String { self == .dev ? "LiteEcho Dev" : "LiteEcho" }
    /// The folder in ~/Library/Application Support for this build's own data.
    public var supportFolderName: String { self == .dev ? "LiteEcho Dev" : "LiteEcho" }
    /// The command installed in ~/.local/bin.
    public var commandName: String { self == .dev ? "liteecho-dev" : "liteecho" }
    public var keychainService: String { self == .dev ? "dev.liteecho.app.dev" : "dev.liteecho.app" }

    /// The release build's support folder; models and uv's caches live there for every flavor.
    public static let sharedFolderName = "LiteEcho"
}
