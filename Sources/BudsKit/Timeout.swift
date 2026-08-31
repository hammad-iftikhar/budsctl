import Foundation

/// Runs `operation`, returning nil if `duration` elapses first.
///
/// Swift has no built-in async timeout. This is the whole of ours: race the
/// work against a sleep and take whichever finishes.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: duration)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
