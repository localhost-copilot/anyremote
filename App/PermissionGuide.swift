import AnyRemoteHost
import AppKit
import OSLog
import Security
import SwiftUI

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Permissions")

/// Walks through the privacy permissions hosting needs, one at a time.
///
/// "Turn On…" opens the exact System Settings list and floats a small card
/// beside it: what to switch on, and AnyRemote's icon to drag into the list
/// when it isn't there yet. The card notices the switch, moves on to the next
/// missing permission, and closes when everything is on.
///
/// macOS keys these permissions by the app's code signature. Entries recorded
/// for an earlier signature stay in the list, switched on, without effect;
/// `cleanUpStaleEntries` removes them so the list shows the truth.
@MainActor
final class PermissionGuide {
    enum Permission: CaseIterable {
        case screenRecording, accessibility

        var pane: String {
            switch self {
            case .screenRecording: "Privacy_ScreenCapture"
            case .accessibility: "Privacy_Accessibility"
            }
        }

        /// tccutil service names.
        var services: [String] {
            switch self {
            case .screenRecording: ["ScreenCapture"]
            case .accessibility: ["Accessibility", "PostEvent"]
            }
        }


        func isGranted(_ permissions: HostService.Permissions) -> Bool {
            switch self {
            case .screenRecording: permissions.screenRecording
            case .accessibility: permissions.accessibility && permissions.postEvents
            }
        }
    }

    static let shared = PermissionGuide()

    private var panel: NSPanel?
    private var timer: Timer?
    private let state = GuideState()
    /// Development: keep the card up although the permission is granted.
    var isPreview = false

    // MARK: Guide

    func start(_ permission: Permission? = nil) {
        let permissions = HostService.permissions
        guard let next = permission ?? Permission.allCases.first(where: { !$0.isGranted(permissions) }) else {
            finish()
            return
        }
        show(next)
    }

    private func show(_ permission: Permission) {
        state.permission = permission
        state.waitingForRestart = false
        if !isPreview { register(permission) }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.pane)")!)
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = NSHostingView(rootView: GuideCard(state: state, guide: self))
            self.panel = panel
        }
        panel?.setContentSize(panel?.contentView?.fittingSize ?? NSSize(width: 380, height: 150))
        // Let System Settings come up first, then sit beside it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.place()
            self?.panel?.orderFrontRegardless()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// Asking macOS for the permission puts AnyRemote into the list, switched
    /// off, so turning it on is one switch: no "+", no dragging.
    private func register(_ permission: Permission) {
        switch permission {
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        case .accessibility:
            if !AXIsProcessTrusted() {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
        }
        log.notice("registered for \(String(describing: permission), privacy: .public)")
    }

    private func check() {
        guard let permission = state.permission, !isPreview else { return }
        let permissions = HostService.permissions
        if permission.isGranted(permissions) {
            log.notice("permission granted: \(String(describing: permission), privacy: .public)")
            Self.rememberGrants()
            start()
        }
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        state.permission = nil
        Self.rememberGrants()
    }

    /// Next to the System Settings window, else at the bottom of the screen.
    private func place() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        if let settings = windows.first(where: {
            ($0[kCGWindowOwnerName as String] as? String) == "System Settings"
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }), let bounds = settings[kCGWindowBounds as String] as? [String: CGFloat] {
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0,
                               height: bounds["Height"] ?? 0)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            // Window list frames are top-left based; to the right of the window, aligned with its bottom.
            let bottom = primaryHeight - frame.maxY
            let right = NSPoint(x: frame.maxX + 12, y: bottom + 20)
            let below = NSPoint(x: frame.midX - size.width / 2, y: bottom - size.height - 12)
            if visible.contains(NSRect(origin: right, size: size)) {
                origin = right
            } else if visible.contains(NSRect(origin: below, size: size)) {
                origin = below
            } else {
                origin = NSPoint(x: frame.maxX - size.width - 20, y: bottom + 20)
            }
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: Stale entries

    /// The current signature's designated requirement, which permissions are keyed by.
    static var signature: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    private static let grantedSignatureKey = "PermissionsGrantedSignature"

    static func rememberGrants() {
        guard HostService.permissions.allGranted, let signature else { return }
        UserDefaults.standard.set(signature, forKey: grantedSignatureKey)
    }

    /// At launch: a permission that is missing although it was granted to a
    /// different signature (an update) has a dead entry in the list. Remove it,
    /// so turning it on again is one switch instead of "−, +, restart".
    ///
    /// Only after a grant to another signature, and once per signature: a
    /// permission switched on moments ago (macOS relaunches the app for Screen
    /// Recording) must never be taken for a dead entry.
    static func cleanUpStaleEntries() {
        let permissions = HostService.permissions
        log.notice("""
            permissions at launch: screen \(permissions.screenRecording, privacy: .public), \
            accessibility \(permissions.accessibility, privacy: .public), \
            events \(permissions.postEvents, privacy: .public)
            """)
        guard let signature else { return }
        let defaults = UserDefaults.standard
        if permissions.allGranted {
            defaults.set(signature, forKey: grantedSignatureKey)
            return
        }
        guard let granted = defaults.string(forKey: grantedSignatureKey), granted != signature,
              defaults.string(forKey: cleanedSignatureKey) != signature else { return }
        defaults.set(signature, forKey: cleanedSignatureKey)
        for permission in Permission.allCases where !permission.isGranted(permissions) {
            reset(permission)
        }
    }

    private static let cleanedSignatureKey = "PermissionsCleanedSignature"

    static func reset(_ permission: Permission) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        for service in permission.services {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", service, bundleID]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
            log.notice("reset \(service, privacy: .public): \(task.terminationStatus)")
        }
    }

    fileprivate func resetCurrent() {
        guard let permission = state.permission else { return }
        Self.reset(permission)
        // Reopen the list so it shows the entry gone.
        show(permission)
    }

    fileprivate func restart() {
        HostSettingsModel.relaunch()
    }
}

@MainActor
@Observable
private final class GuideState {
    var permission: PermissionGuide.Permission?
    var waitingForRestart = false
}

private struct GuideCard: View {
    let state: GuideState
    let guide: PermissionGuide

    var body: some View {
        if let permission = state.permission {
            HStack(alignment: .top, spacing: 14) {
                AppIconDragSource()
                    .frame(width: 56, height: 56)
                    .help("Drag into the list in System Settings")
                VStack(alignment: .leading, spacing: 6) {
                    Text(permission == .screenRecording ? "Let AnyRemote record the screen"
                                                        : "Let AnyRemote control this Mac")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    // The lists' names change between macOS versions; don't name them.
                    Text("Turn on the switch next to AnyRemote in the list that just opened. Not in the list? Drag this icon into it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Not Working?") { guide.resetCurrent() }
                            .help("Removes AnyRemote’s entry from this list, so it can be added again")
                        if permission == .screenRecording {
                            Button("Restart AnyRemote") { guide.restart() }
                                .help("macOS may only apply Screen Recording after a restart")
                        }
                        Spacer()
                        Button("Later") { guide.finish() }
                            .keyboardShortcut(.cancelAction)
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .frame(width: 400)
        }
    }
}

/// AnyRemote's icon, dragged the way Finder drags an app: as its file URL,
/// which the System Settings privacy lists accept.
private struct AppIconDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView, NSDraggingSource {
        private var icon: NSImage { NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }

        override var mouseDownCanMoveWindow: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            icon.draw(in: bounds)
        }

        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}
