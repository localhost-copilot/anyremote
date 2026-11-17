import CoreGraphics
import Foundation

/// Protocol revision carried in the handshake. Bump on any incompatible change
/// to control messages, framing, datagram layout or key schedule.
public let anyRemoteProtocolVersion: UInt16 = 23

/// Cleartext handshake exchanged before the session keys exist.
///
/// Since protocol 20 the handshake is frozen: later protocols may add
/// optional fields and cases, but never change these, so that Macs on
/// different protocols can still tell each other their versions and one can
/// ask the other to update itself (`purpose: .update`).
public enum HandshakeMessage: Codable, Equatable, Sendable {
    case clientHello(version: UInt16, nonce: Data, viewerName: String,
                     appVersion: String? = nil, purpose: HandshakePurpose? = nil)
    case serverHello(version: UInt16, nonce: Data, hostID: String, hostName: String, sessionID: UInt32)
    /// Sent instead of `serverHello`, or in reply to an unauthenticated frame.
    /// `host` tells a viewer on another protocol which AnyRemote that Mac runs.
    case failure(reason: String, host: AppVersionInfo? = nil)
    /// The host's answer to an update hello: prove the pairing code over the
    /// two nonces with `updateRequest`.
    case updateChallenge(nonce: Data, host: AppVersionInfo)
    case updateRequest(proof: Data)
    /// The host downloaded and checked `version` and is about to relaunch with it.
    case updateStarted(version: String)
}

/// Why a viewer connects: to control the host, or only to ask it to update.
public enum HandshakePurpose: String, Codable, Sendable {
    case session
    case update
}

/// Which AnyRemote a Mac runs. Part of the frozen handshake.
public struct AppVersionInfo: Codable, Equatable, Sendable {
    public var appVersion: String
    public var protocolVersion: UInt16
    /// Whether it accepts an update request from a paired Mac.
    public var canUpdateRemotely: Bool

    public init(appVersion: String, protocolVersion: UInt16 = anyRemoteProtocolVersion, canUpdateRemotely: Bool) {
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.canUpdateRemotely = canUpdateRemotely
    }

    /// The running app's version (`CFBundleShortVersionString`).
    public static var runningAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

/// A dotted version such as `0.26.0`, compared numerically part by part.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public func hash(into hasher: inout Hasher) {
        var parts = parts
        while parts.last == 0 { parts.removeLast() }
        hasher.combine(parts)
    }
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
/// What one Mac's clipboard now holds, offered to the other.
///
/// Short text travels in the offer, so pasting it never waits. Every other
/// type (rich text, images, long text) is only named here, with a digest
/// of its bytes, and fetched over the transfer connection
/// (`TransferMessage.pasteboard`) when something pastes it, so a large
/// copy never holds up input or the pings that keep the connection, and
/// one that is never pasted never crosses the network.
public struct PasteboardOffer: Codable, Equatable, Sendable {
    /// A type larger than this is not shared (it would be held in memory
    /// on both Macs); the item's other types still are.
    public static let maximumTypeBytes = 64 << 20

    /// Names this offer in fetches. Chosen by the sender; a newer offer
    /// makes the older ones unavailable.
    public var offerID: UInt32
    /// The Mac where this was copied (a random ID per launch) and which of
    /// its copies it is, so a copy relayed through other Macs is applied
    /// once and never comes back to where it started.
    public var origin: UUID
    public var copy: UInt32
    public var items: [PasteboardOfferItem]

    public init(offerID: UInt32, origin: UUID, copy: UInt32, items: [PasteboardOfferItem]) {
        self.offerID = offerID
        self.origin = origin
        self.copy = copy
        self.items = items
    }
}

/// One clipboard item of an offer.
public struct PasteboardOfferItem: Codable, Equatable, Sendable {
    /// Data sent along, by type identifier.
    public var inline: [String: Data]
    /// Types fetched when needed: the SHA-256 of each one's bytes, by type
    /// identifier. With the inline data it tells one copy from another
    /// without fetching anything.
    public var fetched: [String: Data]

    public init(inline: [String: Data] = [:], fetched: [String: Data] = [:]) {
        self.inline = inline
        self.fetched = fetched
    }
}

/// A Mac offering the other side of a pairing: connect back to me with this code.
public struct PeerPairing: Codable, Equatable, Sendable {
    public var hostID: String
    public var name: String
    /// Nil withdraws an earlier offer.
    public var pairingCode: String?
    /// Its listening port, for reaching it by address.
    public var port: UInt16?
    /// It reached the host by address rather than Bonjour, so connecting
    /// back should use its address too.
    public var usesAddress: Bool

    public init(hostID: String, name: String, pairingCode: String?, port: UInt16?, usesAddress: Bool) {
        self.hostID = hostID
        self.name = name
        self.pairingCode = pairingCode
        self.port = port
        self.usesAddress = usesAddress
    }
}

public struct HostApplication: Codable, Hashable, Sendable {
    /// Bundle path on the host; identifies the app in `launchApplication`.
    public var path: String
    public var name: String
    public var bundleIdentifier: String?
    public var isRunning: Bool
    /// The app's `LSApplicationCategoryType` ("public.app-category.utilities"),
    /// for grouping the viewer's Apps grid. Absent from older hosts.
    public var category: String?

    public init(path: String, name: String, bundleIdentifier: String?, isRunning: Bool, category: String? = nil) {
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
        self.category = category
    }
}

/// One host display, in host global points.
public struct DisplaySummary: Codable, Hashable, Sendable {
    public var displayID: UInt32
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var scale: Double
    public var isVirtual: Bool
    /// The display's name ("Built-in Retina Display", "LG UltraFine").
    public var name: String?
    public var isMain: Bool?

    public init(displayID: UInt32, frame: CGRect, visibleFrame: CGRect, scale: Double, isVirtual: Bool,
                name: String? = nil, isMain: Bool? = nil) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.isVirtual = isVirtual
        self.name = name
        self.isMain = isMain
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
    /// The host's AnyRemote, so a newer viewer can offer to update it.
    public var version: AppVersionInfo?

    public init(hostID: String, hostName: String, datagramPort: UInt16, displays: [DisplaySummary],
                missingPermissions: [String], version: AppVersionInfo? = nil) {
        self.hostID = hostID
        self.hostName = hostName
        self.datagramPort = datagramPort
        self.displays = displays
        self.missingPermissions = missingPermissions
        self.version = version
    }
}

/// A video stream of one host surface: the opened window, one of its child
/// windows (menus, popovers, sheets, tooltips, panels), or a whole display.
public struct StreamDescription: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case window
        case child
        /// A whole display (full desktop). `windowID` is the display ID,
        /// `frame` the display's frame, and input points are relative to
        /// its top-left corner.
        case display
        /// What a menu bar item opened that isn't a menu (a popover, a
        /// panel): shown on its own below the viewer's item. Input points
        /// are relative to its top-left corner.
        case popup
    }

    public var streamID: UInt16
    /// The window ID, or the display ID for `.display` streams.
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
    /// Display streams sent as horizontal strips: the stream carrying each
    /// strip, top to bottom; the first is `streamID` itself. Video for a
    /// strip arrives under its own stream ID; everything else (input, size,
    /// close) uses `streamID`.
    public var tileStreamIDs: [UInt16]?

    public init(streamID: UInt16, windowID: UInt32, role: Role, parentStreamID: UInt16?, frame: CGRect,
                layer: Int, title: String, applicationName: String, tileStreamIDs: [UInt16]? = nil) {
        self.tileStreamIDs = tileStreamIDs
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
    /// Text the viewer's input method composed (Chinese, Japanese, ...),
    /// typed on the host as is, whatever its keyboard layout.
    case text(String)
    /// A trackpad pinch, rotation or smart zoom (double-tap with two
    /// fingers). `phase` is an `NSEvent.Phase` raw value (smart zoom: 0);
    /// `value` is the magnification change or the rotation in degrees.
    case gesture(point: CGPoint, kind: GestureKind, phase: UInt32, value: Double, modifiers: UInt64)

    public enum GestureKind: String, Codable, Sendable {
        case magnify
        case rotate
        case smartMagnify
    }
}

/// Whose input method composes text (Chinese, Japanese…) for the host.
public struct TextInputSettings: Codable, Equatable, Sendable {
    /// The viewer's input method composes and the host gets the text; the
    /// host keeps a plain keyboard layout. Otherwise the host's own input
    /// method composes the keys it gets, and the viewer forwards the input
    /// source shortcuts (⌃Space) for the host to switch it.
    public var composesOnViewer: Bool

    public init(composesOnViewer: Bool) {
        self.composesOnViewer = composesOnViewer
    }
}

/// The font of the text at the host's caret, as Accessibility reports it.
public struct CaretFont: Codable, Equatable, Sendable {
    /// PostScript name, e.g. "Menlo-Regular" (".AppleSystemUIFont" for the system font).
    public var name: String
    public var size: Double

    public init(name: String, size: Double) {
        self.name = name
        self.size = size
    }
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
    /// The viewer's window went full screen by itself (green button, ⌃⌘F).
    /// A host window on the virtual display for remote windows goes full
    /// screen there too, filling it exactly; others are only resized.
    case enterFullScreen
    /// The viewer left full screen while the host window was in it (see
    /// `HostWindowStateRequest.enterFullScreen`); the host window leaves too.
    case exitFullScreen
}

/// Window state changes the host app made (menu item, shortcut, title bar
/// double-click, a web page's video). A minimized host window can't be
/// streamed, so the host undoes that and the viewer minimizes its local
/// window instead. Full screen stays on the host, since apps tie their own
/// state to it (Chrome's video full screen ends with the window's), and the
/// viewer's local window follows it in and out.
public enum HostWindowStateRequest: String, Codable, Sendable {
    case minimize
    case enterFullScreen
    case exitFullScreen
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
    /// The host's processor, e.g. "Apple M4 Pro" (older hosts: nil).
    public var chip: String?
    /// Where the host sends this viewer's video (the address its UDP
    /// keepalives come from), or "none" when none arrived: video is then
    /// encoded but not sent. Older hosts: nil.
    public var videoDestination: String?

    public init(captureP50: Double, waitP50: Double, encodeP50: Double, encodeP95: Double,
                framesPerSecond: Double, megabitsPerSecond: Double, bitRate: Int, chip: String? = nil,
                videoDestination: String? = nil) {
        self.chip = chip
        self.videoDestination = videoDestination
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
/// `VideoFragmenter` datagram, kind 3 an `AudioPacket`.
public enum DatagramKind {
    public static let video: UInt8 = 1
    /// Viewer → host: binds the viewer's UDP address to the session.
    public static let keepalive: UInt8 = 2
    public static let keepaliveDatagram = Data([1, keepalive])
    /// Host → viewer: one `AudioPacket` of the host's sound.
    public static let audio: UInt8 = 3
    /// Viewer → host: one `AudioPacket` of the viewer's microphone.
    public static let microphone: UInt8 = 4
}

/// Messages on the sealed control channel. Video and sound travel separately as
/// datagrams.
public enum ControlMessage: Codable, Equatable, Sendable {
    // Session
    /// `screen`: the viewer's screen in use, which the host's
    /// virtual display for remote windows takes (older viewers: nil).
    case authenticate(viewerName: String, takeOver: Bool, screen: ViewerScreen? = nil)
    case welcome(HostWelcome)
    case rejected(reason: String)
    case ping(id: UInt32, viewerTime: UInt64)
    case pong(id: UInt32, viewerTime: UInt64, hostTime: UInt64)
    case goodbye(reason: String)

    // Window library
    // Lists carry no images: thumbnails and icons, megabytes for a full
    // list of apps, would hold up input and pings behind them on this
    // connection. The viewer fetches them over the transfer connection
    // (`TransferMessage.images`).
    case listWindows(requestID: UInt32)
    case windowList(requestID: UInt32, windows: [WindowSummary], displays: [DisplaySummary],
                    missingPermissions: [String])

    /// Installed apps.
    case listApplications(requestID: UInt32)
    case applicationList(requestID: UInt32, applications: [HostApplication])
    /// Opens (or brings forward) the app; its window then opens like a picked one.
    case launchApplication(path: String)
    /// Quits the app (`force`: without letting it ask to save).
    case quitApplication(path: String, force: Bool)
    /// Viewer → host after pairing: the viewer's own pairing code, so the
    /// host can connect back without pairing again (or, without a code,
    /// withdraws that).
    case peerPairing(PeerPairing)
    /// Viewer → host: share the clipboard (or stop).
    case pasteboardSharing(enabled: Bool)
    /// Both ways: the clipboard changed (see `PasteboardOffer`).
    case pasteboardOffer(PasteboardOffer)

    // Streams
    case openWindow(windowID: UInt32)
    /// Streams a whole display (full desktop), at its own resolution.
    case openDisplay(displayID: UInt32)
    /// Dynamic resolution for a display stream: the host shows its desktop
    /// at this size (points, rendered at 2x) in place of the display, or,
    /// with nil, gives the display its own resolution back.
    case desktopSize(streamID: UInt16, size: CGSize?)
    case streamStarted(StreamDescription)
    /// The surface moved or changed title on the host. `windowID`: the
    /// window it shows from now on, when another took its place (a tab;
    /// older hosts: nil).
    case streamMoved(streamID: UInt16, frame: CGRect, title: String, windowID: UInt32? = nil)
    case streamEnded(streamID: UInt16, reason: String)
    case closeStream(streamID: UInt16)
    case requestKeyframe(streamID: UInt16)
    case receiverReport(streamID: UInt16, framesReceived: UInt32, framesDropped: UInt32)
    /// Viewer → host: the most video each of this viewer's streams may use,
    /// in bits per second; nil leaves it to the host's own ceilings. The
    /// host still lowers the rate on loss. Sent once connected and on every
    /// change, before any stream opens.
    case maximumBitRate(Int?)
    /// Viewer → host: frames a second to show this viewer's windows and
    /// desktops at, up to `FrameRate.supported`'s largest (60 until the
    /// viewer says otherwise). The virtual displays its windows are on
    /// refresh at it, and captures follow. Sent once connected and on every
    /// change, before any stream opens.
    case frameRate(Int)
    case hostReport(streamID: UInt16, HostStreamReport)

    // Window control
    case resize(streamID: UInt16, size: CGSize)
    case resizeApplied(streamID: UInt16, size: CGSize)
    /// `screen`: the viewer screen the window is on (older viewers: nil);
    /// the host window moves to that screen's virtual display.
    case focus(streamID: UInt16, screen: ViewerScreen? = nil)
    case input(streamID: UInt16, InputEvent)
    case cursor(CursorImage)
    case windowControls(streamID: UInt16, WindowControls)
    case windowAction(streamID: UInt16, action: WindowAction)
    case windowStateRequest(streamID: UInt16, HostWindowStateRequest)
    /// Host → viewer: the text insertion point of the focused text field, in
    /// points relative to the stream's top-left corner (nil: none known; as
    /// wide as the selection it replaces), so
    /// the viewer's input method shows its candidates next to it, and the
    /// text's font when the app tells (older hosts: nil).
    case caret(streamID: UInt16, rect: CGRect?, font: CaretFont? = nil)
    /// Viewer → host, once connected and on every change.
    case textInput(TextInputSettings)

    // Menu bar
    case requestMenuBar(streamID: UInt16)
    case menuBar(streamID: UInt16, applicationName: String, menus: [MenuNode])
    /// `path` indexes from the top-level menu down to the item.
    case performMenuItem(streamID: UInt16, path: [Int])

    // Sound
    /// Viewer → host: whether to send the sound of what the viewer shows (the
    /// apps of its open windows, or everything with a full desktop open).
    case audio(enabled: Bool)
    /// Host → viewer: sound packets follow in this format; nil when they stop.
    case audioStream(AudioStreamFormat?)

    // Microphone
    /// Viewer → host: whether apps on the host may record from the viewer's
    /// microphone. Sent once connected and on every change.
    case microphone(enabled: Bool)
    /// Host → viewer: whether an app on the host is recording from the
    /// AnyRemote Microphone right now, so the viewer opens its microphone
    /// only meanwhile.
    case microphoneWanted(Bool)
    /// Viewer → host: microphone packets follow in this format; nil when they
    /// stop (the request ended, or this Mac's microphone is not allowed).
    case microphoneStream(AudioStreamFormat?)

    // Drag and drop
    /// Viewer → host, once connected: the token its transfer connection
    /// presents (`TransferMessage.attach`) to join this session.
    case transferToken(Data)
    /// Host → viewer: a drag started on the host under the viewer's press in
    /// this stream. The viewer takes it over with a drag of its own.
    case hostDragBegan(streamID: UInt16, DragManifest)
    /// Viewer → host: the viewer's drag (see `DragEvent`).
    case drag(DragEvent)
    /// Only on the transfer connection.
    case transfer(TransferMessage)

    // Notifications and badges
    /// Viewer → host, once connected and on every change: which of the
    /// host's notifications and Dock badges to send.
    case notices(NoticeSubscription)
    /// Host → viewer: a notification just appeared on the host.
    case hostNotification(HostNotification)
    /// Host → viewer: every Dock badge the host's apps show now, whenever
    /// one changes (and once after subscribing).
    case badges([HostBadge])
    /// Viewer → host: the viewer's copy of a notification was clicked. The
    /// host opens it (or its app) and that app's window opens here.
    case openNotification(id: String, applicationPath: String?)

    // Menu bar items
    /// Viewer → host: the items on the right of the host's menu bar.
    case listStatusItems(requestID: UInt32)
    case statusItems(requestID: UInt32, items: [HostStatusItem])
    /// Viewer → host: click the item. A menu comes back as `statusItemMenu`,
    /// a popover as a `.popup` stream, a window as a mirror.
    case openStatusItem(id: String)
    /// Host → viewer: the menu the item opened, shown on the host until the
    /// viewer answers with `performStatusItemMenu`.
    case statusItemMenu(id: String, menus: [MenuNode])
    /// Viewer → host: choose the item at `path` in the open menu, or close
    /// the menu (nil).
    case performStatusItemMenu(id: String, path: [Int]?)
}

/// One of the viewer's screens. The host keeps a virtual display for remote
/// windows per screen, the screen's size, so a window can be as large as the
/// screen its mirror is on and fills it exactly in full screen.
/// The frame rates a viewer may ask for (`ControlMessage.frameRate`).
public enum FrameRate {
    public static let standard = 60
    public static let supported = [60, 90, 120, 144]

    /// `rate` within what hosts support.
    public static func clamped(_ rate: Int) -> Int {
        min(max(rate, supported.first!), supported.last!)
    }
}

public struct ViewerScreen: Codable, Equatable, Hashable, Sendable {
    /// The viewer's display ID, telling its screens apart.
    public var id: UInt32
    /// In points.
    public var size: CGSize

    public init(id: UInt32, size: CGSize) {
        self.id = id
        self.size = size
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }
}

public enum ControlCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
