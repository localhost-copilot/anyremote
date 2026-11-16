import AnyRemoteWire
import AppKit

extension NSScreen {
    /// This screen as the host knows it: its windows get a virtual display
    /// of this size there.
    var viewerScreen: ViewerScreen? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return ViewerScreen(id: number.uint32Value, size: frame.size)
    }
}
