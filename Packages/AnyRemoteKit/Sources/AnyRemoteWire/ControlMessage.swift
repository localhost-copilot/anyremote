import CoreGraphics
import Foundation

/// Protocol revision carried in the handshake. Bump on any incompatible change
/// to control messages, framing, datagram layout or key schedule.
public let anyRemoteProtocolVersion: UInt16 = 3

/// Cleartext handshake exchanged before the session keys exist.
public enum HandshakeMessage: Codable, Equatable, Sendable {
    case clientHello(version: UInt16, nonce: Data, viewerName: String)
    case serverHello(version: UInt16, nonce: Data, hostID: String, hostName: String, sessionID: UInt32)
    /// Sent instead of `serverHello`, or in reply to an unauthenticated frame.
    case failure(reason: String)
}

/// A window on the host, in host global points (top-left origin, like
/// `CGWindowListCopyWindowInfo` and `SCWindow.frame`).
public struct WindowSummary: Codable, Hashable, Sendable {
    public var windowID: UInt32
    public var pid: Int32
    public var applicationName: String
    public var bundleIdentifier: String?
    public var title: String
    public var frame: CGRect
    public var isResizable: Bool?

    public init(windowID: UInt32, pid: Int32, applicationName: String, bundleIdentifier: String?,
                title: String, frame: CGRect, isResizable: Bool? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.frame = frame
        self.isResizable = isResizable
    }
}

/// An application installed (or running) on the host.
public struct HostApplication: Codable, Hashable, Sendable {
    /// Bundle path on the host; identifies the app in `launchApplication`.
    public var path: String
    public var name: String
    public var bundleIdentifier: String?
    public var isRunning: Bool

    public init(path: String, name: String, bundleIdentifier: String?, isRunning: Bool) {
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
    }
}

/// One host display, in host global points.
public struct DisplaySummary: Codable, Hashable, Sendable {
    public var displayID: UInt32
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var scale: Double
    public var isVirtual: Bool

    public init(displayID: UInt32, frame: CGRect, visibleFrame: CGRect, scale: Double, isVirtual: Bool) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.isVirtual = isVirtual
    }
}

public struct HostWelcome: Codable, Equatable, Sendable {
    public var hostID: String
    public var hostName: String
    /// Where the viewer sends its datagrams (keepalives) so video can flow back.
    public var datagramPort: UInt16
    public var displays: [DisplaySummary]
    /// Missing host permissions, e.g. "screen-recording", "accessibility".
    public var missingPermissions: [String]

    public init(hostID: String, hostName: String, datagramPort: UInt16, displays: [DisplaySummary],
                missingPermissions: [String]) {
        self.hostID = hostID
        self.hostName = hostName
        self.datagramPort = datagramPort
        self.displays = displays
        self.missingPermissions = missingPermissions
    }
}

/// A video stream of one host surface: the opened window, or one of its child
/// windows (menus, popovers, sheets, tooltips, panels).
public struct StreamDescription: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case window
        case child
    }

    public var streamID: UInt16
    public var windowID: UInt32
    public var role: Role
    /// For children: the stream of the opened window they belong to.
    public var parentStreamID: UInt16?
    /// Host global frame in points.
    public var frame: CGRect
    /// CG window layer on the host (0 = normal, 101 = menus, ...).
    public var layer: Int
    public var title: String
    public var applicationName: String

    public init(streamID: UInt16, windowID: UInt32, role: Role, parentStreamID: UInt16?, frame: CGRect,
                layer: Int, title: String, applicationName: String) {
        self.streamID = streamID
        self.windowID = windowID
        self.role = role
        self.parentStreamID = parentStreamID
        self.frame = frame
        self.layer = layer
        self.title = title
        self.applicationName = applicationName
    }
}

/// User input aimed at an opened window. Points are relative to the top-left
/// corner of that window's stream (`streamID` of `ControlMessage.input`), and
/// may lie outside it (child windows, drags).
public enum InputEvent: Codable, Equatable, Sendable {
    public enum MouseButton: Int, Codable, Sendable {
        case left = 0
        case right = 1
        case other = 2
    }

    case mouseMove(point: CGPoint, pressedButtons: UInt32, modifiers: UInt64)
    case mouseDown(point: CGPoint, button: MouseButton, buttonNumber: Int, clickCount: Int, modifiers: UInt64)
    case mouseUp(point: CGPoint, button: MouseButton, buttonNumber: Int, clickCount: Int, modifiers: UInt64)
    /// `phase` and `momentumPhase` are `NSEvent.Phase` raw values; `precise`
    /// means pixel deltas (trackpad), otherwise line deltas (wheel).
    case scroll(point: CGPoint, deltaX: Double, deltaY: Double, precise: Bool,
                phase: UInt32, momentumPhase: UInt32, modifiers: UInt64)
    /// `keyCode` is the macOS virtual key code; `modifiers` are CGEventFlags.
    case key(keyCode: UInt16, down: Bool, isRepeat: Bool, modifiers: UInt64)
    case flagsChanged(keyCode: UInt16, modifiers: UInt64)
}

/// The host's current cursor. `png` is nil for "unchanged image, new
/// visibility"; images are cached by `seed` on the viewer.
public struct CursorImage: Codable, Equatable, Sendable {
    public var seed: UInt32
    public var png: Data?
    public var pointSize: CGSize
    public var hotSpot: CGPoint

    public init(seed: UInt32, png: Data?, pointSize: CGSize, hotSpot: CGPoint) {
        self.seed = seed
        self.png = png
        self.pointSize = pointSize
        self.hotSpot = hotSpot
    }
}

/// Where a host window's title bar buttons are, in points relative to the
/// window's top-left corner (the captured frame's origin).
public struct WindowControls: Codable, Equatable, Sendable {
    public var close: CGRect?
    public var minimize: CGRect?
    public var zoom: CGRect?
    public var fullScreen: CGRect?

    public init(close: CGRect? = nil, minimize: CGRect? = nil, zoom: CGRect? = nil, fullScreen: CGRect? = nil) {
        self.close = close
        self.minimize = minimize
        self.zoom = zoom
        self.fullScreen = fullScreen
    }
}

/// Window commands the viewer asks the host to perform.
public enum WindowAction: String, Codable, Sendable {
    /// Presses the window's close button (the app may ask to save first).
    case close
}

/// Window state changes the host app attempted (menu item, shortcut, title
/// bar double-click). The host undoes them on its side, because a minimized
/// or full-screen host window can't be streamed into a local window, and the
/// viewer applies them to the local window instead.
public enum HostWindowStateRequest: String, Codable, Sendable {
    case minimize
    case enterFullScreen
}

/// A node of the host application's menu bar, read through Accessibility.
public struct MenuNode: Codable, Equatable, Sendable {
    public var title: String
    public var isEnabled: Bool
    public var isSeparator: Bool
    /// "✓", "•", "-" or nil.
    public var mark: String?
    public var keyEquivalent: String
    /// AX menu modifier mask (kAXMenuItemModifier*).
    public var keyModifiers: Int
    public var children: [MenuNode]

    public init(title: String, isEnabled: Bool = true, isSeparator: Bool = false, mark: String? = nil,
                keyEquivalent: String = "", keyModifiers: Int = 0, children: [MenuNode] = []) {
        self.title = title
        self.isEnabled = isEnabled
        self.isSeparator = isSeparator
        self.mark = mark
        self.keyEquivalent = keyEquivalent
        self.keyModifiers = keyModifiers
        self.children = children
    }
}

/// Host-side stage timings so the viewer can show the whole pipeline.
public struct HostStreamReport: Codable, Equatable, Sendable {
    public var captureP50: Double
    public var waitP50: Double
    public var encodeP50: Double
    public var encodeP95: Double
    public var framesPerSecond: Double
    public var megabitsPerSecond: Double
    public var bitRate: Int

    public init(captureP50: Double, waitP50: Double, encodeP50: Double, encodeP95: Double,
                framesPerSecond: Double, megabitsPerSecond: Double, bitRate: Int) {
        self.captureP50 = captureP50
        self.waitP50 = waitP50
        self.encodeP50 = encodeP50
        self.encodeP95 = encodeP95
        self.framesPerSecond = framesPerSecond
        self.megabitsPerSecond = megabitsPerSecond
        self.bitRate = bitRate
    }
}

/// Plaintext datagram kinds (first two bytes: version 1, kind). Kind 1 is a
/// `VideoFragmenter` datagram.
public enum DatagramKind {
    public static let video: UInt8 = 1
    /// Viewer → host: binds the viewer's UDP address to the session.
    public static let keepalive: UInt8 = 2
    public static let keepaliveDatagram = Data([1, keepalive])
}

/// Messages on the sealed control channel. Video travels separately as
/// datagrams.
public enum ControlMessage: Codable, Equatable, Sendable {
    // Session
    case authenticate(viewerName: String, takeOver: Bool)
    case welcome(HostWelcome)
    case rejected(reason: String)
    case ping(id: UInt32, viewerTime: UInt64)
    case pong(id: UInt32, viewerTime: UInt64, hostTime: UInt64)
    case goodbye(reason: String)

    // Window library
    case listWindows(requestID: UInt32, thumbnailMaxPixels: Int)
    case windowList(requestID: UInt32, windows: [WindowSummary], displays: [DisplaySummary],
                    thumbnails: [UInt32: Data], icons: [String: Data], missingPermissions: [String])

    /// Installed apps; `icons` are PNGs keyed by app path.
    case listApplications(requestID: UInt32)
    case applicationList(requestID: UInt32, applications: [HostApplication], icons: [String: Data])
    /// Opens (or brings forward) the app; its window then opens like a picked one.
    case launchApplication(path: String)

    // Streams
    case openWindow(windowID: UInt32)
    case streamStarted(StreamDescription)
    /// The surface moved or changed title on the host.
    case streamMoved(streamID: UInt16, frame: CGRect, title: String)
    case streamEnded(streamID: UInt16, reason: String)
    case closeStream(streamID: UInt16)
    case requestKeyframe(streamID: UInt16)
    case receiverReport(streamID: UInt16, framesReceived: UInt32, framesDropped: UInt32)
    case hostReport(streamID: UInt16, HostStreamReport)

    // Window control
    case resize(streamID: UInt16, size: CGSize)
    case resizeApplied(streamID: UInt16, size: CGSize)
    case focus(streamID: UInt16)
    case input(streamID: UInt16, InputEvent)
    case cursor(CursorImage)
    case windowControls(streamID: UInt16, WindowControls)
    case windowAction(streamID: UInt16, action: WindowAction)
    case windowStateRequest(streamID: UInt16, HostWindowStateRequest)

    // Menu bar
    case requestMenuBar(streamID: UInt16)
    case menuBar(streamID: UInt16, applicationName: String, menus: [MenuNode])
    /// `path` indexes from the top-level menu down to the item.
    case performMenuItem(streamID: UInt16, path: [Int])
}

public enum ControlCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
