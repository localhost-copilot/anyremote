import AnyRemoteHost
import AppKit
import Carbon.HIToolbox

/// The menu bar icon. A Mac mini that is only ever controlled has no reason
/// to show windows, so everything a host needs lives here: whether sharing is
/// on, who is in control (and a way to cut them off), and the pairing code.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings: HostSettingsModel
    private let viewer: () -> ViewerModel
    private let actions: Actions

    struct Actions {
        var showPicker: () -> Void
        var showSettings: () -> Void
    }

    init(settings: HostSettingsModel, viewer: @escaping () -> ViewerModel, actions: Actions) {
        self.settings = settings
        self.viewer = viewer
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
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
        item.button?.toolTip = controlled ? String(localized: "AnyRemote: “\(settings.status.viewerName ?? "")” is controlling this Mac") : "AnyRemote"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = settings.status

        let header = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let viewer = status.viewerName {
            menu.addItem(action(String(localized: "Disconnect “\(viewer)”"), #selector(disconnectViewer)))
        }
        if settings.settings.isEnabled {
            let code = settings.settings.code?.description ?? ""
            let show = action(String(localized: "Show Pairing Code…"), #selector(showSettings))
            show.toolTip = code
            menu.addItem(show)
            menu.addItem(action(String(localized: "Copy Pairing Code"), #selector(copyCode)))
        } else {
            menu.addItem(action(String(localized: "Allow Other Macs to Control This Mac"), #selector(enableSharing)))
        }

        menu.addItem(.separator())
        let open = action(String(localized: "Open Remote Window…"), #selector(showPicker))
        open.keyEquivalent = "0"
        open.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(open)
        let mirrors = ((viewer().allDesktops as [NSWindowController]) + viewer().allMirrors)
            .sorted { ($0.window?.title ?? "") < ($1.window?.title ?? "") }
        for mirror in mirrors {
            let title = mirror.window?.title ?? String(localized: "Window")
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.indentationLevel = 1
            let submenu = NSMenu(title: title)
            let show = action(String(localized: "Bring to Front"), #selector(focusMirror(_:)))
            show.representedObject = mirror
            submenu.addItem(show)
            let close = action(String(localized: "Close on This Mac"), #selector(closeMirror(_:)))
            close.representedObject = mirror
            close.toolTip = String(localized: "The window stays open on the other Mac.")
            submenu.addItem(close)
            entry.submenu = submenu
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let settingsItem = action(String(localized: "Settings…"), #selector(showSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: String(localized: "Quit AnyRemote"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    private var statusLine: String {
        if !settings.settings.isEnabled { return String(localized: "Sharing: Off") }
        if let viewer = settings.status.viewerName { return String(localized: "“\(viewer)” is controlling this Mac") }
        if !settings.permissions.allGranted { return String(localized: "Sharing: Permissions Missing") }
        if settings.status.isListening { return String(localized: "Sharing: Waiting for Connection") }
        return String(localized: "Sharing: Starting…")
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func disconnectViewer() { settings.service.disconnectViewer() }
    @objc private func copyCode() { settings.copyCode() }
    @objc private func showSettings() { actions.showSettings() }
    @objc private func showPicker() { actions.showPicker() }
    @objc private func enableSharing() { settings.setEnabled(true); updateIcon() }

    @objc private func closeMirror(_ sender: NSMenuItem) {
        (sender.representedObject as? NSWindowController)?.close()
    }

    @objc private func focusMirror(_ sender: NSMenuItem) {
        guard let mirror = sender.representedObject as? NSWindowController else { return }
        NSApp.activate()
        mirror.window?.makeKeyAndOrderFront(nil)
    }
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
