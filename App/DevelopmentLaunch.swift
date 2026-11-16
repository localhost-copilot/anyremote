import AnyRemoteDiagnostics
import AnyRemoteHost
import AnyRemoteWire
import AppKit

/// Command-line launches used for development and measurement:
///
///     --synthetic 940x700 [--resize-test] [--display-test]   mirror a synthetic window of this Mac
///     --input-test                          inject clicks, keys, scroll and a context menu into a recorder window
///     --open <application> [--title <text>] [--menu-test [--choose Menu/Item]]
///                                           mirror a window of this Mac (or of the --connect host)
///     --launch <application>                open an app on the host and mirror its first window
///     --quit <application>                  quit a running app on the host
///     --desktop [--display <index>]         show the host's whole desktop (main display, or the n-th)
///         [--test-display WxH]              ...of a virtual display made for the test (so dynamic
///                                           resolution leaves this Mac's own screens alone)
///         [--desktop-size WxH]              then resize the desktop window to that content size
///         [--fullscreen]                    make the desktop window full screen
///         [--shortcut-test]                 post ⌘Tab and ⌘Space and print what the desktop forwards
///     -DesktopFitsWindow NO                 turn dynamic resolution off for this launch
///     --connect host[:port] --code CODE     connect to another Mac
///     --discovery-test                      print the hosts Bonjour finds
///     --open <application> --gesture-test   pinch, rotate and smart-zoom the mirror (as AppKit would
///                                           deliver them) so the host app gets them
///     --open <application> --status-items-test <menu app> <popup app>
///                                           list the menu bar items, open one app's menu and
///                                           another's popover (closing both without choosing)
///     --open <application> --status-menu-demo
///                                           show a sample menu of the other Mac under its icon
///     --notification-test                   post a notification on this Mac and print what the
///                                           viewer receives, the Dock badges, and an open request
///     --permission-guide                    show Settings and the permission guide card
///     --video-caps <Mbps|auto,…>            after connecting, cap the video from the host at each
///                                           value in turn, 8 s apart (needs a paired --connect host)
///     --exit-after <seconds>
///
/// Set ANYREMOTE_STATS_STDOUT=1 to print pipeline statistics every second,
/// ANYREMOTE_HOME to use a separate settings directory.
@MainActor
enum DevelopmentLaunch {
    private static var testDisplay: VirtualDisplay?

    /// Returns true when the arguments asked for a development launch.
    static func run(arguments: [String], app: AppDelegate) -> Bool {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let seconds = value("--exit-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
        let permissions = HostService.permissions
        print("dev: permissions screen=\(permissions.screenRecording) ax=\(permissions.accessibility) "
              + "post=\(permissions.postEvents)")
        if arguments.contains("--permission-guide") {
            app.showSettings()
            PermissionGuide.shared.isPreview = true
            PermissionGuide.shared.start(.accessibility)
            return true
        }
        if arguments.contains("--settings") {
            app.showSettings()
            return true
        }
        if arguments.contains("--status-panel") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                app.showStatusPanel()
                // The panel's frame in screen points from the top left, for `screencapture -R`.
                for _ in 0..<20 {
                    try? await Task.sleep(for: .seconds(1))
                    if let frame = app.statusPanelFrame, let screen = NSScreen.screens.first {
                        print("dev: status panel \(Int(frame.minX)),\(Int(screen.frame.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
                    }
                }
            }
            return true
        }
        if arguments.contains("--discovery-test") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let own = app.host.settingsStore.settings.hostID
                for host in app.viewerModel.discovered {
                    print("discovery-test: \(host.name) id=\(host.hostID ?? "-") self=\(host.hostID == own) \(host.endpoint)")
                }
                print("discovery-test: \(app.viewerModel.discovered.count) found")
            }
            return true
        }
        var synthetic = value("--synthetic").flatMap(parseSize)
        var recorder: InputRecorderWindow?
        if arguments.contains("--input-test") {
            let window = InputRecorderWindow()
            recorder = window
            app.keepDiagnosticWindow(window)
            synthetic = nil
            app.host.allowOwnWindow(CGWindowID(window.windowNumber))
            app.developmentMirrorHandler = { mirror in InputTest.run(mirror, recorder: window) }
        }
        let application = value("--open")
        let connectAddress = value("--connect")
        let launch = value("--launch")
        let quit = value("--quit")
        let desktop = arguments.contains("--desktop")
        var testDisplayID: UInt32?
        if let size = value("--test-display").flatMap(parseSize),
           let display = VirtualDisplay(pointSize: size, maximumPointSize: size, name: "AnyRemote Test", productID: 0xFFFF) {
            display.makeExtended()
            testDisplay = display
            testDisplayID = display.displayID
            print("dev: test display \(display.displayID) \(display.bounds)")
        }
        // Several sizes, comma-separated; "off" gives the display its own size back.
        let desktopSizes = value("--desktop-size")?.split(separator: ",").map { $0 == "off" ? nil : parseSize(String($0)) } ?? []
        let notificationTest = arguments.contains("--notification-test")
        guard synthetic != nil || recorder != nil || application != nil || connectAddress != nil || launch != nil
                || quit != nil || desktop || notificationTest
        else { return false }
        if desktop {
            app.developmentDesktopHandler = { desktop in
                print("dev: desktop opened \(desktop.stream.title) \(desktop.stream.frame)")
                // Keep a synthetic workload unoccluded (occluded windows are throttled).
                if synthetic != nil, let window = desktop.window, let screen = window.screen {
                    let visible = screen.visibleFrame
                    window.setContentSize(NSSize(width: 800, height: 450))
                    window.setFrameTopLeftPoint(NSPoint(x: visible.maxX - window.frame.width, y: visible.minY + window.frame.height))
                }
                if arguments.contains("--fullscreen") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        desktop.window?.toggleFullScreen(nil)
                    }
                }
                if arguments.contains("--ime-test") {
                    runInputMethodTest(desktop, arguments: arguments)
                    return
                }
                if arguments.contains("--shortcut-test") {
                    desktop.inputTap = { event in
                        if case let .key(keyCode, down, _, modifiers) = event {
                            print("dev: forwarded key \(keyCode) down=\(down) flags=\(String(modifiers, radix: 16))")
                        }
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        NSApp.activate()
                        desktop.window?.makeKeyAndOrderFront(nil)
                        try? await Task.sleep(for: .milliseconds(500))
                        for _ in 0..<20 where !NSApp.isActive {
                            NSRunningApplication.current.activate(options: [])
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                        desktop.window?.makeKeyAndOrderFront(nil)
                        try? await Task.sleep(for: .milliseconds(300))
                        print("dev: key window is desktop: \(NSApp.keyWindow === desktop.window), active \(NSApp.isActive)")
                        // Without the capture these would act on this Mac.
                        guard NSApp.keyWindow === desktop.window, NSApp.isActive else { return }
                        for keyCode: CGKeyCode in [48, 49] { // Tab, Space
                            let source = CGEventSource(stateID: .hidSystemState)
                            for down in [true, false] {
                                let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
                                event?.flags = .maskCommand
                                event?.post(tap: .cghidEventTap)
                                try? await Task.sleep(for: .milliseconds(80))
                            }
                            try? await Task.sleep(for: .milliseconds(400))
                        }
                        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                        print("dev: frontmost after shortcuts: \(front)")
                    }
                    return
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    let content = desktop.window?.contentLayoutRect.size ?? .zero
                    print("dev: desktop window content \(Int(content.width))x\(Int(content.height)) "
                          + "drawable \(desktop.surface.frameLayer.drawableSize)")
                    // Pointer mapping: a move to a display point must land there on the host.
                    let target = CGPoint(x: 321, y: 234)
                    desktop.sendInput(.mouseMove(point: target, pressedButtons: 0, modifiers: 0))
                    try? await Task.sleep(for: .milliseconds(300))
                    let location = CGEvent(source: nil)?.location ?? .zero
                    let origin = desktop.stream.frame.origin
                    print("dev: desktop input moved to \(location) (wanted \(CGPoint(x: origin.x + target.x, y: origin.y + target.y)))")
                    for desktopSize in desktopSizes {
                    guard let window = desktop.window else { return }
                    if let desktopSize {
                        window.setContentSize(desktopSize)
                        print("dev: desktop window resized to \(desktopSize)")
                    } else {
                        desktop.connection.client.setDesktopSize(streamID: desktop.streamID, size: nil)
                        print("dev: desktop size off")
                    }
                    try? await Task.sleep(for: .seconds(3))
                    print("dev: desktop now \(desktop.stream.frame) drawable \(desktop.surface.frameLayer.drawableSize) window \(window.windowNumber)")
                    var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
                    CGGetOnlineDisplayList(16, &ids, &count)
                    print("dev: displays now " + ids.prefix(Int(count)).map { id in
                        let mode = CGDisplayCopyDisplayMode(id)
                        return "\(id) \(CGDisplayBounds(id)) px \(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0) mirrors \(CGDisplayMirrorsDisplay(id))"
                    }.joined(separator: ", "))
                    }
                }
            }
        }

        let model = app.viewerModel
        var syntheticWindowID = recorder.map { UInt32($0.windowNumber) }
        if let synthetic {
            let window = SyntheticWorkloadWindow.open(size: synthetic, origin: CGPoint(x: 40, y: 120))
            app.keepDiagnosticWindow(window)
            syntheticWindowID = UInt32(window.windowNumber)
            app.host.allowOwnWindow(CGWindowID(window.windowNumber))
        }
        if arguments.contains("--display-test") {
            app.developmentMirrorHandler = { mirror in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    for screen in NSScreen.screens {
                        print("display-test: screen \(screen.localizedName) \(Int(screen.frame.width))x\(Int(screen.frame.height))pt "
                              + "@\(Int(screen.backingScaleFactor))x")
                    }
                    for window in NSApp.windows where window.title.contains("synthetic") {
                        print("display-test: synthetic window on \(window.screen?.localizedName ?? "?") at \(window.frame)")
                    }
                    print("display-test: host stream frame \(mirror.stream.frame)")
                    var count: UInt32 = 0
                    CGGetOnlineDisplayList(0, nil, &count)
                    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
                    CGGetOnlineDisplayList(count, &ids, &count)
                    for id in ids {
                        print("display-test: display \(id) bounds \(CGDisplayBounds(id)) main=\(CGDisplayIsMain(id)) "
                              + "mirrorSet=\(CGDisplayIsInMirrorSet(id)) mirrors=\(CGDisplayMirrorsDisplay(id))")
                    }
                }
            }
        }
        if arguments.contains("--menu-test") {
            app.developmentMirrorHandler = { mirror in MenuTest.run(mirror, app: app, choose: value("--choose")) }
        }
        if arguments.contains("--resize-test") {
            app.developmentMirrorHandler = { mirror in ResizeTest.run(mirror) }
        }
        if let point = value("--caret-test") {
            app.developmentMirrorHandler = { mirror in CaretTest.run(mirror, click: point, rename: arguments.contains("--rename"),
                                                                         renameClick: value("--rename-click")) }
        }
        if let point = value("--host-ime-test") {
            app.developmentMirrorHandler = { mirror in HostInputMethodTest.run(mirror, click: point) }
        }
        if arguments.contains("--fullscreen"), app.developmentMirrorHandler == nil {
            app.developmentMirrorHandler = { mirror in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    mirror.window?.makeKeyAndOrderFront(nil)
                    mirror.window?.toggleFullScreen(nil)
                    try? await Task.sleep(for: .seconds(2))
                    print("dev: mirror full screen \(mirror.window?.styleMask.contains(.fullScreen) ?? false)")
                }
            }
        }
        if arguments.contains("--text-test") {
            app.developmentMirrorHandler = { mirror in TextTest.run(mirror) }
        }
        if let menuApp = value("--status-items-test") {
            let popupApp = arguments.drop { $0 != "--status-items-test" }.dropFirst(2).first
            app.developmentMirrorHandler = { mirror in StatusItemsTest.run(mirror, menuApp: menuApp, popupApp: popupApp) }
        }
        if arguments.contains("--status-menu-demo") {
            app.developmentMirrorHandler = { mirror in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    RemoteStatusItems.shared.showMenu([
                        MenuNode(title: "Start New Session", children: [MenuNode(title: "Indefinitely"),
                                                                        MenuNode(title: "5 minutes")]),
                        MenuNode(title: "", isSeparator: true),
                        MenuNode(title: "Allow Display Sleep", mark: "✓"),
                        MenuNode(title: "Settings…", keyEquivalent: ",", keyModifiers: 0),
                        MenuNode(title: "Quit", isEnabled: false),
                    ], itemID: "demo", from: mirror.connection)
                }
            }
        }
        if arguments.contains("--gesture-test") {
            app.developmentMirrorHandler = { mirror in GestureTest.run(mirror) }
        }

        Task { @MainActor in
            let target: HostTarget
            if let connectAddress {
                guard let endpoint = HostTarget.endpoint(fromAddress: connectAddress),
                      let code = value("--code").flatMap(PairingCode.init) else {
                    print("dev: --connect needs a valid address and --code"); return
                }
                // A host paired at this address keeps its settings (such as the video cap).
                let paired = model.pairedStore.all.first { $0.address == connectAddress }
                target = HostTarget(id: "dev:\(connectAddress)", name: connectAddress, kind: .saved, endpoint: endpoint,
                                    savedID: paired?.id)
                await model.connect(target, code: code)
            } else {
                model.showsThisMac = true
                guard let thisMac = model.thisMacTarget else { print("dev: hosting is off"); return }
                target = thisMac
                await model.connect(target)
            }
            model.selection = target.id
            app.showHosts()
            if arguments.contains("--update-host") {
                let before = model.connection(for: target)?.hostVersion
                print("dev: host runs \(before.map { "\($0.appVersion) (protocol \($0.protocolVersion))" } ?? "unknown")")
                await model.updateHost(target, code: value("--code").flatMap(PairingCode.init))
                let after = model.connection(for: target)
                print("dev: update \(model.remoteUpdates[target.id].map { "\($0)" } ?? "done"), "
                      + "host runs \(after?.hostVersion?.appVersion ?? "unknown"), state \(String(describing: after?.state))")
                return
            }
            guard let connection = model.connection(for: target), connection.state == .connected else {
                print("dev: connect failed: \(model.lastError ?? "unknown")"); return
            }
            print("dev: connected to \(connection.hostName)")
            if let caps = value("--video-caps") {
                let steps = caps.split(separator: ",").map { $0 == "auto" ? nil : Int($0).map { $0 * 1_000_000 } }
                Task { @MainActor in
                    for step in steps {
                        try? await Task.sleep(for: .seconds(8))
                        print("dev: video cap \(step.map { "\($0 / 1_000_000) Mbps" } ?? "automatic")")
                        model.setMaximumBitRate(target, step)
                    }
                }
            }
            if notificationTest {
                await NotificationTest.run(connection)
                return
            }
            if desktop {
                let displays = connection.displays
                print("dev: displays " + displays.map { "\($0.displayID) \($0.name ?? "?") \($0.frame)" }.joined(separator: ", "))
                let index = value("--display").flatMap(Int.init) ?? 0
                connection.openDesktop(displayID: testDisplayID ?? (displays.indices.contains(index) ? displays[index].displayID : nil))
                return
            }
            if let quit {
                await connection.loadApplications()
                guard let match = connection.applications?.applications.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(quit) == .orderedSame
                }) else { print("dev: app not found"); return }
                print("dev: quitting \(match.name) running=\(match.isRunning)")
                connection.quit(match, force: false)
                try? await Task.sleep(for: .seconds(2.5))
                let after = connection.applications?.applications.first { $0.path == match.path }
                print("dev: after quit running=\(after?.isRunning ?? false)")
                return
            }
            if let launch {
                var listStart = Date()
                await connection.loadApplications()
                let apps = connection.applications?.applications ?? []
                let listed = Date().timeIntervalSince(listStart) * 1000
                // Every icon at once: the most the transfer connection is asked for.
                listStart = Date()
                let icons = await connection.client.fetchImages(apps.map { .applicationIcon(path: $0.path) })
                print(String(format: "dev: %d apps in %.0f ms; %d icons (%d KB) in %.0f ms, rtt %.1f ms",
                             apps.count, listed, icons.count, icons.values.reduce(0) { $0 + $1.count } / 1024,
                             Date().timeIntervalSince(listStart) * 1000, connection.client.roundTripMilliseconds ?? -1))
                guard let match = apps.first(where: { $0.name.localizedCaseInsensitiveCompare(launch) == .orderedSame })
                else { print("dev: app not found"); return }
                print("dev: launching \(match.name) running=\(match.isRunning) \(match.path)")
                let start = Date()
                let picked = model.onPickedWindow
                model.onPickedWindow = { keep in
                    picked?(keep)
                    print(String(format: "dev: launched window opened after %.1f s", Date().timeIntervalSince(start)))
                }
                model.launch(match, on: connection, keepPicker: false)
                return
            }
            guard syntheticWindowID != nil || application != nil else { return }
            let title = value("--title")
            for _ in 0..<20 {
                let windows = connection.listing?.windows ?? []
                let match = windows.first { window in
                    if let syntheticWindowID { return window.windowID == syntheticWindowID }
                    guard window.applicationName.localizedCaseInsensitiveContains(application ?? "") else { return false }
                    return title.map { window.title.localizedCaseInsensitiveContains($0) } ?? true
                }
                if let match {
                    print("dev: opening \(match.windowID) \(match.applicationName) “\(match.title)”")
                    connection.open(match)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                await connection.refresh()
                print("dev: \(connection.listing?.windows.count ?? 0) windows, \(connection.thumbnails.count) thumbnails, "
                      + "\(connection.windowIcons.count) icons")
            }
            print("dev: window not found")
        }
        return true
    }

    /// `--status-items-test`: the other Mac's menu bar items through this
    /// Mac's icon for it.
    @MainActor private enum StatusItemsTest {
        static func run(_ mirror: MirrorWindowController, menuApp: String, popupApp: String?) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                let connection = mirror.connection
                let start = Date()
                guard let items = try? await connection.client.listStatusItems() else {
                    return print("status-items-test: listing failed")
                }
                print(String(format: "status-items-test: %d items in %.0f ms", items.count,
                             Date().timeIntervalSince(start) * 1000))
                if let png = items.first(where: { $0.image != nil })?.image {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("status-item-icon.png")
                    try? png.write(to: url)
                    print("status-items-test: icon \(NSImage(data: png)?.size ?? .zero) written to \(url.path)")
                }
                for item in items {
                    print("status-items-test:   \(item.id) \(item.applicationName) “\(item.title)” "
                          + "picture=\(item.image?.count ?? 0) bytes \(item.frame)")
                }
                RemoteStatusItems.shared.onMenu = { id, nodes in
                    print("status-items-test: menu of \(id): " + nodes.prefix(6).map(\.title).joined(separator: " | "))
                }
                RemoteStatusItems.shared.onPopup = { popup in
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        print("status-items-test: popup \(popup.stream.frame) shown at \(popup.window?.frame ?? .zero) "
                              + "visible=\(popup.window?.isVisible ?? false) window=\(popup.window?.windowNumber ?? 0)")
                        try? await Task.sleep(for: .seconds(4))
                        popup.close()
                        print("status-items-test: popup closed here")
                    }
                }
                if let item = items.first(where: { $0.applicationName.localizedCaseInsensitiveContains(menuApp) }) {
                    RemoteStatusItems.shared.open(item, from: connection)
                }
                try? await Task.sleep(for: .seconds(2))
                if let popupApp, let item = items.first(where: { $0.applicationName.localizedCaseInsensitiveContains(popupApp) }) {
                    RemoteStatusItems.shared.open(item, from: connection)
                }
            }
        }
    }

    /// `--gesture-test`: trackpad gesture events made the way the window
    /// server makes them, handed to the mirror's view as AppKit would.
    @MainActor private enum GestureTest {
        static func run(_ mirror: MirrorWindowController) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                let view = mirror.surface
                guard let window = view.window else { return }
                let center = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
                // CGEvent locations count from the top of the main screen.
                let location = CGPoint(x: center.x, y: (NSScreen.screens.first?.frame.height ?? 0) - center.y)
                func event(_ hidType: Int64, phase: Int64, zoom: Double = 0, rotation: Double = 0) -> NSEvent? {
                    func field(_ value: UInt32) -> CGEventField { unsafeBitCast(value, to: CGEventField.self) }
                    guard let event = CGEvent(source: nil) else { return nil }
                    event.type = unsafeBitCast(UInt32(29), to: CGEventType.self)
                    event.location = location
                    event.setIntegerValueField(field(110), value: hidType)
                    // Zoom and rotation share their storage: set only the gesture's own.
                    if hidType == 8 { event.setDoubleValueField(field(113), value: zoom) }
                    if hidType == 5 { event.setDoubleValueField(field(114), value: rotation) }
                    event.setIntegerValueField(field(132), value: phase)
                    return NSEvent(cgEvent: event)
                }
                var sequence: [NSEvent?] = [event(8, phase: 1)]
                sequence += (0..<4).map { _ in event(8, phase: 2, zoom: 0.1) }
                sequence += [event(8, phase: 4), event(5, phase: 1), event(5, phase: 2, rotation: 15), event(5, phase: 4),
                             event(22, phase: 0)]
                for case let event? in sequence {
                    switch event.type {
                    case .magnify: view.magnify(with: event)
                    case .rotate: view.rotate(with: event)
                    case .smartMagnify: view.smartMagnify(with: event)
                    default: print("gesture-test: unexpected event type \(event.type.rawValue)")
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                print("gesture-test: sent \(sequence.count) gesture events")
            }
        }
    }

    /// `--notification-test`: a notification posted on the host (this Mac)
    /// must arrive once, with the app it came from.
    @MainActor private enum NotificationTest {
        static func run(_ connection: HostConnection) async {
            var arrived: [HostNotification] = []
            RemoteNotifications.shared.onArrival = { notification in
                arrived.append(notification)
                print("notification-test: arrived from \(notification.applicationName) "
                      + "bundle=\(notification.bundleIdentifier ?? "-") path=\(notification.applicationPath ?? "-") "
                      + "title=“\(notification.title)” subtitle=“\(notification.subtitle)” body=“\(notification.body)” "
                      + "icon=\(notification.icon?.count ?? 0) bytes")
            }
            try? await Task.sleep(for: .seconds(3))
            print("notification-test: badges " + connection.badges.map { "\($0.applicationName)=\($0.label) [\($0.bundleIdentifier ?? "-")]" }
                .joined(separator: ", "))
            let script = Process()
            script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            script.arguments = ["-e", "display notification \"Body, with a comma\" with title \"AnyRemote test\" subtitle \"Sub\""]
            try? script.run()
            script.waitUntilExit()
            try? await Task.sleep(for: .seconds(3))
            print("notification-test: \(arrived.count) arrived")
            // A banner that is gone: the host only logs it (the click path without opening anything here).
            connection.client.send(.openNotification(id: "00000000-0000-0000-0000-000000000000", applicationPath: nil))
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// `--desktop --ime-test`: types through this Mac's input method into the
    /// desktop window and prints what would go to the host.
    private static func runInputMethodTest(_ desktop: DesktopWindowController, arguments: [String]) {
        desktop.inputTap = { event in
            switch event {
            case let .key(keyCode, down, _, _): print("dev: ime key \(keyCode) \(down ? "down" : "up")")
            case let .text(text): print("dev: ime text \(text)")
            default: break
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<20 where !NSApp.isActive {
                NSRunningApplication.current.activate(options: [])
                try? await Task.sleep(for: .milliseconds(250))
            }
            for _ in 0..<10 where NSApp.keyWindow !== desktop.window {
                NSApp.activate(ignoringOtherApps: true)
                desktop.window?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard NSApp.keyWindow === desktop.window else {
                return print("dev: ime desktop not key (active \(NSApp.isActive), key \(String(describing: NSApp.keyWindow)))")
            }
            let source = CGEventSource(stateID: .hidSystemState)
            func post(_ keyCode: CGKeyCode, flags: CGEventFlags = []) async {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
                    event?.flags = flags
                    event?.post(tap: .cghidEventTap)
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
            func shiftTap() async {
                for flags: CGEventFlags in [.maskShift, []] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: !flags.isEmpty)
                    event?.type = .flagsChanged
                    event?.flags = flags
                    event?.post(tap: .cghidEventTap)
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
            if arguments.contains("--ime-hold") {
                // Leaves "nihao" composing at a pretend host caret, for a screenshot.
                desktop.setCaret(CGRect(x: 300, y: 200, width: 1, height: 18), font: nil)
                for keyCode: CGKeyCode in [45, 34, 4, 0, 31] { await post(keyCode) }
                return print("dev: ime holding")
            }
            for round in 0..<2 {
                print("dev: ime round \(round), composes \(LocalInputSource.composes)")
                for keyCode: CGKeyCode in [45, 34, 4, 0, 31, 49, 43, 36, 123] { await post(keyCode) } // nihao␣,⏎←
                try? await Task.sleep(for: .milliseconds(300))
                await shiftTap()
            }
            print("dev: ime ⌃Space")
            await post(49, flags: .maskControl)
            try? await Task.sleep(for: .milliseconds(500))
            print("dev: ime composes after ⌃Space \(LocalInputSource.composes)")
            await post(49, flags: .maskControl)
            try? await Task.sleep(for: .milliseconds(500))
            print("dev: ime composes after second ⌃Space \(LocalInputSource.composes)")
        }
    }

    private static func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
}

/// Resizes the mirror through a series of sizes and reports how the host followed.
/// `--open <app> --text-test`: clicks into the host window, types composed
/// text there and prints the caret the host reports.
@MainActor
enum TextTest {
    static func run(_ mirror: MirrorWindowController) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            let size = mirror.stream.frame.size
            let p = CGPoint(x: size.width / 2, y: size.height / 2)
            mirror.sendInput(.mouseDown(point: p, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0))
            mirror.sendInput(.mouseUp(point: p, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0))
            try? await Task.sleep(for: .milliseconds(500))
            print("text-test: caret after click \(String(describing: mirror.caret))")
            mirror.sendInput(.text("你好，世界"))
            mirror.sendInput(.key(keyCode: 49, down: true, isRepeat: false, modifiers: 0))
            mirror.sendInput(.key(keyCode: 49, down: false, isRepeat: false, modifiers: 0))
            mirror.sendInput(.text("これは長い日本語のテキストで二十文字を超えるかどうかを確かめます👍🏽"))
            try? await Task.sleep(for: .milliseconds(600))
            print("text-test: caret after typing \(String(describing: mirror.caret))")
            if let rect = mirror.caretScreenRect() { print("text-test: caret on screen \(rect)") }
        }
    }
}

/// `--open <app> --caret-test x,y`: moves the mirror off the host window,
/// clicks at that window point, then types `nihao` through this Mac's input
/// method into the mirror and prints where the composition panel went.
/// `--rename` waits for a Finder rename started from outside; with
/// `--rename-click x,y` it then clicks into the field there, types x and Return.
@MainActor
enum CaretTest {
    private static var started = false

    static func run(_ mirror: MirrorWindowController, click: String, rename: Bool, renameClick: String? = nil) {
        // Windows the test's input opens show up as mirrors too: test only the first.
        guard !started else { return }
        started = true
        let parts = click.split(separator: ",").compactMap { Double($0) }
        guard let window = mirror.window, let screen = window.screen else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            // Clicks injected on the host must not land on the mirror itself.
            window.setFrameTopLeftPoint(NSPoint(x: screen.frame.maxX - window.frame.width - 20, y: screen.frame.maxY - 60))
            try? await Task.sleep(for: .milliseconds(300))
            if parts.count == 2 {
                let p = CGPoint(x: parts[0], y: parts[1])
                mirror.sendInput(.mouseDown(point: p, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0))
                mirror.sendInput(.mouseUp(point: p, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0))
                try? await Task.sleep(for: .milliseconds(700))
            }
            if rename {
                // Finder's rename field, started from outside meanwhile: a small window of its own.
                print("caret-test: waiting for a rename")
                try? await Task.sleep(for: .seconds(3))
                // A mouse release makes the host look the caret up (as after a click).
                mirror.sendInput(.mouseUp(point: CGPoint(x: -50, y: -50), button: .left, buttonNumber: 0,
                                          clickCount: 1, modifiers: 0))
                try? await Task.sleep(for: .milliseconds(600))
                let point = renameClick?.split(separator: ",").compactMap { Double($0) } ?? []
                if point.count == 2 {
                    // Click inside the field to move its caret, type x, and press Return.
                    let p = CGPoint(x: point[0], y: point[1])
                    mirror.sendInput(.mouseDown(point: p, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0))
                    mirror.sendInput(.mouseUp(point: p, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0))
                    try? await Task.sleep(for: .milliseconds(400))
                    for code: UInt16 in [7, 36] {
                        mirror.sendInput(.key(keyCode: code, down: true, isRepeat: false, modifiers: 0))
                        mirror.sendInput(.key(keyCode: code, down: false, isRepeat: false, modifiers: 0))
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    print("caret-test: clicked into the rename field, typed x and Return")
                    return
                }
                let children = window.childWindows?.filter { $0 is ChildPanel && $0.isVisible }.map(\.frame) ?? []
                print("caret-test: child windows \(children)")
            }
            for _ in 0..<10 where NSApp.keyWindow !== window {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(300))
            }
            print("caret-test: caret \(String(describing: mirror.caret)) font \(String(describing: mirror.caretFont()))")
            let source = CGEventSource(stateID: .hidSystemState)
            for keyCode: CGKeyCode in [45, 34, 4, 0, 31] {
                for down in [true, false] {
                    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)?.post(tap: .cghidEventTap)
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
            let frame = window.frame
            print("caret-test: mirror window \(frame), caret on screen \(String(describing: mirror.caretScreenRect()))")
            print("caret-test: panel \(window.childWindows?.filter { $0 is NSPanel && $0.isVisible }.map(\.frame) ?? [])")
            // For screencapture -R: the window in top-left global points.
            let top = (NSScreen.screens.first?.frame.height ?? 0) - frame.maxY
            print("caret-test: capture \(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))")
        }
    }
}

/// `--open <app> --host-ime-test x,y` (with `-ComposesOnThisMac NO`): clicks
/// at that window point, sends the keys of `nihao` for the host's input
/// method, prints the child windows that came back (its candidates), then
/// tries Shift (its English mode) and Escape.
@MainActor
enum HostInputMethodTest {
    private static var started = false

    static func run(_ mirror: MirrorWindowController, click: String) {
        guard !started else { return }
        started = true
        let parts = click.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, let window = mirror.window, let screen = window.screen else { return }
        func key(_ code: UInt16) {
            mirror.sendInput(.key(keyCode: code, down: true, isRepeat: false, modifiers: 0))
            mirror.sendInput(.key(keyCode: code, down: false, isRepeat: false, modifiers: 0))
        }
        func children() -> [NSRect] {
            window.childWindows?.filter { $0 is ChildPanel && $0.isVisible }.map(\.frame) ?? []
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            window.setFrameTopLeftPoint(NSPoint(x: screen.frame.maxX - window.frame.width - 20, y: screen.frame.maxY - 60))
            print("host-ime-test: composes here \(TextInputPreferences.composesOnThisMac)")
            try? await Task.sleep(for: .milliseconds(300))
            let p = CGPoint(x: parts[0], y: parts[1])
            mirror.sendInput(.mouseDown(point: p, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0))
            mirror.sendInput(.mouseUp(point: p, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0))
            try? await Task.sleep(for: .milliseconds(500))
            for code: UInt16 in [45, 34, 4, 0, 31] {
                key(code)
                try? await Task.sleep(for: .milliseconds(80))
            }
            try? await Task.sleep(for: .milliseconds(1200))
            let frame = window.frame
            let top = (NSScreen.screens.first?.frame.height ?? 0) - frame.maxY
            print("host-ime-test: mirror \(frame), capture \(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))")
            print("host-ime-test: child windows while composing \(children())")
            try? await Task.sleep(for: .seconds(3))
            key(49) // Space: the first candidate
            try? await Task.sleep(for: .milliseconds(800))
            print("host-ime-test: child windows after Space \(children())")
            // Shift alone: the input method's English mode, so letters stay letters.
            mirror.sendInput(.flagsChanged(keyCode: 56, modifiers: CGEventFlags.maskShift.rawValue))
            mirror.sendInput(.flagsChanged(keyCode: 56, modifiers: 0))
            try? await Task.sleep(for: .milliseconds(300))
            for code: UInt16 in [0, 1] { key(code) } // a s
            try? await Task.sleep(for: .milliseconds(300))
            mirror.sendInput(.flagsChanged(keyCode: 56, modifiers: CGEventFlags.maskShift.rawValue))
            mirror.sendInput(.flagsChanged(keyCode: 56, modifiers: 0))
            print("host-ime-test: done")
        }
    }
}

@MainActor
enum ResizeTest {
    static func run(_ mirror: MirrorWindowController) {
        let sizes = [CGSize(width: 700, height: 500), CGSize(width: 1100, height: 760), CGSize(width: 520, height: 900),
                     CGSize(width: 940, height: 700)]
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for size in sizes {
                let start = CACurrentMediaTime()
                mirror.requestHostResize(size)
                var reached = false
                for _ in 0..<100 {
                    try? await Task.sleep(for: .milliseconds(20))
                    let content = mirror.surface.bounds.size
                    if abs(content.width - size.width) < 2, abs(content.height - size.height) < 2 {
                        reached = true; break
                    }
                }
                let elapsed = (CACurrentMediaTime() - start) * 1000
                print(String(format: "resize-test: %.0fx%.0f %@ in %.0f ms (viewer content %.0fx%.0f)",
                             size.width, size.height, reached ? "applied" : "NOT applied", elapsed,
                             mirror.surface.bounds.width, mirror.surface.bounds.height))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// A window that records the input it receives, for checking injection.
@MainActor
final class InputRecorderWindow: NSWindow {
    final class RecorderView: NSView {
        var log: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.textBackgroundColor.setFill()
            dirtyRect.fill()
            (log.suffix(30).joined(separator: "\n") as NSString)
                .draw(at: NSPoint(x: 8, y: 8), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                               .foregroundColor: NSColor.textColor])
        }
        private func record(_ text: String) { log.append(text); needsDisplay = true }
        private func point(_ event: NSEvent) -> String {
            let p = convert(event.locationInWindow, from: nil)
            return "\(Int(p.x.rounded())),\(Int(p.y.rounded()))"
        }
        override func mouseDown(with event: NSEvent) { record("down \(point(event)) clicks=\(event.clickCount)") }
        override func mouseUp(with event: NSEvent) { record("up \(point(event))") }
        override func mouseDragged(with event: NSEvent) { record("drag \(point(event))") }
        override func rightMouseDown(with event: NSEvent) {
            record("rightdown \(point(event))")
            super.rightMouseDown(with: event)
        }
        override func scrollWheel(with event: NSEvent) {
            record("scroll \(point(event)) dy=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas)")
        }
        override func keyDown(with event: NSEvent) { record("key \(event.characters ?? "?") code=\(event.keyCode)") }
    }

    let recorder = RecorderView()

    init() {
        super.init(contentRect: NSRect(x: 60, y: 160, width: 600, height: 420),
                   styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        title = "AnyRemote input recorder"
        isReleasedWhenClosed = false
        contentView = recorder
        let menu = NSMenu()
        for title in ["First item", "Second item", "Third item"] { menu.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        recorder.menu = menu
        orderFrontRegardless()
    }
}

/// Injects a fixed input sequence through the mirror and reports what the host window received.
@MainActor
enum InputTest {
    static func run(_ mirror: MirrorWindowController, recorder: InputRecorderWindow) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            // Window-relative host points; the title bar is the top `titleHeight` points.
            let titleHeight = recorder.frame.height - recorder.contentLayoutRect.height
            let p = CGPoint(x: 200, y: titleHeight + 150)
            mirror.sendInput(.mouseMove(point: p, pressedButtons: 0, modifiers: 0))
            mirror.sendInput(.mouseDown(point: p, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0))
            mirror.sendInput(.mouseUp(point: p, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0))
            try? await Task.sleep(for: .milliseconds(200))
            for (code, character) in [(UInt16(0), "a"), (UInt16(1), "s")] {
                _ = character
                mirror.sendInput(.key(keyCode: code, down: true, isRepeat: false, modifiers: 0))
                mirror.sendInput(.key(keyCode: code, down: false, isRepeat: false, modifiers: 0))
            }
            mirror.sendInput(.scroll(point: p, deltaX: 0, deltaY: -0.4, precise: false, phase: 0, momentumPhase: 0,
                                     modifiers: 0))
            try? await Task.sleep(for: .milliseconds(300))
            mirror.sendInput(.mouseDown(point: p, button: .right, buttonNumber: 1, clickCount: 1, modifiers: 0))
            mirror.sendInput(.mouseUp(point: p, button: .right, buttonNumber: 1, clickCount: 1, modifiers: 0))
            try? await Task.sleep(for: .milliseconds(1500))
            let children = mirror.window?.childWindows?.filter { $0 is ChildPanel && $0.isVisible } ?? []
            print("input-test: child windows shown in viewer: \(children.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" })")
            mirror.sendInput(.key(keyCode: 53, down: true, isRepeat: false, modifiers: 0))
            mirror.sendInput(.key(keyCode: 53, down: false, isRepeat: false, modifiers: 0))
            try? await Task.sleep(for: .milliseconds(800))
            let after = mirror.window?.childWindows?.filter { $0 is ChildPanel && $0.isVisible } ?? []
            print("input-test: child windows after Escape: \(after.count)")
            print("input-test: expected click at 200,150 then keys a s, scroll, right-click with menu")
            for line in recorder.recorder.log { print("input-test: got \(line)") }
        }
    }
}

/// Prints the remote menus installed in our menu bar and optionally chooses
/// one item ("Menu/Item") through them.
@MainActor
enum MenuTest {
    static func run(_ mirror: MirrorWindowController, app: AppDelegate, choose: String?) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            print("menu-test: \(mirror.remoteMenus.count) remote menus from \(mirror.remoteApplicationName); "
                  + "mirror is key: \(mirror.window?.isKeyWindow ?? false)")
            // Mirroring this Mac's own windows, focusing the host window activates
            // that app and our mirror stops being key; install regardless.
            app.installRemoteMenus(for: mirror)
            guard let mainMenu = NSApp.mainMenu else { return }
            print("menu-test: menu bar \(mainMenu.items.map { $0.submenu?.title ?? $0.title })")
            for item in mainMenu.items.dropFirst() {
                guard let submenu = item.submenu, submenu.delegate is RemoteMenuBar else { continue }
                let titles = submenu.items.prefix(8).map { $0.isSeparatorItem ? "—" : $0.title }
                print("menu-test:   \(item.title): \(titles)")
            }
            guard let choose else { return }
            let parts = choose.split(separator: "/").map(String.init)
            guard parts.count == 2, let menu = mainMenu.items.first(where: { $0.title == parts[0] })?.submenu,
                  let index = menu.items.firstIndex(where: { $0.title == parts[1] }) else {
                print("menu-test: \(choose) not found"); return
            }
            menu.performActionForItem(at: index)
            print("menu-test: chose \(choose)")
        }
    }
}
