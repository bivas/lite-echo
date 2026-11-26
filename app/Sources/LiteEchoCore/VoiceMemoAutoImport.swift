import Foundation

/// "Only if longer than" choices of the auto-import setting.
public enum VoiceMemoMinimumLength: Int, CaseIterable, Identifiable, Sendable {
    case any = 0, thirtySeconds = 30, oneMinute = 60, fiveMinutes = 300

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public var label: String {
        switch self {
        case .any: "Any length"
        case .thirtySeconds: "30 seconds"
        case .oneMinute: "1 minute"
        case .fiveMinutes: "5 minutes"
        }
    }
}

/// What the user asked auto-import to do.
public struct AutoImportPolicy: Equatable, Sendable {
    public var enabled: Bool
    /// When auto-import was turned on: only memos recorded after it are added.
    public var since: Date?
    /// nil = all folders.
    public var folderID: String?
    public var minimumLength: VoiceMemoMinimumLength

    public init(enabled: Bool, since: Date?, folderID: String? = nil, minimumLength: VoiceMemoMinimumLength = .any) {
        self.enabled = enabled
        self.since = since
        self.folderID = folderID
        self.minimumLength = minimumLength
    }
}

public enum AutoImportDecision {
    /// The memos to enqueue now, oldest first: local, not imported, not queued, recorded after
    /// `policy.since`, in the chosen folder and longer than the minimum. Nothing unless the
    /// library answered `ok`, the policy is on and has a start moment.
    public static func memos(in listing: VoiceMemoListing, policy: AutoImportPolicy,
                             imported: Set<String>, queued: Set<String>) -> [VoiceMemo] {
        guard policy.enabled, let since = policy.since, listing.status == .ok else { return [] }
        return listing.memos.filter { memo in
            guard memo.local, !imported.contains(memo.id), !queued.contains(memo.id), memo.recorded > since else { return false }
            if let folder = policy.folderID, memo.folderID != folder { return false }
            let minimum = policy.minimumLength.seconds
            return minimum == 0 || memo.durationSeconds > minimum
        }
        .sorted { $0.recorded < $1.recorded }
    }
}

/// Re-lists the library on a timer (and when the app comes to the front) and enqueues new
/// memos. Everything it touches is injected, so tests need no engine and no real clock.
@MainActor
public final class VoiceMemoAutoImporter {
    public struct Hooks {
        public var lister: () async -> VoiceMemoListing
        public var clock: () -> Date
        public var policy: () -> AutoImportPolicy
        public var importedIDs: () -> Set<String>
        /// Memo ids that already have a queue entry (any state), so failed ones are not retried by themselves.
        public var queuedIDs: () -> Set<String>
        /// False while the engine or models are not ready.
        public var canRun: () -> Bool
        public var enqueue: ([VoiceMemo], VoiceMemoListing) -> Void

        public init(lister: @escaping () async -> VoiceMemoListing, clock: @escaping () -> Date = { Date() },
                    policy: @escaping () -> AutoImportPolicy, importedIDs: @escaping () -> Set<String>,
                    queuedIDs: @escaping () -> Set<String>, canRun: @escaping () -> Bool = { true },
                    enqueue: @escaping ([VoiceMemo], VoiceMemoListing) -> Void) {
            self.lister = lister
            self.clock = clock
            self.policy = policy
            self.importedIDs = importedIDs
            self.queuedIDs = queuedIDs
            self.canRun = canRun
            self.enqueue = enqueue
        }
    }

    public nonisolated static let defaultInterval: TimeInterval = 120
    /// Polls closer together than this (e.g. app activation right after a timer tick) are skipped.
    public nonisolated static let minimumGap: TimeInterval = 10

    public let interval: TimeInterval
    private let hooks: Hooks
    private var lastPoll: Date?
    private var isPolling = false
    private var loop: Task<Void, Never>?
    /// The last status the library answered with (nil before the first poll).
    public private(set) var lastStatus: VoiceMemoAccess?

    public init(interval: TimeInterval = VoiceMemoAutoImporter.defaultInterval, hooks: Hooks) {
        self.interval = interval
        self.hooks = hooks
    }

    /// One check. Returns the memos it enqueued. `force` ignores the minimum gap.
    @discardableResult
    public func poll(force: Bool = false) async -> [VoiceMemo] {
        let policy = hooks.policy()
        guard policy.enabled, policy.since != nil, hooks.canRun(), !isPolling else { return [] }
        let now = hooks.clock()
        if !force, let last = lastPoll, now.timeIntervalSince(last) < Self.minimumGap { return [] }
        isPolling = true
        defer { isPolling = false }
        lastPoll = now
        let listing = await hooks.lister()
        lastStatus = listing.status
        // The settings may have changed while the engine was answering.
        let current = hooks.policy()
        let chosen = AutoImportDecision.memos(in: listing, policy: current,
                                              imported: hooks.importedIDs(), queued: hooks.queuedIDs())
        if !chosen.isEmpty { hooks.enqueue(chosen, listing) }
        return chosen
    }

    /// Starts the timer (first check after one interval; the app calls `appBecameActive` at launch).
    public func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.interval ?? 120) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.poll(force: true)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func appBecameActive() {
        Task { await poll() }
    }
}
