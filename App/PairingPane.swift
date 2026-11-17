import AnyRemoteClient
import AnyRemoteWire
import SwiftUI

/// One pairing under way, as the pane shows it.
@MainActor
@Observable
final class PairingFlow {
    enum Phase: Equatable {
        case idle
        /// Asking the other Mac to show a code.
        case requesting
        case enterCode
        case checking
        case wrongCode
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var client: HostPairingClient?
    @ObservationIgnored private var cancelled = false

    var isActive: Bool { client != nil }

    func begin(_ client: HostPairingClient) {
        self.client = client
        cancelled = false
        phase = .requesting
        client.onCodeShown = { [weak self] _ in self?.phase = .enterCode }
        client.onCodeRejected = { [weak self] in self?.phase = .wrongCode }
    }

    func submit(_ digits: String) {
        guard client != nil, phase != .checking else { return }
        phase = .checking
        client?.submit(digits)
    }

    func cancel() {
        cancelled = true
        client?.cancel()
    }

    func finish(_ error: String?) {
        client = nil
        phase = cancelled ? .idle : error.map(Phase.failed) ?? .idle
    }
}

/// Pairing with a Mac, as Apple devices pair: that Mac shows six digits,
/// which are typed here. Each Mac only needs it once.
struct PairingPane: View {
    let target: HostTarget
    let model: ViewerModel
    /// Why the Mac needs pairing again, if it was paired before.
    let error: String?
    @State private var flow = PairingFlow()
    @State private var digits = ""
    @State private var sharesBack = true
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Pair with “\(target.name)”").font(.title2.weight(.semibold))
            switch flow.phase {
            case .idle, .failed:
                start
            case .requesting:
                ProgressView().controlSize(.small)
                Text("Asking “\(target.name)” for a code…").foregroundStyle(.secondary)
            case .enterCode, .checking, .wrongCode:
                codeEntry
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { if flow.isActive { flow.cancel() } }
    }

    private var start: some View {
        VStack(spacing: 16) {
            Text("“\(target.name)” shows a six-digit code, which you enter here. The two Macs only need to pair once.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Toggle("Also let “\(target.name)” control this Mac", isOn: $sharesBack)
                .help("Then “\(target.name)” can connect to this Mac without pairing again")
            if let message = failure {
                Text(message).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Button("Pair") {
                digits = ""
                Task { await model.pair(target, sharesBack: sharesBack, flow: flow) }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
    }

    private var failure: String? {
        if case .failed(let message) = flow.phase { return FriendlyText.message(message) }
        return error
    }

    private var codeEntry: some View {
        VStack(spacing: 14) {
            Text("Enter the code shown on “\(target.name)”.").foregroundStyle(.secondary)
            TextField(text: $digits, prompt: Text(verbatim: "000000")) { Text("Code") }
                .textFieldStyle(.plain)
                .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(6)
                .multilineTextAlignment(.center)
                .frame(width: 220)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
                .focused($codeFocused)
                .disabled(flow.phase == .checking)
                .onAppear { codeFocused = true }
                .onChange(of: digits) { _, text in
                    // Keep the digits only (full-width ones too), at most six;
                    // the sixth sends the code.
                    let kept = String(text.compactMap { $0.wholeNumberValue }.map(String.init).joined().prefix(6))
                    if kept != text { digits = kept }
                    if kept.count == PairingDigits.count { flow.submit(kept) }
                }
            Group {
                if flow.phase == .checking {
                    ProgressView().controlSize(.small)
                } else if flow.phase == .wrongCode {
                    Text("That code isn’t right. Check it and try again.").foregroundStyle(.red)
                } else {
                    Text(verbatim: " ")
                }
            }
            .font(.callout)
            .frame(height: 20)
            Button("Cancel") { flow.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .onChange(of: flow.phase) { _, phase in
            if phase == .wrongCode {
                digits = ""
                codeFocused = true
            }
        }
    }
}
