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
///         [--shortcut-test]                 post ⌘Tab and ⌘Space and print what the desktop forwards
///     -DesktopFitsWindow NO                 turn dynamic resolution off for this launch
///     --connect host[:port] --code CODE     connect to another Mac
///     --discovery-test                      print the hosts Bonjour finds
///     --permission-guide                    show Settings and the permission guide card
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
        guard synthetic != nil || recorder != nil || application != nil || connectAddress != nil || launch != nil
                || quit != nil || desktop
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

        Task { @MainActor in
            let target: HostTarget
            if let connectAddress {
                guard let endpoint = HostTarget.endpoint(fromAddress: connectAddress),
                      let code = value("--code").flatMap(PairingCode.init) else {
                    print("dev: --connect needs a valid address and --code"); return
                }
                target = HostTarget(id: "dev:\(connectAddress)", name: connectAddress, kind: .saved, endpoint: endpoint)
                await model.connect(target, code: code)
            } else {
                model.showsThisMac = true
                guard let thisMac = model.thisMacTarget else { print("dev: hosting is off"); return }
                target = thisMac
                await model.connect(target)
            }
            model.selection = target.id
            app.showHosts()
            guard let connection = model.connection(for: target), connection.state == .connected else {
                print("dev: connect failed: \(model.lastError ?? "unknown")"); return
            }
            print("dev: connected to \(connection.hostName)")
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
                await connection.loadApplications()
                let apps = connection.applications?.applications ?? []
                print("dev: \(apps.count) apps, \(connection.applications?.icons.count ?? 0) icons")
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
            }
            print("dev: window not found")
        }
        return true
    }

    private static func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
}

/// Resizes the mirror through a series of sizes and reports how the host followed.
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
