import Foundation

public enum BridgeRequest: Codable, Sendable, Equatable {
    case setMode(ANCMode)
    case cycleMode
}

/// The whole agent ↔ extension protocol.
///
/// Two channels, both in App Group defaults:
///   snapshot  — agent writes, extension reads (for `currentValue()`)
///   request   — extension writes, agent reads (for taps on a control)
///
/// A Darwin notification nudges the agent to read. It carries no payload and
/// coalesces, so the defaults write is the actual channel; a monotonic `seq`
/// makes a replayed or coalesced nudge harmless.
public final class StateBridge: @unchecked Sendable {

    private enum Key {
        static let snapshot = "snapshot"
        /// Payload *and* seq together — see `StoredRequest`.
        static let request = "request"
        static let handledSeq = "handledSeq"
        static let peripheralIdentifier = "peripheralIdentifier"
    }

    /// The request and its seq in one value under one key.
    ///
    /// They used to be two keys. The writer ordered them safely (payload, then
    /// seq), but the reader is a *different process* doing two independent
    /// CFPreferences lookups, with no guarantee both caches were invalidated
    /// together. Seeing a stale seq beside a fresh payload applied the new
    /// request while recording the old seq — and the next `drainRequests()`
    /// (one Darwin burst usually delivers more than one) applied it again. One
    /// Control Center tap, two cycle advances.
    private struct StoredRequest: Codable {
        let seq: Int
        let request: BridgeRequest
    }

    private let defaults: UserDefaults

    public static let shared = StateBridge(
        defaults: UserDefaults(suiteName: BudsCtl.appGroupID) ?? .standard
    )

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// False when the App Group is not actually provisioned for this build —
    /// i.e. the entitlement is missing or the signing team cannot grant it.
    /// Surface it, do not paper over it: `UserDefaults(suiteName:)` succeeds
    /// regardless, so an unprovisioned group would silently give the agent and
    /// the extension two different stores and look merely "broken".
    public var appGroupAvailable: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BudsCtl.appGroupID
        ) != nil
    }

    // MARK: - State, agent to extension

    public func publish(_ snapshot: ModeSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Key.snapshot)
    }

    public func readSnapshot() -> ModeSnapshot {
        guard let data = defaults.data(forKey: Key.snapshot),
              let snapshot = try? JSONDecoder().decode(ModeSnapshot.self, from: data)
        else { return ModeSnapshot(mode: nil, connected: false) }
        return snapshot
    }

    // MARK: - Requests, extension to agent

    @discardableResult
    public func postRequest(_ request: BridgeRequest) -> Int {
        // Also floored at handledSeq, so a lost or undecodable stored request
        // cannot hand out a seq the agent has already passed — which would be
        // taken for "already handled" and dropped.
        let seq = max(storedRequest()?.seq ?? 0, handledSeq) + 1
        // On encode failure, nothing is persisted, so `seq` is never reachable
        // by `handledSeq`. Returning it (not `seq - 1`, which is the already-
        // persisted value) makes `waitForHandling` report false — failing
        // safe — instead of an intent falsely claiming the request succeeded.
        guard let data = try? JSONEncoder().encode(
            StoredRequest(seq: seq, request: request)
        ) else { return seq }
        defaults.set(data, forKey: Key.request)
        // ponytail: no synchronize() call. Darwin delivery is slower than the
        // CFPreferences write path in practice; if a request is ever seen stale,
        // add defaults.synchronize() here before reaching for anything larger.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(BudsCtl.requestNotification as CFString),
            nil,
            nil,
            true
        )
        return seq
    }

    /// Highest seq the agent has taken. Used to tell "the agent handled it"
    /// from "nothing is running".
    public var handledSeq: Int {
        defaults.integer(forKey: Key.handledSeq)
    }

    /// Poll until the agent takes `seq`, or give up.
    ///
    /// Polling rather than a second Darwin notification: this runs inside a
    /// control extension with a short execution budget, and a 100 ms defaults
    /// read is cheaper than standing up an observer for one shot.
    public func waitForHandling(of seq: Int, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if handledSeq >= seq { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return handledSeq >= seq
    }

    /// Returns the pending request, or nil if there is none or it was already
    /// handled. Only the agent calls this.
    public func takeRequest() -> BridgeRequest? {
        // One lookup, so the seq and the payload cannot be observed out of
        // sync across the process boundary.
        guard let stored = storedRequest() else { return nil }
        guard stored.seq > handledSeq else { return nil }
        // Advanced only now, after a successful decode. Advancing first threw
        // an undecodable request away while `waitForHandling` still reported
        // true, so an intent said "Set to …" for a request nobody applied —
        // reachable through version skew, e.g. an installed agent older than
        // the extension after a `BridgeRequest` case is added. Leaving
        // `handledSeq` alone instead makes such a request read as unhandled,
        // so the intent takes the launch path.
        defaults.set(stored.seq, forKey: Key.handledSeq)
        return stored.request
    }

    /// nil when there is nothing stored, or when what is stored cannot be
    /// decoded by this build.
    private func storedRequest() -> StoredRequest? {
        guard let data = defaults.data(forKey: Key.request) else { return nil }
        return try? JSONDecoder().decode(StoredRequest.self, from: data)
    }

    public func observeRequests(_ handler: @escaping @Sendable () -> Void) {
        DarwinNotifications.shared.observe(BudsCtl.requestNotification, handler)
    }

    // MARK: - Saved peripheral

    public var peripheralIdentifier: UUID? {
        guard let raw = defaults.string(forKey: Key.peripheralIdentifier) else { return nil }
        return UUID(uuidString: raw)
    }

    public func savePeripheralIdentifier(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Key.peripheralIdentifier)
        } else {
            defaults.removeObject(forKey: Key.peripheralIdentifier)
        }
    }
}

/// Darwin notify centre observation. The C callback cannot capture context, so
/// handlers live in a process-wide table keyed by notification name.
///
/// Darwin notify rather than DistributedNotificationCenter because it is the
/// route that reliably crosses the sandbox boundary between an app and its
/// extension.
final class DarwinNotifications: @unchecked Sendable {
    static let shared = DarwinNotifications()

    private let lock = NSLock()
    private var handlers: [String: [@Sendable () -> Void]] = [:]

    func observe(_ name: String, _ handler: @escaping @Sendable () -> Void) {
        let isFirstForName: Bool = lock.withLock {
            let existing = handlers[name] ?? []
            handlers[name] = existing + [handler]
            return existing.isEmpty
        }
        guard isFirstForName else { return }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, name, _, _ in
                guard let name else { return }
                DarwinNotifications.shared.fire(name.rawValue as String)
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    fileprivate func fire(_ name: String) {
        let targets = lock.withLock { handlers[name] ?? [] }
        for handler in targets { handler() }
    }
}
