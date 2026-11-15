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
        item.button?.toolTip = controlled ? "AnyRemote：「\(settings.status.viewerName ?? "")」正在控制这台 Mac" : "AnyRemote"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = settings.status

        let header = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let viewer = status.viewerName {
            menu.addItem(action("断开「\(viewer)」", #selector(disconnectViewer)))
        }
        if settings.settings.isEnabled {
            let code = settings.settings.code?.description ?? ""
            let show = action("显示配对码…", #selector(showSettings))
            show.toolTip = code
            menu.addItem(show)
            menu.addItem(action("拷贝配对码", #selector(copyCode)))
        } else {
            menu.addItem(action("允许其他 Mac 控制这台 Mac", #selector(enableSharing)))
        }

        menu.addItem(.separator())
        let open = action("打开远程窗口…", #selector(showPicker))
        open.keyEquivalent = "0"
        open.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(open)
        let mirrors = viewer().allMirrors.sorted { ($0.window?.title ?? "") < ($1.window?.title ?? "") }
        for mirror in mirrors {
            let entry = action(mirror.window?.title ?? "窗口", #selector(focusMirror(_:)))
            entry.representedObject = mirror
            entry.indentationLevel = 1
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let settingsItem = action("设置…", #selector(showSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "退出 AnyRemote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    private var statusLine: String {
        if !settings.settings.isEnabled { return "共享本机：已关闭" }
        if let viewer = settings.status.viewerName { return "「\(viewer)」正在控制这台 Mac" }
        if !settings.permissions.allGranted { return "共享本机：缺少权限" }
        if settings.status.isListening { return "共享本机：等待连接" }
        return "共享本机：正在启动…"
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

    @objc private func focusMirror(_ sender: NSMenuItem) {
        guard let mirror = sender.representedObject as? MirrorWindowController else { return }
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
