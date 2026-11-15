import Carbon
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Input")

/// Keeps the host on a plain keyboard layout while a viewer types.
///
/// The viewer composes Chinese, Japanese and the like with its own input
/// method and sends the text; its other keys arrive as key codes. An input
/// method selected here would compose those key codes again, in a candidate
/// window the viewer can't see (it isn't part of the captured window). The
/// source that was selected before comes back when the viewer leaves.
@MainActor
final class HostKeyboardLayout {
    /// The source selected before this session switched, and the one it chose.
    private var switched: (previous: String, selected: String)?
    private var lastCheck: Date = .distantPast

    /// Cheap enough for every key press: checks at most once a second.
    func ensureKeyboardLayout() {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 1 else { return }
        lastCheck = now
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              !Self.isKeyboardLayout(current),
              let layout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let currentID = Self.identifier(current), let layoutID = Self.identifier(layout) else { return }
        let status = TISSelectInputSource(layout)
        log.notice("input source \(currentID, privacy: .public) -> \(layoutID, privacy: .public) (\(status))")
        guard status == noErr else { return }
        if switched == nil { switched = (currentID, layoutID) }
    }

    /// Selects the previous source again, unless someone chose another meanwhile.
    func restore() {
        guard let switched else { return }
        self.switched = nil
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              Self.identifier(current) == switched.selected,
              let previous = Self.source(switched.previous) else { return }
        TISSelectInputSource(previous)
    }

    private static func isKeyboardLayout(_ source: TISInputSource) -> Bool {
        guard let type = property(source, kTISPropertyInputSourceType) else { return true }
        return (Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String) == (kTISTypeKeyboardLayout as String)
    }

    private static func identifier(_ source: TISInputSource) -> String? {
        property(source, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> UnsafeMutableRawPointer? {
        TISGetInputSourceProperty(source, key)
    }

    private static func source(_ identifier: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }
}
