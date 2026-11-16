import AppKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Desktop")

/// How full desktops are shown; shared by every desktop window.
@MainActor
enum DesktopPreferences {
    private static let fitsWindowKey = "DesktopFitsWindow"
    private static let capturesShortcutsKey = "DesktopCapturesSystemShortcuts"

    /// On unless turned off (also as `-Key NO` on the command line, a string).
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key)
    }

    /// Dynamic resolution: the host's desktop takes the window's size.
    static var fitsWindow: Bool {
        get { flag(fitsWindowKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: fitsWindowKey)
            NotificationCenter.default.post(name: .desktopPreferencesChanged, object: nil)
        }
    }

    /// ⌘Tab, ⌘Space, Mission Control and the like go to the host while a
    /// desktop window is in front.
    static var capturesSystemShortcuts: Bool {
        get { flag(capturesShortcutsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: capturesShortcutsKey)
            NotificationCenter.default.post(name: .desktopPreferencesChanged, object: nil)
        }
    }
}

/// Whether remote windows and desktops show the statistics panel; one
/// switch for all of them, kept across launches.
@MainActor
enum StatisticsPreferences {
    private static let key = "ShowsStatistics"

    /// Off unless turned on (development: also `ANYREMOTE_STATS=1`).
    static var isShown: Bool {
        get { UserDefaults.standard.bool(forKey: key) || ProcessInfo.processInfo.environment["ANYREMOTE_STATS"] == "1" }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .statisticsPreferenceChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let desktopPreferencesChanged = Notification.Name("AnyRemoteDesktopPreferencesChanged")
    static let statisticsPreferenceChanged = Notification.Name("AnyRemoteStatisticsPreferenceChanged")
}

/// Turns this Mac's system shortcuts off while a desktop window is key, so
/// they reach the host as ordinary key events: the window server's global
/// hot keys (⌘Tab, ⌘Space, ⌃↑, screenshots…) are what would otherwise act
/// here first. They are back on as soon as another window or app is in
/// front, and macOS restores them if this app quits or crashes (the setting
/// belongs to its window server connection).
@MainActor
final class SystemShortcutCapture {
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias SetModeFunction = @convention(c) (Int32, Int32) -> Int32
    private static func symbol<T>(_ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
                return unsafeBitCast(pointer, to: type)
            }
        }
        return nil
    }
    private static let mainConnection = symbol(["CGSMainConnectionID", "SLSMainConnectionID"], as: ConnectionFunction.self)
    private static let setMode = symbol(["CGSSetGlobalHotKeyOperatingMode", "SLSSetGlobalHotKeyOperatingMode"],
                                        as: SetModeFunction.self)
    /// CGSGlobalHotKeyOperatingMode: 0 enabled, 1 disabled.
    private static let enabled: Int32 = 0, disabled: Int32 = 1

    private var isCapturing = false
    private var observers: [NSObjectProtocol] = []
    private let isActive: @MainActor () -> Bool

    /// - Parameter isActive: whether a desktop window is key.
    init(isActive: @escaping @MainActor () -> Bool) {
        self.isActive = isActive
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                          NSApplication.didBecomeActiveNotification,
                                          NSApplication.didResignActiveNotification, .desktopPreferencesChanged]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
    }

    var isAvailable: Bool { Self.mainConnection != nil && Self.setMode != nil }

    func update() {
        let wanted = DesktopPreferences.capturesSystemShortcuts && NSApp.isActive && isActive()
        guard wanted != isCapturing, let mainConnection = Self.mainConnection, let setMode = Self.setMode else { return }
        let result = setMode(mainConnection(), wanted ? Self.disabled : Self.enabled)
        isCapturing = wanted && result == 0
        log.info("system shortcuts \(wanted ? "captured" : "released", privacy: .public) (\(result))")
    }

    func release() {
        guard isCapturing, let mainConnection = Self.mainConnection, let setMode = Self.setMode else { return }
        _ = setMode(mainConnection(), Self.enabled)
        isCapturing = false
    }
}
