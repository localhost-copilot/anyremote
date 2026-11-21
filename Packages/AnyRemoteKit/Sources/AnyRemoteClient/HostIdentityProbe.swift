import AnyRemoteNetwork
import AnyRemoteWire
import Foundation

/// Tells whether the Mac at a route is the one a key belongs to, without
/// opening a session there. The hello names the key and the host answers
/// with its ID; a message sent before authenticating then gets the host's
/// sealed refusal ("Expected authentication."), which only the Mac holding
/// the key could seal. The host admits no viewer and shows nothing.
///
/// Used for a paired Mac whose tailnet address isn't known yet (it runs an
/// AnyRemote from before 0.32, or joined the tailnet after this Mac last
/// reached it), when the tailnet node finds AnyRemote at an address.
public enum HostIdentityProbe {
    /// The host's ID if it holds `credential`, else nil.
    public static func hostID(at route: HostRoute, credential: PairingCredential, viewerName: String,
                              timeout: TimeInterval = 6) async -> String? {
        let queue = DispatchQueue(label: "anyremote.identity-probe")
        let control = ControlConnection(transport: route.makeStream(),
                                        role: .viewer(credential: credential, viewerName: viewerName), queue: queue)
        let once = Once<String?>()
        let claimed = Claimed()
        return await withCheckedContinuation { continuation in
            once.handler = { continuation.resume(returning: $0) }
            control.onSecured = { [weak control] info in
                claimed.id = info.peerID
                control?.send(.ping(id: 0, viewerTime: 0))
            }
            // A sealed message opened: it came from the key's Mac.
            control.onMessage = { [weak control] _ in
                once.fire(claimed.id)
                control?.close()
            }
            control.onClose = { _ in once.fire(nil) }
            control.start()
            queue.asyncAfter(deadline: .now() + timeout) {
                once.fire(nil)
                control.close()
            }
        }
    }
}

/// Queue-confined to the probe's connection.
private final class Claimed: @unchecked Sendable {
    var id: String?
}
