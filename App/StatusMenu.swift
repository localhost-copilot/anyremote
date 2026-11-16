import AnyRemoteHost
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The menu bar icon and its panel. Clicking it opens `StatusPanelView`:
/// open apps on another Mac, get back to windows open here, and see whether
/// this Mac is being controlled. A Mac mini that is only ever controlled has
/// no reason to show windows, so the host controls live there too. A right
/// click gives a short classic menu for people who expect one.
@MainActor
final class StatusMenuController: NSObject, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings: HostSettingsModel
    private let model: StatusPanelModel
    private let actions: Actions
    private lazy var panel = makePanel()
    /// When the panel last closed because focus moved, so the click on the
    /// icon that moved it doesn't open it again straight away.
    private var closedAt = Date.distantPast

    struct Actions {
        var showPicker: () -> Void
        var showSettings: () -> Void
    }

    init(settings: HostSettingsModel, viewer: ViewerModel, actions: Actions) {
        self.settings = settings
        self.actions = actions
        model = StatusPanelModel(viewer: viewer, host: settings)
        super.init()
        model.actions = .init(dismiss: { [weak self] in self?.closePanel() },
                              showPicker: actions.showPicker, showSettings: actions.showSettings,
                              resize: { [weak self] size in self?.contentChanged(size) })
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        updateIcon()
    }

    func updateIcon() {
        let controlled = settings.status.viewerName != nil
        let enabled = settings.settings.isEnabled
        let name = controlled ? "macwindow.badge.plus" : "macwindow.on.rectangle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AnyRemote")
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: "AnyRemote")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.appearsDisabled = !enabled
        item.button?.toolTip = controlled ? "AnyRemote: " + Self.controlling(settings.status.viewers) : "AnyRemote"
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseDown || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            closePanel()
            showClassicMenu()
        } else if panel.isVisible {
            closePanel()
        } else if Date().timeIntervalSince(closedAt) > 0.3 {
            showPanel()
        }
    }

    /// The SwiftUI content's own size, as it last reported it.
    private var contentSize = CGSize(width: 340, height: 420)

    /// The panel's SwiftUI content, which sizes it.
    private var hosting: NSView?

    func showPanel() {
        model.willShow()
        _ = panel
        // Sized to what it will show before it appears: content that changed
        // while it was hidden (a window opened, a Mac paired) would otherwise
        // only resize it once on screen.
        if let hosting {
            hosting.layoutSubtreeIfNeeded()
            let fitting = hosting.fittingSize
            if fitting.height > 0 { contentSize = CGSize(width: 340, height: fitting.height) }
        }
        placePanel()
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
    }

    var panelFrame: NSRect? { panel.isVisible ? panel.frame : nil }

    /// The content reports its size during SwiftUI's layout pass; resizing
    /// the window right there can leave its content view at the old size
    /// (the window grows, the content stays put and is cut off), so the
    /// frame changes once that pass is over.
    private func contentChanged(_ size: CGSize) {
        contentSize = size
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.placePanel() }
        }
    }

    /// Hangs the panel just below the icon, inside the screen, sized to its content.
    private func placePanel() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = contentSize
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 6 - size.height)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        let frame = NSRect(origin: origin, size: size).integral
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        // The content view always fills the window.
        if let content = panel.contentView, content.frame.size != frame.size {
            content.frame = NSRect(origin: .zero, size: frame.size)
        }
        // The shadow follows the rounded shape at the new size.
        panel.invalidateShadow()
    }

    func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        closedAt = Date()
        closePanel()
    }

    private func makePanel() -> NSPanel {
        let panel = StatusPanel()
        panel.delegate = self
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        // Rounded with the effect view's own mask, which also cuts the blurred
        // backdrop; a layer corner radius leaves it square under the corners,
        // a light fringe around them.
        effect.maskImage = Self.roundedMask(radius: 12)
        let hosting = NSHostingView(rootView: StatusPanelView(model: model))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        self.hosting = hosting
        return panel
    }

    /// A stretchable rounded rectangle: the corners stay, the middle stretches.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func showClassicMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: String(localized: "Open AnyRemote Window"), action: #selector(showPicker), keyEquivalent: "0")
        open.keyEquivalentModifierMask = [.control, .option, .command]
        open.target = self
        menu.addItem(open)
        let settingsItem = NSMenuItem(title: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit AnyRemote"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func showPicker() { actions.showPicker() }
    @objc private func showSettings() { actions.showSettings() }

    /// "“M6” is controlling this Mac", or how many are.
    static func controlling(_ viewers: [HostService.Viewer]) -> String {
        if viewers.count == 1 { return String(localized: "“\(viewers[0].name)” is controlling this Mac") }
        return String(localized: "\(viewers.count) Macs are controlling this Mac")
    }
}

/// A borderless panel that takes typing without making AnyRemote the active
/// app, like Spotlight: the app the user was in stays in front until a remote
/// window actually opens.
private final class StatusPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { (delegate as? StatusMenuController)?.closePanel() }
}

/// A system-wide hot key (Carbon; needs no permission).
@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, context, &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4152_484B), id: 1) // "ARHK"
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0,
                                  &reference) == noErr else { return nil }
    }

    static func pickerShortcut(action: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: kVK_ANSI_0, modifiers: controlKey | optionKey | cmdKey, action: action)
    }
}
