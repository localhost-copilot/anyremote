import Foundation

/// Runs the Accessibility queries the host polls for (an app's standard
/// windows, its focused field, whether a window was minimized) away from the
/// host service's queue, one serial queue per app.
///
/// An app that is busy (dragging its alert, in a modal loop, hung) answers
/// each query only when it times out. On the host's queue those waits added
/// up to seconds: every session stalled until viewers gave up on the
/// connection and closed its windows. Now the host goes on with the last
/// answer it has, and a query that is still waiting isn't asked again.
final class AccessibilityPoller: @unchecked Sendable {
    // Confined to the caller's queue (the host service's queue).
    private var queues: [pid_t: DispatchQueue] = [:]
    private var running: Set<String> = []

    /// Runs `work` for the app `pid` unless a query with the same key is
    /// still running, then `done` with its result on `reply`, the queue this
    /// is called on.
    func run<T>(_ key: String, pid: pid_t, reply: DispatchQueue,
                _ work: @escaping @Sendable () -> T, then done: @escaping @Sendable (T) -> Void) {
        guard running.insert(key).inserted else { return }
        let queue = queues[pid] ?? DispatchQueue(label: "anyremote.accessibility.\(pid)", qos: .userInitiated)
        queues[pid] = queue
        nonisolated(unsafe) let work = work
        queue.async {
            nonisolated(unsafe) let result = work()
            reply.async { [self] in
                running.remove(key)
                done(result)
            }
        }
    }

    /// Lets the queues of apps that quit go.
    func forget(exceptPIDs pids: Set<pid_t>) {
        queues = queues.filter { pids.contains($0.key) }
    }
}
