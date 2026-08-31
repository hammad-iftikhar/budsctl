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
        static let request = "request"
        static let requestSeq = "requestSeq"
        static let handledSeq = "handledSeq"
        static let peripheralIdentifier = "peripheralIdentifier"
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
        let seq = defaults.integer(forKey: Key.requestSeq) + 1
        guard let data = try? JSONEncoder().encode(request) else { return seq - 1 }
        defaults.set(data, forKey: Key.request)
        defaults.set(seq, forKey: Key.requestSeq)
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
        let seq = defaults.integer(forKey: Key.requestSeq)
        guard seq > defaults.integer(forKey: Key.handledSeq) else { return nil }
        defaults.set(seq, forKey: Key.handledSeq)
        guard let data = defaults.data(forKey: Key.request),
              let request = try? JSONDecoder().decode(BridgeRequest.self, from: data)
        else { return nil }
        return request
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
