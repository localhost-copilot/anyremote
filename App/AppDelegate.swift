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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let hostService = HostService()
    private lazy var tailnet = TailnetService(hostService: hostService)
    private lazy var viewer = ViewerModel(hostService: hostService, tailnet: tailnet)
    private lazy var hostSettings = HostSettingsModel(service: hostService)
    private let keyForwarder = KeyForwarder()
    private let remoteMenuBar = RemoteMenuBar()
    /// The Remote menu's connection line (host, latency, frame rate) and its separator.
    private let connectionItem = NSMenuItem()
    private let connectionSeparator = NSMenuItem.separator()
    private var hostsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var updateWindow: NSWindow?
    private var diagnosticWindows: [NSWindow] = []
    private var statusMenu: StatusMenuController?
    private var dockProxies: DockProxies?
    private var pickerHotKey: GlobalHotKey?
    private var shortcutCapture: SystemShortcutCapture?
    private var inputSourceShortcuts: InputSourceShortcutRelay?
    private var isDevelopmentLaunch = false
    /// Development launches observe mirrors as they open.
    var developmentMirrorHandler: ((MirrorWindowController) -> Void)?
    var developmentDesktopHandler: ((DesktopWindowController) -> Void)?

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
        MainThreadWatchdog.start()
        NSApp.mainMenu = makeMainMenu()
        PermissionGuide.cleanUpStaleEntries()
        let update = SoftwareUpdate.shared
        update.showWindow = { [weak self] in self?.showUpdateWindow() }
        update.activityDescription = { [weak self] in self?.relaunchConsequences() ?? [] }
        if update.isSupported { hostService.updateHandler = SoftwareUpdate.remoteRequestHandler() }
        update.start()
        hostService.onPairingRequest = { [weak self] prompt in
            guard let self else { return }
            PairingCodePanel.show(prompt, service: hostService)
        }
        hostService.onPairingEnded = { id, _ in PairingCodePanel.close(id: id) }
        if hostService.settingsStore.settings.isEnabled {
            do { try hostService.start() } catch {
                log.error("host failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
        tailnet.start()
        statusMenu = StatusMenuController(
            settings: hostSettings, viewer: viewer,
            actions: .init(showPicker: { [weak self] in self?.showHosts() },
                           showSettings: { [weak self] in self?.showSettings() }))
        hostSettings.onStatusChange = { [weak self] _ in self?.statusMenu?.updateIcon() }
        pickerHotKey = GlobalHotKey.pickerShortcut { [weak self] in self?.showHosts() }
        dockProxies = DockProxies(viewer: { [unowned self] in viewer })
        RemoteNotifications.shared.connection = { [unowned self] id in viewer.connections[id] }
        RemoteNotifications.shared.install()
        RemoteStatusItems.shared.connections = { [unowned self] in Array(viewer.connections.values) }
        keyForwarder.install(target: { NSApp.keyWindow?.windowController as? any RemoteKeyTarget })
        viewer.onOpenedMirror = { [weak self] mirror in
            mirror.onMenuBarChange = { [weak self] mirror in self?.updateRemoteMenus(for: mirror) }
            self?.developmentMirrorHandler?(mirror)
        }
        viewer.onOpenedDesktop = { [weak self] desktop in self?.developmentDesktopHandler?(desktop) }
        shortcutCapture = SystemShortcutCapture { NSApp.keyWindow?.windowController is DesktopWindowController }
        inputSourceShortcuts = InputSourceShortcutRelay { NSApp.keyWindow?.windowController is any RemoteKeyTarget }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            nonisolated(unsafe) let unsafeWindow = window
            MainActor.assumeIsolated {
                self?.updateRemoteMenus(for: unsafeWindow?.windowController as? MirrorWindowController)
            }
        }
        isDevelopmentLaunch = DevelopmentLaunch.run(arguments: ProcessInfo.processInfo.arguments, app: self)
        // Opened by a remote app's stand-in (from Spotlight or the Dock): its
        // window is all the person asked for.
        let openedForApp = UserDefaults.standard.bool(forKey: "AnyRemoteOpenedForApp")
        if !isDevelopmentLaunch, !openedForApp {
            showHosts()
            // A Mac that can't be controlled yet: show what's missing instead of
            // firing every system prompt at once.
            if hostService.settingsStore.settings.isEnabled, !HostService.permissions.allGranted { showSettings() }
        }
        if !openedForApp { NSApp.activate() }
    }

    /// The AnyRemote Dock icon always brings the main window back; remote
    /// apps have Dock icons of their own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHosts()
        return true
    }

    // Keep hosting when the last window closes: other Macs may rely on it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutCapture?.release()
        inputSourceShortcuts?.release()
        dockProxies?.quitAll()
        hostService.stop()
        SoftwareUpdate.shared.installOnQuit()
        // The sessions end asynchronously, too late for a quitting app.
        HostService.restoreDefaultInput()
    }

    var viewerModel: ViewerModel { viewer }
    var host: HostService { hostService }

    func showStatusPanel() { statusMenu?.showPanel() }
    var statusPanelFrame: NSRect? { statusMenu?.panelFrame }

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
            window.contentView = NSHostingView(rootView: HostSettingsView(model: hostSettings, tailnet: tailnet))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Task { await SoftwareUpdate.shared.check(userInitiated: true) }
    }

    private func showUpdateWindow() {
        if updateWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = String(localized: "Software Update")
            window.contentView = NSHostingView(rootView: UpdateView(update: .shared) { [weak window] in
                window?.close()
            })
            window.isReleasedWhenClosed = false
            window.center()
            updateWindow = window
        }
        // A background check shouldn't take the keyboard from another app.
        if NSApp.isActive {
            updateWindow?.makeKeyAndOrderFront(nil)
        } else {
            updateWindow?.orderFrontRegardless()
        }
    }

    /// What a relaunch now interrupts, for the update window.
    private func relaunchConsequences() -> [String] {
        var lines: [String] = []
        if let names = hostService.currentStatus.viewerName {
            lines.append(String(localized: "“\(names)” is controlling this Mac and is disconnected until AnyRemote is back."))
        }
        let open = viewer.connections.values.reduce(0) { $0 + $1.openMirrors.count + $1.openDesktops.count }
        if open > 0 {
            lines.append(String(localized: "Remote windows open here close; open them again afterwards."))
        }
        return lines
    }

    private var keyMirror: MirrorWindowController? {
        NSApp.keyWindow?.windowController as? MirrorWindowController
    }

    private var keyDesktop: DesktopWindowController? {
        NSApp.keyWindow?.windowController as? DesktopWindowController
    }

    /// One switch for every remote window and desktop.
    @objc private func toggleStatistics(_ sender: Any?) {
        StatisticsPreferences.isShown.toggle()
    }

    @objc private func closeMirror(_ sender: Any?) {
        keyMirror?.close()
        keyDesktop?.close()
    }

    /// The desktop of the display the key mirror's window is on, or of the
    /// Mac selected in the picker.
    @objc private func openFullDesktop(_ sender: Any?) {
        if let mirror = keyMirror {
            mirror.connection.openDesktop(displayID: mirror.connection.displayID(containing: mirror.stream.frame))
        } else if let connection = viewer.selectedConnection {
            connection.openDesktop()
        }
    }

    @objc private func toggleFitDesktop(_ sender: Any?) { DesktopPreferences.fitsWindow.toggle() }
    @objc private func toggleCaptureShortcuts(_ sender: Any?) { DesktopPreferences.capturesSystemShortcuts.toggle() }

    /// The Remote menu shows how the key remote window's connection is doing.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.contains(connectionItem) else { return }
        let line: String?
        if let mirror = keyMirror {
            line = [mirror.connection.hostName, mirror.connection.routeLabel, mirror.connectionStatus.summary]
                .compactMap { $0 }.joined(separator: " · ")
        } else if let desktop = keyDesktop {
            line = [desktop.connection.hostName, desktop.connection.routeLabel, desktop.connectionStatus.summary]
                .compactMap { $0 }.joined(separator: " · ")
        } else {
            line = nil
        }
        connectionItem.title = line ?? ""
        connectionItem.isHidden = line == nil
        connectionSeparator.isHidden = line == nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleFitDesktop(_:)):
            menuItem.state = DesktopPreferences.fitsWindow ? .on : .off
            return true
        case #selector(toggleCaptureShortcuts(_:)):
            menuItem.state = DesktopPreferences.capturesSystemShortcuts ? .on : .off
            return shortcutCapture?.isAvailable ?? false
        case #selector(openFullDesktop(_:)):
            return keyMirror != nil || viewer.selectedConnection?.state == .connected
        case #selector(toggleStatistics(_:)):
            menuItem.state = StatisticsPreferences.isShown ? .on : .off
            return true
        case #selector(closeMirror(_:)):
            return keyMirror != nil || keyDesktop != nil
        case #selector(checkForUpdates(_:)):
            return SoftwareUpdate.shared.isSupported
        default:
            return true
        }
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let local: NSEvent.ModifierFlags = [.control, .option, .command]

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About AnyRemote"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(checkForUpdates(_:)),
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
        remoteMenu.delegate = self
        connectionItem.isEnabled = false
        remoteMenu.addItem(connectionItem)
        remoteMenu.addItem(connectionSeparator)
        func add(_ title: String, _ action: Selector, _ key: String) {
            let item = remoteMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = local
        }
        add(String(localized: "Open Remote Window…"), #selector(showHosts), "0")
        add(String(localized: "Show Statistics"), #selector(toggleStatistics(_:)), "i")
        add(String(localized: "Open Full Desktop"), #selector(openFullDesktop(_:)), "d")
        add(String(localized: "Fit Desktop to Window"), #selector(toggleFitDesktop(_:)), "r")
        add(String(localized: "Send System Shortcuts to Desktop"), #selector(toggleCaptureShortcuts(_:)), "k")
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
