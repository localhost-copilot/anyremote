import Carbon
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Input")

/// The host's input source while a viewer types, per `TextInputSettings`.
///
/// When the viewer's input method composes, the host keeps a plain keyboard
/// layout: an input method selected here would compose the viewer's key codes
/// again, in a candidate window the viewer may not see. The source that was
/// selected before comes back when the viewer leaves or lets the host's input
/// method compose, unless someone chose another meanwhile.
@MainActor
final class HostKeyboardLayout {
    /// The source selected before this session first switched, and the one it chose last.
    private var switched: (previous: String, selected: String)?
    private var lastCheck: Date = .distantPast

    /// Viewer composes: cheap enough for every key press, checks at most once a second.
    func ensureKeyboardLayout() {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 1 else { return }
        lastCheck = now
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              !Self.isKeyboardLayout(current),
              let layout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return }
        select(layout, replacing: current)
    }

    private func select(_ source: TISInputSource, replacing current: TISInputSource) {
        guard let currentID = Self.identifier(current), let sourceID = Self.identifier(source) else { return }
        let status = TISSelectInputSource(source)
        log.notice("input source \(currentID, privacy: .public) -> \(sourceID, privacy: .public) (\(status))")
        guard status == noErr else { return }
        switched = (switched?.previous ?? currentID, sourceID)
    }

    /// Selects the previous source again, unless someone chose another meanwhile.
    func restore() {
        guard let switched else { return }
        self.switched = nil
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              Self.identifier(current) == switched.selected, switched.previous != switched.selected,
              let previous = Self.source(switched.previous) else { return }
        TISSelectInputSource(previous)
    }

    private static func isKeyboardLayout(_ source: TISInputSource) -> Bool {
        stringProperty(source, kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String)
    }

    private static func identifier(_ source: TISInputSource) -> String? {
        stringProperty(source, kTISPropertyInputSourceID)
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        TISGetInputSourceProperty(source, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }

    /// Among the enabled sources only.
    private static func source(_ identifier: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }
}
