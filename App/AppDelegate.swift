import AnyRemoteDiagnostics
import AnyRemoteHost
import AnyRemoteWire
import AppKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "App")

/// Every AnyRemote instance is both a host (others may control this Mac)
/// and a viewer (this Mac controls others).
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hostService = HostService()
    private lazy var viewer = ViewerModel(hostService: hostService)
    private lazy var hostSettings = HostSettingsModel(service: hostService)
    private let keyForwarder = KeyForwarder()
    private let remoteMenuBar = RemoteMenuBar()
    private var hostsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var diagnosticWindows: [NSWindow] = []
    private var statusMenu: StatusMenuController?
    private var pickerHotKey: GlobalHotKey?
    private var isDevelopmentLaunch = false
    /// Development launches observe mirrors as they open.
    var developmentMirrorHandler: ((MirrorWindowController) -> Void)?

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        AppLanguage.applyAtLaunch()
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        if hostService.settingsStore.settings.isEnabled {
            do { try hostService.start() } catch {
                log.error("host failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
        statusMenu = StatusMenuController(
            settings: hostSettings, viewer: { [unowned self] in viewer },
            actions: .init(showPicker: { [weak self] in self?.showHosts() },
                           showSettings: { [weak self] in self?.showSettings() }))
        hostSettings.onStatusChange = { [weak self] _ in self?.statusMenu?.updateIcon() }
        pickerHotKey = GlobalHotKey.pickerShortcut { [weak self] in self?.showHosts() }
        keyForwarder.install(target: { NSApp.keyWindow?.windowController as? MirrorWindowController })
        viewer.onOpenedMirror = { [weak self] mirror in
            mirror.onMenuBarChange = { [weak self] mirror in self?.updateRemoteMenus(for: mirror) }
            self?.developmentMirrorHandler?(mirror)
        }
        // Like Spotlight: once a window is picked, the picker gets out of the way.
        viewer.onPickedWindow = { [weak self] keepPicker in
            if !keepPicker { self?.hostsWindow?.orderOut(nil) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            nonisolated(unsafe) let unsafeWindow = window
            MainActor.assumeIsolated {
                self?.updateRemoteMenus(for: unsafeWindow?.windowController as? MirrorWindowController)
            }
        }
        isDevelopmentLaunch = DevelopmentLaunch.run(arguments: ProcessInfo.processInfo.arguments, app: self)
        if !isDevelopmentLaunch {
            showHosts()
            // A Mac that can't be controlled yet: show what's missing instead of
            // firing every system prompt at once.
            if hostService.settingsStore.settings.isEnabled, !HostService.permissions.allGranted { showSettings() }
        }
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showHosts() }
        return true
    }

    // Keep hosting when the last window closes: other Macs may rely on it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        hostService.stop()
    }

    var viewerModel: ViewerModel { viewer }
    var host: HostService { hostService }

    func keepDiagnosticWindow(_ window: NSWindow) { diagnosticWindows.append(window) }

    func installRemoteMenus(for mirror: MirrorWindowController) {
        if let mainMenu = NSApp.mainMenu { remoteMenuBar.install(for: mirror, in: mainMenu) }
    }

    private func updateRemoteMenus(for mirror: MirrorWindowController?) {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Only the key mirror's menus are shown; other windows get ours back.
        if let mirror, NSApp.keyWindow?.windowController !== mirror { return }
        remoteMenuBar.install(for: mirror, in: mainMenu)
    }

    // MARK: Windows

    @objc func showHosts() {
        if hostsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "AnyRemote"
            window.toolbarStyle = .unified
            window.contentView = NSHostingView(rootView: HostsView(model: viewer))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("AnyRemoteHosts")
            if window.frame.origin == .zero { window.center() }
            hostsWindow = window
        }
        NSApp.activate()
        hostsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = String(localized: "AnyRemote Settings")
            window.contentView = NSHostingView(rootView: HostSettingsView(model: hostSettings))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private var keyMirror: MirrorWindowController? {
        NSApp.keyWindow?.windowController as? MirrorWindowController
    }

    @objc private func toggleStatistics(_ sender: Any?) { keyMirror?.toggleStatistics() }
    @objc private func closeMirror(_ sender: Any?) { keyMirror?.close() }

    @objc private func openFullDesktop(_ sender: Any?) {
        if let mirror = keyMirror { FullDesktop.open(mirror.connection) }
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let local: NSEvent.ModifierFlags = [.control, .option, .command]

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About AnyRemote"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide AnyRemote"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "Quit AnyRemote"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Text fields (pairing code, search) need the standard edit commands.
        // While a mirror is key, the key forwarder sends these keys to the host.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // Our controls. While a mirror is key every other shortcut goes to the
        // host, so these use ⌃⌥⌘.
        let remoteItem = NSMenuItem()
        let remoteMenu = NSMenu(title: RemoteMenuBar.ownMenuTitle)
        func add(_ title: String, _ action: Selector, _ key: String) {
            let item = remoteMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = local
        }
        add(String(localized: "Open Remote Window…"), #selector(showHosts), "0")
        add(String(localized: "Show Statistics"), #selector(toggleStatistics(_:)), "i")
        add(String(localized: "Open Full Desktop"), #selector(openFullDesktop(_:)), "d")
        remoteMenu.addItem(.separator())
        add(String(localized: "Close on This Mac"), #selector(closeMirror(_:)), "w")
        remoteItem.submenu = remoteMenu
        main.addItem(remoteItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}
