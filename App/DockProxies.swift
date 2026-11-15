import AppKit
import CryptoKit
import ImageIO
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Dock")

extension Notification.Name {
    /// A mirror opened, closed or changed its title.
    static let mirrorsChanged = Notification.Name("AnyRemoteMirrorsChanged")
}

/// Gives each remote app with windows mirrored here its own Dock tile and
/// app switcher entry, like Parallels' Coherence mode.
///
/// macOS gives a process one Dock tile, so each remote app gets a small
/// stand-in app (`DockProxy/main.swift`) in a bundle generated under
/// Application Support with the app's icon (badged) and name. Clicking it, or
/// choosing it with ⌘Tab, brings that app's mirrors forward; its Dock menu
/// lists them; Quit closes them on this Mac only.
@MainActor
final class DockProxies {
    static let enabledKey = "ShowsRemoteAppsInDock"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .mirrorsChanged, object: nil)
        }
    }

    private final class Proxy {
        let id: String
        var url: URL?
        var application: NSRunningApplication?
        var mirrors: [MirrorWindowController] = []
        init(id: String) { self.id = id }
    }

    private let viewer: () -> ViewerModel
    private let parentID = Bundle.main.bundleIdentifier ?? "com.localhost-copilot.anyremote"
    private let center = DistributedNotificationCenter.default()
    private var proxies: [String: Proxy] = [:]
    /// Groups whose icon was asked for with a fresh window listing.
    private var iconRefreshes: Set<String> = []
    private var scheduled = false

    init(viewer: @escaping () -> ViewerModel) {
        self.viewer = viewer
        NotificationCenter.default.addObserver(forName: .mirrorsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        for event in ["ready", "activate", "focus", "closeAll"] {
            center.addObserver(forName: name(event), object: nil, queue: .main) { [weak self] note in
                let id = note.object as? String
                let window = note.userInfo?["window"] as? Int
                MainActor.assumeIsolated {
                    guard let id else { return }
                    self?.handle(event, id: id, window: window)
                }
            }
        }
    }

    private func name(_ event: String) -> Notification.Name { .init("\(parentID).dock.\(event)") }

    private func post(_ event: String, to id: String, _ userInfo: [String: Any]? = nil) {
        center.postNotificationName(name(event), object: id, userInfo: userInfo, deliverImmediately: true)
    }

    func quitAll() {
        for id in proxies.keys { post("quit", to: id) }
        proxies.removeAll()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.sync()
            }
        }
    }

    // MARK: Groups

    private func sync() {
        guard Self.isEnabled else { return quitAll() }
        var groups: [String: (connection: HostConnection, application: String, mirrors: [MirrorWindowController])] = [:]
        for connection in viewer().connections.values {
            let host = connection.target.hostID ?? connection.target.id
            for mirror in connection.openMirrors {
                let application = mirror.stream.applicationName
                let id = Self.proxyID(host: host, application: application)
                groups[id, default: (connection, application, [])].mirrors.append(mirror)
            }
        }
        for (id, _) in proxies where groups[id] == nil {
            post("quit", to: id)
            proxies[id] = nil
        }
        for (id, group) in groups {
            let mirrors = group.mirrors.sorted { $0.windowID < $1.windowID }
            if let proxy = proxies[id] {
                proxy.mirrors = mirrors
                sendUpdate(proxy)
                continue
            }
            let icon = Self.icon(for: group.application, in: group.connection)
            if icon == nil, !iconRefreshes.contains(id) {
                // A window opened by itself may not be in the listing yet.
                iconRefreshes.insert(id)
                Task { [weak self] in
                    await group.connection.refresh()
                    self?.schedule()
                }
                continue
            }
            let proxy = Proxy(id: id)
            proxy.mirrors = mirrors
            proxies[id] = proxy
            launch(proxy, name: "\(group.application) (\(group.connection.hostName))", icon: icon)
        }
    }

    private static func proxyID(host: String, application: String) -> String {
        let digest = SHA256.hash(data: Data("\(host)|\(application)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func icon(for application: String, in connection: HostConnection) -> Data? {
        guard let listing = connection.listing else { return nil }
        let bundle = listing.windows.first { $0.applicationName == application && $0.bundleIdentifier != nil }?
            .bundleIdentifier
        return bundle.flatMap { listing.icons[$0] }
    }

    private func sendUpdate(_ proxy: Proxy) {
        let windows: [[Any]] = proxy.mirrors.map { mirror in
            let title = mirror.stream.title.isEmpty ? mirror.stream.applicationName : mirror.stream.title
            return [Int(mirror.windowID), title]
        }
        post("update", to: proxy.id, ["windows": windows,
                                       "closeAllTitle": String(localized: "Close All on This Mac")])
    }

    // MARK: Proxy events

    private func handle(_ event: String, id: String, window: Int?) {
        guard let proxy = proxies[id] else {
            // A proxy left over from an earlier run.
            if event == "ready" { post("quit", to: id) }
            return
        }
        switch event {
        case "ready":
            sendUpdate(proxy)
        case "activate":
            bringForward(proxy.mirrors)
        case "focus":
            bringForward(proxy.mirrors.filter { Int($0.windowID) == window })
        case "closeAll":
            for mirror in proxy.mirrors { mirror.close() }
        default:
            break
        }
    }

    /// Shows the mirrors in their current order, the frontmost one key.
    private func bringForward(_ mirrors: [MirrorWindowController]) {
        let windows = mirrors.compactMap(\.window)
        guard !windows.isEmpty else { return }
        NSApp.activate()
        let order = NSApp.orderedWindows
        let sorted = windows.sorted {
            (order.firstIndex(of: $0) ?? .max) > (order.firstIndex(of: $1) ?? .max)
        }
        for window in sorted {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFront(nil)
        }
        sorted.last?.makeKeyAndOrderFront(nil)
    }

    // MARK: Bundles

    private func launch(_ proxy: Proxy, name: String, icon: Data?) {
        let url: URL
        do {
            url = try makeBundle(id: proxy.id, name: name, icon: icon)
        } catch {
            log.error("dock proxy bundle failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        proxy.url = url
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let id = proxy.id
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] application, error in
            if let error { log.error("dock proxy launch failed: \(error.localizedDescription, privacy: .public)") }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if let proxy = self?.proxies[id] {
                        proxy.application = application
                    } else {
                        application?.terminate()
                    }
                }
            }
        }
    }

    /// `<Application Support>/<bundle ID>/Dock/<id>/<name>.app`, rebuilt when
    /// its name, icon or the helper changed.
    private func makeBundle(id: String, name: String, icon: Data?) throws -> URL {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "AnyRemoteDockProxy") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fileManager = FileManager.default
        let helperAttributes = try fileManager.attributesOfItem(atPath: helper.path)
        let helperStamp = "\(helperAttributes[.size] ?? 0)-\((helperAttributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let iconStamp = icon.map { SHA256.hash(data: $0).prefix(6).map { String(format: "%02x", $0) }.joined() } ?? "-"
        let stamp = "\(helperStamp)|\(iconStamp)|\(name)"

        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                       create: true)
            .appendingPathComponent(parentID).appendingPathComponent("Dock").appendingPathComponent(id)
        let fileName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let bundle = base.appendingPathComponent("\(fileName).app")
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        if let info = NSDictionary(contentsOf: infoURL), info["AnyRemoteStamp"] as? String == stamp { return bundle }

        try? fileManager.removeItem(at: base)
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try fileManager.copyItem(at: helper, to: macOS.appendingPathComponent("AnyRemoteDockProxy"))
        let info: [String: Any] = [
            "CFBundleExecutable": "AnyRemoteDockProxy",
            "CFBundleIdentifier": "\(parentID).dock.\(id)",
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            "AnyRemoteProxyID": id,
            "AnyRemoteParentBundleID": parentID,
            "AnyRemoteStamp": stamp,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: infoURL)
        try Self.writeIcon(icon, to: resources.appendingPathComponent("AppIcon.icns"))
        // The copied executable's signature names the helper's Info.plist; sign the bundle as itself.
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", bundle.path]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        if codesign.terminationStatus != 0 { log.error("dock proxy signing failed") }
        return bundle
    }

    /// The app's icon with a small display badge, so it isn't mistaken for a local app.
    private static func writeIcon(_ data: Data?, to url: URL) throws {
        let source = data.flatMap(NSImage.init(data:)) ?? NSApp.applicationIconImage ?? NSImage()
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, 3, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        for pixels in [128, 256, 512] {
            guard let image = badged(source, pixels: pixels) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func badged(_ icon: NSImage, pixels: Int) -> CGImage? {
        let size = CGFloat(pixels)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        let badge = NSRect(x: size * 0.6, y: size * 0.04, width: size * 0.36, height: size * 0.36)
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: badge.offsetBy(dx: 0, dy: -size * 0.01)).fill()
        NSColor.controlAccentColor.usingColorSpace(.sRGB)?.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.17, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let symbolSize = symbol.size
            symbol.draw(in: NSRect(x: badge.midX - symbolSize.width / 2, y: badge.midY - symbolSize.height / 2,
                                   width: symbolSize.width, height: symbolSize.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
