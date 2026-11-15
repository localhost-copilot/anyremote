import AnyRemoteWire
import AppKit
import Carbon

/// This Mac's selected input source, as far as typing on a host goes.
///
/// With a keyboard layout (ABC, French…) keys go to the host as key codes,
/// so shortcuts, games and terminals see real keys. With an input method
/// (Pinyin, WeChat, Kotoeri…) keys go through it here: its candidates show
/// on this Mac, it switches like any other, and the host gets the text.
@MainActor
enum LocalInputSource {
    private static var cachedComposes: Bool?
    private static var observers: [NSObjectProtocol] = []
    /// Source IDs, most recently selected first: ⌃Space goes back to the second.
    private static var recent: [String] = []

    static var composes: Bool {
        startObserving()
        if let cachedComposes { return cachedComposes }
        let value = current().map { !isKeyboardLayout($0) } ?? false
        cachedComposes = value
        return value
    }

    private static func startObserving() {
        guard observers.isEmpty else { return }
        if let id = current().flatMap(identifier) { recent = [id] }
        let changed: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { selectionChanged() }
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            queue: .main, using: changed))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main,
            using: changed))
    }

    private static func selectionChanged() {
        cachedComposes = nil
        guard let id = current().flatMap(identifier), recent.first != id else { return }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 2 { recent.removeLast(recent.count - 2) }
    }

    /// The input source shortcuts, when they reach this app: while a full
    /// desktop captures system shortcuts, macOS doesn't act on them itself.
    /// Returns true when the event was one and the source was switched.
    static func handleSwitchShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = SwitchShortcut.matching(event) else { return false }
        startObserving()
        switch shortcut {
        case .previous:
            if recent.count > 1, let source = source(recent[1]) {
                TISSelectInputSource(source)
            } else {
                selectNext()
            }
        case .next:
            selectNext()
        }
        return true
    }

    private static func selectNext() {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              !list.isEmpty else { return }
        let currentID = current().flatMap(identifier)
        let index = list.firstIndex { identifier($0) == currentID } ?? -1
        TISSelectInputSource(list[(index + 1) % list.count])
    }

    private enum SwitchShortcut {
        case previous, next

        /// System Settings › Keyboard Shortcuts › Input Sources (symbolic hot
        /// keys 60 and 61), or their defaults ⌃Space and ⌃⌥Space.
        static func matching(_ event: NSEvent) -> SwitchShortcut? {
            let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
            let flags = event.modifierFlags.intersection(relevant)
            guard !flags.isEmpty else { return nil }
            let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys")
            for (id, shortcut, fallback) in [("60", SwitchShortcut.previous, (49, NSEvent.ModifierFlags.control)),
                                             ("61", .next, (49, [.control, .option]))] {
                var keyCode = fallback.0, modifiers = fallback.1
                if let entry = hotKeys?[id] as? [String: Any] {
                    guard (entry["enabled"] as? Bool) ?? true else { continue }
                    if let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3 {
                        keyCode = parameters[1]
                        modifiers = NSEvent.ModifierFlags(rawValue: UInt(parameters[2])).intersection(relevant)
                    }
                }
                if Int(event.keyCode) == keyCode, flags == modifiers { return shortcut }
            }
            return nil
        }
    }

    private static func current() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    private static func isKeyboardLayout(_ source: TISInputSource) -> Bool {
        guard let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return true }
        return (Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String) == (kTISTypeKeyboardLayout as String)
    }

    private static func identifier(_ source: TISInputSource) -> String? {
        TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }

    private static func source(_ identifier: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        return (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first
    }
}

/// Composes text for the host with this Mac's input method.
///
/// The surface view's input context talks to this object. A key goes to the
/// input method first; what it does with the key decides what the host gets:
/// committed text (你好, ，) as text, a key it passed through unchanged (a
/// letter in its English mode, Return or an arrow outside a composition) as
/// that key, so the host app sees a real key code. Text still being composed
/// shows in a small panel at the host's caret, with the candidates below it.
@MainActor
final class TextComposer: NSObject, @preconcurrency NSTextInputClient {
    private weak var view: RemoteSurfaceView?
    private(set) lazy var context = NSTextInputContext(client: self)
    private var marked = NSAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    /// What the input method did with the key being handled.
    private var handling: (inserted: String, commanded: Bool)?
    /// Keys the input method took: their releases stay here too.
    private var composedKeys: Set<UInt16> = []
    private var cancelling = false
    private lazy var panel = MarkedTextPanel()
    /// Where the last click was (screen), for hosts that report no caret.
    var clickPoint: NSPoint?

    init(view: RemoteSurfaceView) {
        self.view = view
    }

    private func send(_ text: String) {
        guard !text.isEmpty else { return }
        view?.sink?.sendInput(.text(text))
    }

    /// Returns false when the key should go to the host as a key.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let wasComposing = hasMarkedText()
        handling = ("", false)
        let handled = context.handleEvent(event)
        let result = handling ?? ("", false)
        handling = nil
        guard handled else { return false }

        var passKey = false
        if !result.inserted.isEmpty {
            if !wasComposing, !hasMarkedText(), !result.commanded, result.inserted == event.characters {
                passKey = true
            } else {
                send(result.inserted)
            }
        }
        // A command (insertNewline:, moveLeft:, deleteBackward:…) outside a
        // composition, or after committing one, is the host app's to handle.
        if result.commanded, !wasComposing || !result.inserted.isEmpty { passKey = true }
        if !passKey { composedKeys.insert(event.keyCode) }
        return !passKey
    }

    /// True when the release belongs to a key the input method took.
    func handleKeyUp(_ event: NSEvent) -> Bool {
        composedKeys.remove(event.keyCode) != nil
    }

    /// Drops the text being composed (a click, another window in front, an
    /// input source without composition).
    func cancel() {
        guard hasMarkedText() else { return }
        clearMarked()
        cancelling = true
        context.discardMarkedText()
        cancelling = false
    }

    /// The host's caret moved: the panel and the candidates follow it.
    func caretMoved() {
        if hasMarkedText() { showPanel() }
        context.invalidateCharacterCoordinates()
    }

    private func clearMarked() {
        marked = NSAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        panel.hide()
    }

    private func showPanel() {
        guard let window = view?.window else { return }
        panel.show(marked, selection: markedSelection, at: anchorRect(), font: view?.sink?.caretFont(),
                   over: window)
    }

    /// The host's caret on this screen, or the last click, or the view's corner.
    private func anchorRect() -> NSRect {
        if let caret = view?.sink?.caretScreenRect() { return caret }
        if let clickPoint { return NSRect(x: clickPoint.x, y: clickPoint.y - 9, width: 1, height: 18) }
        guard let view, let window = view.window else { return .zero }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        return NSRect(x: frame.minX + 20, y: frame.minY + 20, width: 1, height: 18)
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard !cancelling else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        clearMarked()
        if handling != nil {
            handling?.inserted += text
        } else {
            // Committed outside a key press (a click on a candidate).
            send(text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !cancelling else { return }
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        markedSelection = selectedRange
        if marked.length == 0 { clearMarked() } else { showPanel() }
    }

    /// The marked text is accepted as it is.
    func unmarkText() {
        guard !cancelling, hasMarkedText() else { return }
        let text = marked.string
        clearMarked()
        if handling != nil { handling?.inserted += text } else { send(text) }
    }

    func doCommand(by selector: Selector) {
        handling?.commanded = true
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { marked.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location < marked.length else { return nil }
        let clipped = NSRange(location: range.location, length: min(range.length, marked.length - range.location))
        actualRange?.pointee = clipped
        return marked.attributedSubstring(from: clipped)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        if hasMarkedText(), let rect = panel.screenRect(forCharacterAt: range.location) { return rect }
        return anchorRect()
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func windowLevel() -> Int { view?.window?.level.rawValue ?? NSWindow.Level.normal.rawValue }
}

/// Shows the text being composed at the host's caret, as if typed there: on
/// the caret's line, from the caret on, in the host text's font and on its
/// baseline when the host reports the font. A window of its own, not a view:
/// a view over the video would slow its presentation.
@MainActor
final class MarkedTextPanel {
    private let panel: NSPanel
    private let label = MarkedTextView()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                        defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = label
    }

    /// - Parameters:
    ///   - caret: the host's caret on this screen (its line's height, and the
    ///     selection's width when text is selected).
    ///   - font: the host text's font at this window's scale, when known.
    func show(_ text: NSAttributedString, selection: NSRange, at caret: NSRect, font: NSFont?, over window: NSWindow) {
        // Without the host's font: the system font, sized from the line.
        let font = font ?? NSFont.systemFont(ofSize: min(28, max(12, (caret.height * 0.8).rounded())))
        label.font = font
        label.text = text
        label.selection = selection
        // The baseline sits where the host's does: half the line's extra
        // height above the text, then the font's ascent.
        let textHeight = font.ascender - font.descender
        let height = max(caret.height, ceil(textHeight))
        label.baseline = ((height - textHeight) / 2 + font.ascender).rounded(.toNearestOrAwayFromZero)
        // At least as wide as the selected text the composition replaces, so it doesn't show beside it.
        let width = max(label.textWidth + MarkedTextView.trailing, caret.width > 1.5 ? caret.width : 0)
        let frame = NSRect(x: caret.minX, y: caret.maxY - height, width: width, height: height)
        panel.setFrame(frame, display: true)
        label.needsDisplay = true
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// The character's place on screen, for the input method's candidates.
    func screenRect(forCharacterAt index: Int) -> NSRect? {
        guard panel.isVisible else { return nil }
        let x = label.offset(ofCharacterAt: index)
        return NSRect(x: panel.frame.minX + x, y: panel.frame.minY, width: 1, height: panel.frame.height)
    }
}

private final class MarkedTextView: NSView {
    /// Room after the text, so the last character isn't cut by the edge.
    static let trailing: CGFloat = 2
    var text = NSAttributedString()
    var selection = NSRange(location: 0, length: 0)
    var font = NSFont.systemFont(ofSize: 13)
    /// From the top of the view.
    var baseline: CGFloat = 0

    override var isFlipped: Bool { true }

    private var styled: NSAttributedString {
        let result = NSMutableAttributedString(string: text.string, attributes: [
            .font: font, .foregroundColor: NSColor.textColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.secondaryLabelColor,
        ])
        // The clause being converted, as the input method marks it.
        let selected = NSIntersectionRange(selection, NSRange(location: 0, length: result.length))
        if selected.length > 0 {
            result.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue,
                                  .underlineColor: NSColor.controlAccentColor], range: selected)
        }
        return result
    }

    var textWidth: CGFloat { ceil(styled.size().width) }

    func offset(ofCharacterAt index: Int) -> CGFloat {
        let string = styled
        let end = min(max(0, index), string.length)
        return string.attributedSubstring(from: NSRange(location: 0, length: end)).size().width
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        // Without .usesLineFragmentOrigin the rect's origin is the first baseline.
        styled.draw(with: NSRect(x: 0, y: baseline, width: bounds.width + 100, height: 0), options: [],
                    context: nil)
    }
}
