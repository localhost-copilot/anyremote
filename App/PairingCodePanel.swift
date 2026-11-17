import AnyRemoteHost
import AnyRemoteWire
import AppKit
import SwiftUI

/// The code another Mac asks for when it pairs with this one, shown the
/// way macOS shows an AirPlay code: a small window in front of everything,
/// with the digits large, until that Mac has typed them, gives up, or the
/// person here cancels.
@MainActor
final class PairingCodePanel {
    private static var current: (id: UInt32, panel: NSPanel)?

    static func show(_ prompt: HostService.PairingPrompt, service: HostService) {
        current?.panel.close()
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PairingCodeView(prompt: prompt) {
            service.cancelPairing(id: prompt.id)
            close(id: prompt.id)
        })
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.center()
        panel.orderFrontRegardless()
        current = (prompt.id, panel)
    }

    static func close(id: UInt32) {
        guard let current, current.id == id else { return }
        current.panel.close()
        self.current = nil
    }
}

private struct PairingCodeView: View {
    let prompt: HostService.PairingPrompt
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("“\(prompt.viewerName)” wants to pair with this Mac")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Enter this code on “\(prompt.viewerName)”:")
                .foregroundStyle(.secondary)
            Text(verbatim: PairingDigits.display(prompt.code))
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(4)
                .textSelection(.enabled)
            Text("Once paired, “\(prompt.viewerName)” can control this Mac. Only pair with Macs you trust.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(width: 360)
    }
}
