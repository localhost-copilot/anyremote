import AnyRemoteUpdate
import AnyRemoteWire
import AppKit
import SwiftUI

/// The Software Update window: progress of a check the user asked for, or a
/// downloaded update waiting for Install and Relaunch.
struct UpdateView: View {
    @Bindable var update: SoftwareUpdate
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch update.state {
        case .idle, .checking:
            Text("Checking for Updates…").font(.headline)
            ProgressView().progressViewStyle(.linear)
            buttons { Button("Cancel") { close() } }
        case .upToDate:
            Text("AnyRemote Is Up to Date").font(.headline)
            Text("Version \(update.currentVersion) is the latest.").foregroundStyle(.secondary)
            buttons { Button("OK") { close() }.keyboardShortcut(.defaultAction) }
        case .downloading(let version, let fraction):
            Text("Downloading AnyRemote \(version)…").font(.headline)
            ProgressView(value: fraction).progressViewStyle(.linear)
            Text("It’s offered for installing once it’s downloaded and checked.")
                .font(.callout).foregroundStyle(.secondary)
            buttons { Button("Hide") { close() } }
        case .ready(let staged):
            ready(staged.manifest)
        case .installing(let version):
            Text("Installing AnyRemote \(version)…").font(.headline)
            Text("AnyRemote quits and opens again in a moment.").foregroundStyle(.secondary)
            ProgressView().progressViewStyle(.linear)
        case .failed(let message):
            Text("The Update Didn’t Work").font(.headline)
            Text(verbatim: message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Close") { close() }
                Button("Try Again") { Task { await update.check(userInitiated: true) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func ready(_ manifest: UpdateManifest) -> some View {
        Text("AnyRemote \(manifest.version) Is Ready to Install").font(.headline)
        Text("You have version \(update.currentVersion).").foregroundStyle(.secondary)
        let notes = manifest.notes(preferring: [AppLanguage.running])
        // The manifest's notes are a few lines; the full notes are on the release page.
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(notes.prefix(8).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                        Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        if manifest.protocolVersion != anyRemoteProtocolVersion {
            Label("The other Macs need this version too. When you connect to one, AnyRemote offers to update it.",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(update.activityDescription?() ?? [], id: \.self) { line in
            Label(line, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            if let url = manifest.releaseURL {
                Button("Release Notes") { NSWorkspace.shared.open(url) }
            }
            Spacer()
            Button("Later") {
                update.postpone()
                close()
            }
            Button("Install and Relaunch") { update.installAndRelaunch() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
        Text("If you choose Later, it installs when AnyRemote quits.")
            .font(.caption).foregroundStyle(.tertiary)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
        }
        .padding(.top, 4)
    }
}
