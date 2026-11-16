import AppKit
import CryptoKit
import ImageIO
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Dock")

/// The stand-in apps for remote apps, as real apps in the Applications
/// folder: `~/Applications/AnyRemote/<Mac>/<App> (<Mac>).app`.
///
/// Being there makes them apps like any other: Spotlight and the Apps
/// launcher find them, and their Dock icon can be kept in the Dock. Opened
/// that way, a stand-in asks AnyRemote to open the app on its Mac
/// (`DockProxy/main.swift`). A stand-in is made the first time one of the
/// app's windows opens here, and kept until its Mac is forgotten or remote
/// apps are turned off.
@MainActor
enum RemoteAppBundles {
    struct Identity {
        /// The stand-in's ID, which also names its bundle identifier.
        var id: String
        var hostID: String
        var hostName: String
        /// The app's name on the host, as its windows report it.
        var application: String
        var bundleIdentifier: String?

        var displayName: String { "\(application) (\(hostName))" }
    }

    /// `~/Applications/AnyRemote` (`AnyRemote Dev` for development builds).
    static var folder: URL {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "AnyRemote"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            .appendingPathComponent(name)
    }

    private static var parentID: String { Bundle.main.bundleIdentifier ?? "com.localhost-copilot.anyremote" }

    /// The stand-in's bundle, made or rebuilt when its name, icon or the
    /// helper changed. Its path stays the same as long as the names do, so
    /// a copy kept in the Dock keeps working.
    static func make(_ identity: Identity, icon: Data?) throws -> URL {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "AnyRemoteDockProxy") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fileManager = FileManager.default
        let helperAttributes = try fileManager.attributesOfItem(atPath: helper.path)
        let helperStamp = "\(helperAttributes[.size] ?? 0)-\((helperAttributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let iconStamp = icon.map { SHA256.hash(data: $0).prefix(6).map { String(format: "%02x", $0) }.joined() } ?? "-"
        // `badge2`: the badge moved inside the icon shape; bump it whenever the drawing changes.
        let stamp = "\(helperStamp)|\(iconStamp)|badge2|\(identity.displayName)|\(identity.bundleIdentifier ?? "-")"

        let bundle = folder.appendingPathComponent(fileName(identity.hostName))
            .appendingPathComponent("\(fileName(identity.displayName)).app")
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        if let info = NSDictionary(contentsOf: infoURL), info["AnyRemoteStamp"] as? String == stamp { return bundle }

        // The same app under an older name (the Mac was renamed).
        for other in bundles() where other != bundle && info(of: other)?["AnyRemoteProxyID"] as? String == identity.id {
            try? fileManager.removeItem(at: other)
        }
        try? fileManager.removeItem(at: bundle)
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try fileManager.copyItem(at: helper, to: macOS.appendingPathComponent("AnyRemoteDockProxy"))
        var info: [String: Any] = [
            "CFBundleExecutable": "AnyRemoteDockProxy",
            "CFBundleIdentifier": "\(parentID).dock.\(identity.id)",
            "CFBundleName": identity.displayName,
            "CFBundleDisplayName": identity.displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            "AnyRemoteProxyID": identity.id,
            "AnyRemoteParentBundleID": parentID,
            "AnyRemoteHostID": identity.hostID,
            "AnyRemoteApplication": identity.application,
            "AnyRemoteStamp": stamp,
        ]
        if let bundleIdentifier = identity.bundleIdentifier { info["AnyRemoteApplicationBundleID"] = bundleIdentifier }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: infoURL)
        try writeIcon(icon, to: resources.appendingPathComponent("AppIcon.icns"))
        // The copied executable's signature names the helper's Info.plist; sign the bundle as itself.
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", bundle.path]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        if codesign.terminationStatus != 0 { log.error("dock proxy signing failed") }
        // Known to Launch Services (and so to Spotlight and the Apps launcher) right away.
        LSRegisterURL(bundle as CFURL, true)
        return bundle
    }

    /// The stand-ins of a Mac that was forgotten.
    static func remove(hostID: String) {
        for bundle in bundles() where info(of: bundle)?["AnyRemoteHostID"] as? String == hostID {
            try? FileManager.default.removeItem(at: bundle)
        }
        removeEmptyFolders()
    }

    /// Remote apps were turned off.
    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Before 0.19 the stand-ins lived in Application Support.
    static func removeLegacyBundles() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        try? FileManager.default.removeItem(at: support.appendingPathComponent(parentID).appendingPathComponent("Dock"))
    }

    private static func bundles() -> [URL] {
        let fileManager = FileManager.default
        let macs = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return macs.flatMap { mac in
            ((try? fileManager.contentsOfDirectory(at: mac, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
        }
    }

    private static func removeEmptyFolders() {
        let fileManager = FileManager.default
        for mac in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            let contents = (try? fileManager.contentsOfDirectory(atPath: mac.path)) ?? []
            if contents.allSatisfy({ $0.hasPrefix(".") }) { try? fileManager.removeItem(at: mac) }
        }
    }

    private static func info(of bundle: URL) -> NSDictionary? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    private static func fileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    // MARK: Icon

    /// The app's icon with a small display badge, so it isn't mistaken for a local app.
    ///
    /// The badge stays inside the icon's own outline: since macOS 26 the Dock
    /// shrinks any icon whose shape isn't the standard rounded square into a
    /// grey tile, and a badge poking past the corner is enough to trigger it.
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
        // Just inside the bottom-right corner of the standard icon shape
        // (a rounded square inset 9.4 % with an 18 % corner radius), and
        // drawn source-atop so nothing lands outside the icon's alpha.
        let radius = size * 0.15
        let center = NSPoint(x: size * 0.715, y: size * 0.285)
        let badge = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: badge.offsetBy(dx: 0, dy: -size * 0.01)).fill()
        NSColor.controlAccentColor.usingColorSpace(.sRGB)?.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.14, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let symbolSize = symbol.size
            symbol.draw(in: NSRect(x: badge.midX - symbolSize.width / 2, y: badge.midY - symbolSize.height / 2,
                                   width: symbolSize.width, height: symbolSize.height),
                        from: .zero, operation: .sourceAtop, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
