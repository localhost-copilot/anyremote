import AnyRemoteClient
import AnyRemoteWire
import AppKit
import SwiftUI

/// The window picker: pick a Mac on the left, a window on the right.
///
/// What the user is here to do is open one remote window, so everything is
/// arranged around that: the last used Mac is selected and connected on open,
/// the search field has focus, windows are grouped by app, Return opens the
/// selection and the picker gets out of the way once a window opens.
struct HostsView: View {
    @Bindable var model: ViewerModel
    @State private var addingHost = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, addingHost: $addingHost)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            if let id = model.selection, let target = model.target(id: id) {
                HostDetailView(target: target, model: model)
                    .id(target.id)
            } else {
                EmptyHostsView(model: model, addingHost: $addingHost)
            }
        }
        .sheet(isPresented: $addingHost) { AddHostSheet(model: model) }
        .frame(minWidth: 780, minHeight: 500)
        .onAppear {
            if model.selection.flatMap(model.target(id:)) == nil { model.selection = model.preferredTargetID }
        }
        .onChange(of: model.myMacs.map(\.id) + model.newNearby.map(\.id)) {
            if model.selection.flatMap(model.target(id:)) == nil { model.selection = model.preferredTargetID }
        }
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    @Bindable var model: ViewerModel
    @Binding var addingHost: Bool
    @State private var renaming: HostTarget?

    var body: some View {
        List(selection: $model.selection) {
            Section("My Macs") {
                if model.myMacs.isEmpty {
                    Text("No paired Macs yet").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(model.myMacs) { target in
                    HostRow(target: target, model: model).tag(target.id)
                        .contextMenu {
                            if model.connection(for: target)?.state == .connected {
                                Button("Disconnect") { model.disconnect(target) }
                            }
                            if target.kind != .thisMac {
                                Button("Rename…") { renaming = target }
                                Divider()
                                Button("Forget This Mac", role: .destructive) { model.forget(target) }
                            }
                        }
                }
            }
            Section("Nearby") {
                if model.newNearby.isEmpty {
                    Text("No other Macs found").foregroundStyle(.secondary).font(.callout)
                        .help("Other Macs need to run AnyRemote on the same network. If one doesn’t appear, check that AnyRemote is allowed in System Settings › Privacy & Security › Local Network, or use “Add by Address” below.")
                }
                ForEach(model.newNearby) { target in
                    HostRow(target: target, model: model).tag(target.id)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { addingHost = true } label: {
                Label("Add by Address…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .sheet(item: $renaming) { target in RenameSheet(target: target, model: model) }
    }
}

private struct HostRow: View {
    let target: HostTarget
    let model: ViewerModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: target.kind == .thisMac ? "desktopcomputer" : "macmini")
                .font(.title3)
                .foregroundStyle(target.kind == .offline ? .tertiary : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(status.color).frame(width: 6, height: 6)
                    Text(status.text).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var status: (text: String, color: Color) {
        let connection = model.connection(for: target)
        switch connection?.state {
        case .connected?:
            let count = connection?.listing?.windows.count
            let text = count.map { $0 == 1 ? String(localized: "Connected · 1 window") : String(localized: "Connected · \($0) windows") }
            return (text ?? String(localized: "Connected"), .green)
        case .connecting?:
            return (String(localized: "Connecting…"), .orange)
        case .failed(let message)?:
            if FriendlyText.isBusy(message) { return (String(localized: "In use by someone else"), .orange) }
            if FriendlyText.isPairingFailure(message) { return (String(localized: "Wrong pairing code"), .red) }
            return (String(localized: "Couldn’t connect"), .red)
        case .disconnected?, nil:
            break
        }
        if model.code(for: target) == nil { return (String(localized: "Needs pairing"), .gray) }
        switch target.kind {
        case .offline: return (String(localized: "Offline"), .gray.opacity(0.5))
        case .saved: return (model.pairedHost(for: target)?.address ?? String(localized: "Connect by address"), .gray)
        case .discovered, .thisMac: return (String(localized: "Online"), .blue)
        }
    }
}

private struct EmptyHostsView: View {
    let model: ViewerModel
    @Binding var addingHost: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Connect Another Mac", systemImage: "macmini")
        } description: {
            Text("Install and open AnyRemote on the other Mac and it appears under “Nearby” on the left.\nIf it isn’t on the same network, add it by IP address.")
        } actions: {
            Button("Add by Address…") { addingHost = true }
        }
    }
}

// MARK: Detail

struct HostDetailView: View {
    let target: HostTarget
    let model: ViewerModel
    @State private var working = false

    private var connection: HostConnection? { model.connection(for: target) }

    var body: some View {
        content
            .navigationTitle(connection?.hostName ?? target.name)
            .task(id: target.id) {
                if connection == nil, model.code(for: target) != nil, target.kind != .offline { await connect() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let connection, connection.state == .connected {
            WindowPicker(connection: connection, model: model, target: target)
        } else if working || connection?.state == .connecting {
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to “\(target.name)”…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.code(for: target) == nil || isFailure(FriendlyText.isPairingFailure) {
            PairingPane(target: target, model: model, error: failureMessage.map(FriendlyText.message))
        } else if isFailure(FriendlyText.isBusy) {
            StatusPane(symbol: "person.2.fill", title: FriendlyText.message(failureMessage ?? ""),
                       detail: String(localized: "Only one Mac can control it at a time. Taking over disconnects the other one.")) {
                Button("Take Over") { Task { await connect(takeOver: true) } }.keyboardShortcut(.defaultAction)
            }
        } else if let failureMessage {
            StatusPane(symbol: "exclamationmark.triangle", title: String(localized: "Can’t connect to “\(target.name)”"),
                       detail: FriendlyText.message(failureMessage)) {
                Button("Try Again") { Task { await connect() } }.keyboardShortcut(.defaultAction)
            }
        } else if target.kind == .offline {
            StatusPane(symbol: "moon.zzz", title: String(localized: "“\(target.name)” is offline"),
                       detail: String(localized: "It appears automatically once it’s on and running AnyRemote.")) {
                Button("Try Anyway") { Task { await connect() } }
            }
        } else {
            StatusPane(symbol: "macmini", title: target.name, detail: String(localized: "Disconnected.")) {
                Button("Connect") { Task { await connect() } }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var failureMessage: String? {
        if case .failed(let message)? = connection?.state { return message }
        return nil
    }

    private func isFailure(_ test: (String) -> Bool) -> Bool { failureMessage.map(test) ?? false }

    private func connect(takeOver: Bool = false) async {
        working = true
        await model.connect(target, takeOver: takeOver)
        working = false
    }
}

private struct StatusPane<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(verbatim: detail)
        } actions: {
            actions
        }
    }
}

private struct PairingPane: View {
    let target: HostTarget
    let model: ViewerModel
    let error: String?
    @State private var codeText = ""
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Pair with “\(target.name)”").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("On “\(target.name)”, click the AnyRemote icon in the menu bar and choose “Show Pairing Code”.", systemImage: "1.circle")
                Label("Enter the 20-character code below. Each Mac only needs to be paired once.", systemImage: "2.circle")
            }
            .foregroundStyle(.secondary)
            TextField("XXXXX-XXXXX-XXXXX-XXXXX", text: $codeText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 340)
                .focused($focused)
                .onSubmit(pair)
            if let error, codeText.isEmpty || working {
                Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if working {
                ProgressView().controlSize(.small)
            } else {
                Button("Pair and Connect", action: pair)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(PairingCode(codeText) == nil)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private func pair() {
        guard let code = PairingCode(codeText) else { return }
        Task {
            working = true
            await model.connect(target, code: code)
            working = false
            codeText = ""
        }
    }
}

// MARK: Window picker

private struct AppGroup: Identifiable {
    var id: String
    var name: String
    var bundleIdentifier: String?
    var windows: [WindowSummary]
}

private struct WindowPicker: View {
    let connection: HostConnection
    let model: ViewerModel
    let target: HostTarget
    @State private var query = ""
    @State private var selection: UInt32?
    /// Until the user picks a window, the selection follows the first match.
    @State private var userSelected = false
    @State private var columns = 3
    @FocusState private var searchFocused: Bool
    @FocusState private var gridFocused: Bool

    /// Windows matching the search, grouped by app in the host's front-to-back order.
    private var groups: [AppGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var groups: [AppGroup] = []
        var index: [String: Int] = [:]
        for window in connection.listing?.windows ?? [] {
            if !needle.isEmpty, !window.title.localizedCaseInsensitiveContains(needle),
               !window.applicationName.localizedCaseInsensitiveContains(needle) { continue }
            let key = window.bundleIdentifier ?? window.applicationName
            if let position = index[key] {
                groups[position].windows.append(window)
            } else {
                index[key] = groups.count
                groups.append(AppGroup(id: key, name: window.applicationName,
                                       bundleIdentifier: window.bundleIdentifier, windows: [window]))
            }
        }
        return groups
    }

    var body: some View {
        let groups = groups
        let flat = groups.flatMap(\.windows)
        VStack(spacing: 0) {
            banners
            GeometryReader { proxy in
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20, pinnedViews: []) {
                            ForEach(groups) { group in
                                AppSection(group: group, connection: connection, selection: selection,
                                           select: { selection = $0; userSelected = true; gridFocused = true },
                                           open: open)
                            }
                        }
                        .padding(20)
                    }
                    .onChange(of: selection) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) } }
                    }
                }
                .onAppear { columns = Self.columnCount(width: proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in columns = Self.columnCount(width: width) }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(.return) { openSelected(in: flat); return .handled }
            .onKeyPress(.leftArrow) { move(-1, in: flat); return .handled }
            .onKeyPress(.rightArrow) { move(1, in: flat); return .handled }
            .onKeyPress(.upArrow) { move(-columns, in: flat); return .handled }
            .onKeyPress(.downArrow) { move(columns, in: flat); return .handled }
            .overlay { emptyState(isEmpty: flat.isEmpty) }
            footer
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search windows or apps")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { openSelected(in: flat) }
        .onChange(of: query) { userSelected = false; selection = flat.first?.windowID }
        .onChange(of: flat.map(\.windowID), initial: true) { _, ids in
            if !userSelected || selection.map({ !ids.contains($0) }) ?? true {
                userSelected = false
                selection = ids.first
            }
        }
        .toolbar { toolbar }
        .onAppear { searchFocused = true }
        .task {
            // Thumbnails and the window list stay fresh while the picker is visible.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await connection.refresh()
            }
        }
    }

    private static func columnCount(width: CGFloat) -> Int {
        // Mirrors GridItem(.adaptive(minimum: 200), spacing: 16) inside 20 pt padding.
        max(1, Int((width - 40 + 16) / (200 + 16)))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await connection.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh the window list")
            Button { FullDesktop.open(connection) } label: { Label("Full Desktop", systemImage: "display") }
                .help("Open the whole desktop in Screen Sharing (or iScreenSharing, if installed)")
            Button { model.disconnect(target) } label: { Label("Disconnect", systemImage: "xmark.circle") }
                .help("Disconnect from this Mac and close all of its windows")
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let reason = connection.captureBlockedReason ?? connection.inputBlockedReason {
            Label(reason + " " + String(localized: "This recovers on its own once it’s granted in AnyRemote › Settings on that Mac."),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.18))
        }
    }

    @ViewBuilder
    private func emptyState(isEmpty: Bool) -> some View {
        if isEmpty, connection.listing != nil {
            if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView("No Windows to Share", systemImage: "macwindow",
                                       description: Text("“\(connection.hostName)” has no open windows."))
            }
        } else if connection.listing == nil {
            ProgressView()
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("Double-click or press ↩ to open · Arrow keys to select · Hold ⌥ to keep this window open")
            Spacer()
            Text("Press ⌃⌥⌘0 anytime to come back here")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func move(_ offset: Int, in flat: [WindowSummary]) {
        guard !flat.isEmpty else { return }
        let current = flat.firstIndex { $0.windowID == selection } ?? (offset > 0 ? -1 : flat.count)
        selection = flat[min(max(current + offset, 0), flat.count - 1)].windowID
        userSelected = true
    }

    private func openSelected(in flat: [WindowSummary]) {
        if let window = flat.first(where: { $0.windowID == selection }) ?? flat.first { open(window) }
    }

    private func open(_ window: WindowSummary) {
        model.open(window, on: connection, keepPicker: NSEvent.modifierFlags.contains(.option))
    }
}

private struct AppSection: View {
    let group: AppGroup
    let connection: HostConnection
    let selection: UInt32?
    let select: (UInt32) -> Void
    let open: (WindowSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon = group.bundleIdentifier.flatMap({ connection.listing?.icons[$0] }).flatMap(NSImage.init(data:)) {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                Text(group.name).font(.headline)
                if group.windows.count > 1 {
                    Text("\(group.windows.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16, alignment: .top)],
                      alignment: .leading, spacing: 16) {
                ForEach(group.windows, id: \.windowID) { window in
                    WindowCard(window: window, thumbnail: connection.listing?.thumbnails[window.windowID],
                               isSelected: selection == window.windowID,
                               isOpen: connection.openWindowIDs.contains(window.windowID))
                        .id(window.windowID)
                        .onTapGesture(count: 2) { open(window) }
                        .simultaneousGesture(TapGesture().onEnded { select(window.windowID) })
                        .contextMenu { Button(connection.openWindowIDs.contains(window.windowID) ? LocalizedStringKey("Switch to This Window") : LocalizedStringKey("Open")) { open(window) } }
                }
            }
        }
    }
}

private struct WindowCard: View {
    let window: WindowSummary
    let thumbnail: Data?
    let isSelected: Bool
    let isOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6))
                if let thumbnail, let image = NSImage(data: thumbnail) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if isOpen {
                    Text("Opened")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
            .frame(height: 140)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(window.title.isEmpty ? window.applicationName : window.title)
                    .lineLimit(1)
                    .fontWeight(isSelected ? .medium : .regular)
                Text(verbatim: "\(Int(window.frame.width)) × \(Int(window.frame.height))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .help(window.title)
    }
}

// MARK: Sheets

private struct AddHostSheet: View {
    let model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var code = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Mac by Address").font(.title3.weight(.semibold))
            Text("Use this when the Mac isn’t on the same network or doesn’t show up under “Nearby”. Find the pairing code on that Mac under the AnyRemote menu bar icon › Show Pairing Code.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Address", text: $address, prompt: Text("192.168.1.20 or mac-mini.local"))
                TextField("Pairing Code", text: $code, prompt: Text("XXXXX-XXXXX-XXXXX-XXXXX"))
                    .font(.system(.body, design: .monospaced))
                TextField("Name", text: $name, prompt: Text("Optional; defaults to the Mac’s name"))
            }
            if let error = model.lastError {
                Text(FriendlyText.message(error)).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    guard let pairing = PairingCode(code) else { return }
                    Task {
                        working = true
                        let added = await model.addManualHost(name: name, address: address, code: pairing)
                        working = false
                        if added { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.isEmpty || PairingCode(code) == nil || working)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { model.lastError = nil }
    }
}

private struct RenameSheet: View {
    let target: HostTarget
    let model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename “\(target.name)”").font(.headline)
            TextField("Name", text: $name).frame(width: 300).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK", action: save).keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = target.name }
    }

    private func save() {
        model.rename(target, to: name)
        dismiss()
    }
}

/// Full-desktop sessions use Apple's Screen Sharing protocol, through
/// iScreenSharing (high-performance mode) when it is installed.
enum FullDesktop {
    static let iScreenSharingBundleID = "com.wangkai.iShareScreen"

    @MainActor
    static func open(_ connection: HostConnection) {
        guard let host = connection.hostAddressForURL, let url = URL(string: "vnc://\(host)") else { return }
        let workspace = NSWorkspace.shared
        if let app = workspace.urlForApplication(withBundleIdentifier: iScreenSharingBundleID) {
            workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(url)
        }
    }
}
