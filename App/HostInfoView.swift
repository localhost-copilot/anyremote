import AnyRemoteClient
import AnyRemoteNetwork
import AnyRemoteWire
import SwiftUI

/// Everything about one paired Mac in one place, laid out as Screen
/// Sharing's Info and the Wi-Fi Details sheet: who it is and how it's
/// connected on top, then untitled groups that fit without scrolling.
/// Edits wait for Done, so Cancel leaves the Mac as it was. Opened from its
/// context menu (Info…), ⌘I in the picker, or the menu bar panel.
struct HostInfoSheet: View {
    let target: HostTarget
    let model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    /// As the sheet opened, and as edited: Done applies only what changed,
    /// so it doesn't undo what changed meanwhile (Bonjour taking the
    /// address's place once the Mac is found nearby).
    @State private var original = Fields()
    @State private var edited = Fields()
    @State private var confirmingForget = false

    private struct Fields: Equatable {
        var name = ""
        var address = ""
        var route = RoutePreference.automatic
        var bitRate: Int?
        var frameRate = FrameRate.standard
        var sharesBack = true
    }

    /// The caps offered besides Automatic, in Mbps, from the host's floor
    /// (`VideoQualityView.range`) to its full-desktop ceiling.
    private static let bitRateChoices = [10, 20, 40, 80, 120]

    private var host: PairedHost? { model.pairedHost(for: target) }
    private var connection: HostConnection? { model.connection(for: target) }
    private var isConnected: Bool { connection?.state == .connected }
    private var shownName: String {
        let trimmed = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? target.name : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
            Form {
                Section {
                    TextField("Name", text: $edited.name)
                }
                networkSection
                Section {
                    Picker("Video Quality", selection: $edited.bitRate) {
                        Text("Automatic").tag(Int?.none)
                        Divider()
                        ForEach(bitRates, id: \.self) { rate in
                            Text("Up to \(rate / 1_000_000) Mbps").tag(Int?.some(rate))
                        }
                    }
                    Picker("Frame Rate", selection: $edited.frameRate) {
                        ForEach(FrameRate.supported, id: \.self) { Text("\($0) Hz").tag($0) }
                    }
                }
                Section {
                    Toggle("Let “\(shownName)” Control This Mac", isOn: $edited.sharesBack)
                } footer: {
                    footnote
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("Forget This Mac…") { confirmingForget = true }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { if save() { dismiss() } }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        // Room for "Connected · Tailscale, peer relay · 123 ms" next to Disconnect.
        .frame(width: 480)
        .onAppear {
            model.lastError = nil
            original = Fields(name: host?.name ?? target.name, address: host?.address ?? "",
                              route: host?.routePreference ?? .automatic, bitRate: host?.maximumBitRate,
                              frameRate: host?.frameRate ?? FrameRate.standard, sharesBack: model.sharesBack(target))
            edited = original
        }
        .confirmationDialog("Forget “\(target.name)”?", isPresented: $confirmingForget) {
            Button("Forget This Mac", role: .destructive) {
                dismiss()
                model.forget(target)
            }
        } message: {
            Text("Pair with it again to control it from here.")
        }
    }

    // MARK: Parts

    /// The Mac, and how it's connected right now. Rechecked every second:
    /// the latency moves, and a Tailscale path often turns direct.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "macmini")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 10, style: .continuous))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let status = status
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: shownName).font(.headline).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(status.color).frame(width: 7, height: 7)
                        Text(verbatim: status.text).lineLimit(1)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .help(isConnected ? connection?.routeDescription ?? "" : "")
            }
            Spacer(minLength: 12)
            if isConnected {
                Button("Disconnect") { model.disconnect(target) }
            } else {
                Button("Connect") {
                    guard save() else { return }
                    dismiss()
                    Task { await model.connect(target) }
                }
            }
        }
    }

    /// Every way to reach it: the address typed here, the ones it told, and
    /// which of them to use.
    private var networkSection: some View {
        Section {
            TextField("Address", text: $edited.address, prompt: Text("Automatic"))
                .help("Set an address when that Mac is on another subnet and isn’t found nearby; the default port is 47800. Leave it empty to find it nearby or by the addresses it told.")
            if let local = host?.localAddresses, !local.isEmpty {
                LabeledContent(local.count == 1 ? "Local Address" : "Local Addresses") {
                    Text(verbatim: local.joined(separator: ", ")).textSelection(.enabled)
                }
            }
            if let tailnetAddress = host?.tailnetAddress {
                LabeledContent("Tailscale Address") {
                    Text(verbatim: tailnetAddress).textSelection(.enabled)
                }
            }
            // Only a choice once Tailscale is one of the ways.
            if host?.tailnetAddress != nil || edited.route != .automatic {
                Picker("Route", selection: $edited.route) {
                    Text("Automatic").tag(RoutePreference.automatic)
                    Text("Local Network Only").tag(RoutePreference.localOnly)
                    Text("Tailscale Only").tag(RoutePreference.tailnetOnly)
                }
                .help(routeExplanation)
            }
        } footer: {
            if let error = model.lastError {
                Text(FriendlyText.message(error)).foregroundStyle(.red)
            }
        }
    }

    /// The quiet facts under the last group, as Screen Sharing's "Last connected".
    @ViewBuilder
    private var footnote: some View {
        let line = [host?.lastConnected.map { String(localized: "Last connected \($0.formatted(date: .abbreviated, time: .shortened))") },
                    connection?.hostVersion.map { String(localized: "AnyRemote \($0.appVersion)") }]
            .compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 4) {
            if host?.credential?.isLegacy == true {
                Text("Paired with the 20-character code of AnyRemote before 0.31.")
            }
            if !line.isEmpty { Text(verbatim: line) }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Helpers

    private var status: (text: String, color: Color) {
        guard let connection, isConnected else {
            let status = HostStatus(target, model: model)
            return (status.text, status.color)
        }
        let parts = [String(localized: "Connected"), connection.routePath,
                     connection.client.roundTripMilliseconds.map { String(format: "%.0f ms", $0) }]
        return (parts.compactMap { $0 }.joined(separator: " · "), connection.isRelayed ? .orange : .green)
    }

    /// The offered caps, plus one set another way (the Video Quality slider).
    private var bitRates: [Int] {
        Set(Self.bitRateChoices.map { $0 * 1_000_000 } + [edited.bitRate].compactMap { $0 }).sorted()
    }

    private var routeExplanation: String {
        switch edited.route {
        case .automatic:
            String(localized: "Tries every way at once and takes the local network when it answers, Tailscale otherwise.")
        case .localOnly:
            String(localized: "Never goes through Tailscale, even when the local network can’t reach that Mac.")
        case .tailnetOnly:
            String(localized: "Always goes through Tailscale: for networks where a local connection opens but the picture doesn’t come through.")
        }
    }

    /// Applies what was edited, the address first; false, with the error
    /// shown and nothing changed, for an address that can't be used.
    private func save() -> Bool {
        guard host != nil else { return true }
        let address = edited.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if address != original.address, !model.setAddress(target, to: address) { return false }
        let name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != original.name, !name.isEmpty { model.rename(target, to: name) }
        if edited.route != original.route { model.setRoutePreference(target, edited.route) }
        if edited.bitRate != original.bitRate { model.setMaximumBitRate(target, edited.bitRate) }
        if edited.frameRate != original.frameRate { model.setFrameRate(target, edited.frameRate) }
        if edited.sharesBack != original.sharesBack { model.setSharesBack(target, edited.sharesBack) }
        original = edited
        return true
    }
}
