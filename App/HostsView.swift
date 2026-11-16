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
    @State private var editingAddress: HostTarget?
    @State private var choosingQuality: HostTarget?

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
                            if model.canUpdate(target) {
                                Button("Update “\(target.name)” to AnyRemote \(AppVersionInfo.runningAppVersion)") {
                                    model.selection = target.id
                                    Task { await model.updateHost(target) }
                                }
                            }
                            if target.kind != .thisMac {
                                Toggle("Let “\(target.name)” Control This Mac", isOn: Binding(
                                    get: { model.sharesBack(target) },
                                    set: { model.setSharesBack(target, $0) }))
                                Button("Rename…") { renaming = target }
                                Button("Edit Address…") { editingAddress = target }
                                if model.pairedHost(for: target) != nil {
                                    Button("Video Quality…") { choosingQuality = target }
                                }
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
        .sheet(item: $editingAddress) { target in AddressSheet(target: target, model: model) }
        .sheet(item: $choosingQuality) { target in VideoQualityView(target: target, model: model, showsDone: true) }
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
            if connection?.versionMismatch != nil { return (String(localized: "Needs an update"), .orange) }
            if model.remoteUpdates[target.id] != nil { return (String(localized: "Updating…"), .orange) }
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
        if let connection, connection.state == .connected, model.remoteUpdates[target.id] == nil {
            WindowPicker(connection: connection, model: model, target: target)
        } else if let update = model.remoteUpdates[target.id] {
            RemoteUpdatePane(target: target, model: model, state: update)
        } else if working || connection?.state == .connecting {
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to “\(target.name)”…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.code(for: target) == nil || isFailure(FriendlyText.isPairingFailure) {
            PairingPane(target: target, model: model, error: failureMessage.map(FriendlyText.message))
        } else if failureMessage != nil, let mismatch = connection?.versionMismatch {
            VersionMismatchPane(target: target, model: model, host: mismatch.host) { Task { await connect() } }
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

/// The two Macs speak different protocols: update the older one.
private struct VersionMismatchPane: View {
    let target: HostTarget
    let model: ViewerModel
    let host: AppVersionInfo?
    let retry: () -> Void

    static let releasesURL = URL(string: "https://github.com/localhost-copilot/anyremote/releases/latest")!
    private var mine: String { AppVersionInfo.runningAppVersion }

    var body: some View {
        if let host {
            if isOlder(host) {
                StatusPane(symbol: "arrow.down.circle", title: String(localized: "“\(target.name)” runs AnyRemote \(host.appVersion)"),
                           detail: host.canUpdateRemotely
                            ? String(localized: "This Mac runs \(mine), and both need the same version. Update “\(target.name)” from here: it takes about a minute and reconnects by itself.")
                            : String(localized: "This Mac runs \(mine), and both need the same version. That copy can’t be updated from here: install AnyRemote \(mine) on it.")) {
                    if host.canUpdateRemotely {
                        Button("Update “\(target.name)”") { Task { await model.updateHost(target) } }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Download Page") { NSWorkspace.shared.open(Self.releasesURL) }
                    }
                    Button("Try Again", action: retry)
                }
            } else {
                StatusPane(symbol: "arrow.down.circle", title: String(localized: "“\(target.name)” runs a newer AnyRemote (\(host.appVersion))"),
                           detail: String(localized: "This Mac runs \(mine), and both need the same version. Update this Mac to connect.")) {
                    if SoftwareUpdate.shared.isSupported {
                        Button("Update This Mac") { Task { await SoftwareUpdate.shared.check(userInitiated: true) } }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Download Page") { NSWorkspace.shared.open(Self.releasesURL) }
                    }
                    Button("Try Again", action: retry)
                }
            }
        } else {
            StatusPane(symbol: "arrow.down.circle", title: String(localized: "“\(target.name)” runs an older AnyRemote"),
                       detail: String(localized: "Install AnyRemote \(mine) on “\(target.name)” by hand this once. Versions from 0.26 on can be updated from here.")) {
                Button("Download Page") { NSWorkspace.shared.open(Self.releasesURL) }
                Button("Try Again", action: retry)
            }
        }
    }

    private func isOlder(_ host: AppVersionInfo) -> Bool {
        if host.protocolVersion != anyRemoteProtocolVersion { return host.protocolVersion < anyRemoteProtocolVersion }
        return (AppVersion(host.appVersion) ?? AppVersion("0")!) < (AppVersion(mine) ?? AppVersion("0")!)
    }
}

/// An update of the other Mac asked for from here.
private struct RemoteUpdatePane: View {
    let target: HostTarget
    let model: ViewerModel
    let state: ViewerModel.RemoteUpdateState

    var body: some View {
        switch state {
        case .asking:
            progress(String(localized: "Updating “\(target.name)”…"),
                     String(localized: "That Mac downloads and checks the new version, then relaunches. This takes about a minute."))
        case .relaunching(let version):
            progress(String(localized: "“\(target.name)” is relaunching with AnyRemote \(version)…"),
                     String(localized: "It reconnects as soon as it’s back."))
        case .failed(let message):
            StatusPane(symbol: "exclamationmark.triangle", title: String(localized: "Couldn’t update “\(target.name)”"),
                       detail: message) {
                Button("OK") { model.dismissRemoteUpdate(target) }
                Button("Try Again") { Task { await model.updateHost(target) } }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func progress(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(verbatim: title).font(.headline)
            Text(verbatim: detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var sharesBack = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Pair with “\(target.name)”").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("On “\(target.name)”, click the AnyRemote icon in the menu bar and choose ⋯ › Show Pairing Code.", systemImage: "1.circle")
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
            Toggle("Also let “\(target.name)” control this Mac", isOn: $sharesBack)
                .help("Then “\(target.name)” can connect to this Mac without pairing again")
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
            await model.connect(target, code: code, sharesBack: sharesBack)
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

/// One titled group of the Apps grid (Recent, Running, Not Running).
struct AppShelf: Identifiable {
    var title: String
    var apps: [HostApplication]
    var id: String { title }

    /// The app an arrow key moves the selection to. `offset` is ±1 for
    /// left/right and ±`columns` for up/down; up and down stay in the same
    /// column and cross into the neighbouring shelf, whose rows start afresh.
    static func move(from selected: String?, by offset: Int, columns: Int, in shelves: [AppShelf]) -> String? {
        guard !shelves.isEmpty else { return nil }
        let columns = max(1, columns)
        guard let selected,
              let s = shelves.firstIndex(where: { $0.apps.contains { $0.path == selected } }),
              let i = shelves[s].apps.firstIndex(where: { $0.path == selected }) else {
            return offset > 0 ? shelves.first?.apps.first?.path : shelves.last?.apps.last?.path
        }
        if abs(offset) < columns || columns == 1 {
            let flat = shelves.flatMap(\.apps)
            let position = flat.firstIndex { $0.path == selected } ?? 0
            return flat[min(max(position + offset.signum(), 0), flat.count - 1)].path
        }
        let shelf = shelves[s].apps
        let column = i % columns
        if offset > 0 {
            if i + columns < shelf.count { return shelf[i + columns].path }
            // The last row may be short: land on its last tile before leaving the shelf.
            if i / columns < (shelf.count - 1) / columns { return shelf[shelf.count - 1].path }
            guard s + 1 < shelves.count else { return selected }
            let next = shelves[s + 1].apps
            return next[min(column, next.count - 1)].path
        } else {
            if i >= columns { return shelf[i - columns].path }
            guard s > 0 else { return selected }
            let previous = shelves[s - 1].apps
            let lastRow = (previous.count - 1) / columns * columns
            return previous[min(lastRow + column, previous.count - 1)].path
        }
    }
}

private enum PickerMode: String {
    case windows, apps
}

private struct WindowPicker: View {
    let connection: HostConnection
    let model: ViewerModel
    let target: HostTarget
    @AppStorage("pickerMode") private var mode = PickerMode.windows
    @State private var query = ""
    @State private var selection: UInt32?
    @State private var appSelection: String?
    @State private var launching: String?
    /// Until the user picks a window, the selection follows the first match.
    @State private var userSelected = false
    @State private var columns = 3
    @State private var showsVideoQuality = false
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

    /// Apps matching the search, in the order the user is likeliest to want
    /// them: the ones opened from here lately (most recent first), then the
    /// others running there, then the rest by name.
    private var appShelves: [AppShelf] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let all = connection.offeredApplications
        let matching = needle.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        let recent = RecentApplications.applications(host: connection.welcome?.hostID ?? "", in: matching)
        let recentPaths = Set(recent.map(\.path))
        let rest = matching.filter { !recentPaths.contains($0.path) }
        return [AppShelf(title: String(localized: "Recent"), apps: recent),
                AppShelf(title: String(localized: "Running"), apps: rest.filter(\.isRunning)),
                AppShelf(title: String(localized: "Not Running"), apps: rest.filter { !$0.isRunning })]
            .filter { !$0.apps.isEmpty }
    }

    var body: some View {
        let groups = groups
        let flat = groups.flatMap(\.windows)
        let shelves = mode == .apps ? appShelves : []
        let apps = shelves.flatMap(\.apps)
        VStack(spacing: 0) {
            banners
            Picker("Show", selection: $mode) {
                Text("Windows").tag(PickerMode.windows)
                Text("Apps").tag(PickerMode.apps)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Windows open on that Mac, or apps to open there")
            .padding(.top, 12)
            GeometryReader { proxy in
                ScrollViewReader { scroller in
                    ScrollView {
                        if mode == .windows {
                            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: []) {
                                ForEach(groups) { group in
                                    AppSection(group: group, connection: connection, selection: selection,
                                               select: { selection = $0; userSelected = true; gridFocused = true },
                                               open: open)
                                }
                            }
                            .padding(20)
                        } else {
                            // Not lazy: scrollTo can only reach tiles of shelves that have been laid out.
                            VStack(alignment: .leading, spacing: 20) {
                                ForEach(shelves) { shelf in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(shelf.title).font(.headline)
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.appTileWidth), spacing: 8)],
                                                  alignment: .leading, spacing: 8) {
                                            ForEach(shelf.apps, id: \.path) { app in appTile(app) }
                                        }
                                    }
                                }
                            }
                            .padding(20)
                        }
                    }
                    .onChange(of: selection) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) } }
                    }
                    .onChange(of: appSelection) { _, path in
                        if let path { withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(path) } }
                    }
                }
                .onAppear { columns = Self.columnCount(width: proxy.size.width, mode: mode) }
                .onChange(of: proxy.size.width) { _, width in columns = Self.columnCount(width: width, mode: mode) }
                .onChange(of: mode) { _, mode in columns = Self.columnCount(width: proxy.size.width, mode: mode) }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(.return) { openSelected(in: flat, apps: apps); return .handled }
            .onKeyPress(.leftArrow) { move(-1, in: flat, shelves: shelves); return .handled }
            .onKeyPress(.rightArrow) { move(1, in: flat, shelves: shelves); return .handled }
            .onKeyPress(.upArrow) { move(-columns, in: flat, shelves: shelves); return .handled }
            .onKeyPress(.downArrow) { move(columns, in: flat, shelves: shelves); return .handled }
            .overlay { mode == .windows ? AnyView(emptyState(isEmpty: flat.isEmpty)) : AnyView(appsEmptyState(isEmpty: apps.isEmpty)) }
            footer
        }
        .searchable(text: $query, placement: .toolbar, prompt: mode == .windows ? "Search windows" : "Search apps")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { openSelected(in: flat, apps: apps) }
        .onChange(of: query) {
            userSelected = false
            selection = flat.first?.windowID
            appSelection = apps.first?.path
        }
        .onChange(of: apps.map(\.path)) { _, paths in
            if appSelection.map({ !paths.contains($0) }) ?? true { appSelection = paths.first }
        }
        .task(id: mode) {
            if mode == .apps { await connection.loadApplications() }
        }
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

    private static let appTileWidth: CGFloat = 112

    private static func columnCount(width: CGFloat, mode: PickerMode) -> Int {
        // Mirrors the grids' adaptive GridItems inside 20 pt padding.
        let (tile, spacing): (CGFloat, CGFloat) = mode == .windows ? (200, 16) : (appTileWidth, 8)
        return max(1, Int((width - 40 + spacing) / (tile + spacing)))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await connection.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh the window list")
            FullDesktopButton(connection: connection)
            if model.pairedHost(for: target) != nil {
                Button { showsVideoQuality.toggle() } label: {
                    Label("Video Quality", systemImage: "gauge.with.dots.needle.67percent")
                }
                .help("How much video this Mac may send")
                .popover(isPresented: $showsVideoQuality, arrowEdge: .bottom) {
                    VideoQualityView(target: target, model: model)
                }
            }
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

    @ViewBuilder
    private func appsEmptyState(isEmpty: Bool) -> some View {
        if connection.applications == nil {
            ProgressView()
        } else if isEmpty, !query.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text(mode == .windows ? "↩ or double-click opens"
                                  : "↩ or double-click opens the app there")
            Spacer()
            Text("⌃⌥⌘W closes on this Mac only · ⌃⌥⌘0 comes back here")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func move(_ offset: Int, in flat: [WindowSummary], shelves: [AppShelf]) {
        if mode == .apps {
            appSelection = AppShelf.move(from: appSelection, by: offset, columns: columns, in: shelves) ?? appSelection
            return
        }
        guard !flat.isEmpty else { return }
        let current = flat.firstIndex { $0.windowID == selection } ?? (offset > 0 ? -1 : flat.count)
        selection = flat[min(max(current + offset, 0), flat.count - 1)].windowID
        userSelected = true
    }

    private func openSelected(in flat: [WindowSummary], apps: [HostApplication]) {
        if mode == .apps {
            if let app = apps.first(where: { $0.path == appSelection }) ?? apps.first { launch(app) }
            return
        }
        if let window = flat.first(where: { $0.windowID == selection }) ?? flat.first { open(window) }
    }

    private func appTile(_ app: HostApplication) -> some View {
        AppTile(application: app, icon: connection.applicationIcons[app.path],
                isSelected: appSelection == app.path, isLaunching: launching == app.path)
            .id(app.path)
            .onAppear { connection.needIcon(forApplicationAt: app.path) }
            .onTapGesture(count: 2) { launch(app) }
            .simultaneousGesture(TapGesture().onEnded { appSelection = app.path; gridFocused = true })
            .contextMenu {
                Button(app.isRunning ? "Show" : "Open") { launch(app) }
                if app.isRunning {
                    Divider()
                    Button("Quit") { connection.quit(app, force: false) }
                    Button("Force Quit") { connection.quit(app, force: true) }
                }
            }
    }

    private func open(_ window: WindowSummary) {
        model.open(window, on: connection, keepPicker: NSEvent.modifierFlags.contains(.option))
    }

    private func launch(_ app: HostApplication) {
        launching = app.path
        model.launch(app, on: connection, keepPicker: NSEvent.modifierFlags.contains(.option))
        Task {
            try? await Task.sleep(for: .seconds(8))
            if launching == app.path { launching = nil }
        }
    }
}

private struct AppTile: View {
    let application: HostApplication
    let icon: Data?
    let isSelected: Bool
    let isLaunching: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if let icon, let image = NSImage(data: icon) {
                    Image(nsImage: image).resizable().frame(width: 56, height: 56)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 40)).frame(width: 56, height: 56)
                        .foregroundStyle(.tertiary)
                }
                if isLaunching {
                    ProgressView().controlSize(.small)
                }
            }
            Text(application.name)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Circle()
                .fill(application.isRunning ? Color.secondary : .clear)
                .frame(width: 4, height: 4)
                .help(application.isRunning ? "Running" : "")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(width: 112)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .help(application.path)
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
                if let icon = group.bundleIdentifier.flatMap({ connection.windowIcons[$0] }).flatMap(NSImage.init(data:)) {
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
                    WindowCard(window: window, thumbnail: connection.thumbnails[window.windowID],
                               isSelected: selection == window.windowID,
                               isOpen: connection.openWindowIDs.contains(window.windowID))
                        .id(window.windowID)
                        .onTapGesture(count: 2) { open(window) }
                        .simultaneousGesture(TapGesture().onEnded { select(window.windowID) })
                        .contextMenu {
                            if connection.openWindowIDs.contains(window.windowID) {
                                Button("Switch to This Window") { open(window) }
                                Button("Close on This Mac") { connection.closeMirror(windowID: window.windowID) }
                            } else {
                                Button("Open") { open(window) }
                            }
                        }
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
            Text("Use this when the Mac isn’t on the same network or doesn’t show up under “Nearby”. Find the pairing code on that Mac under the AnyRemote menu bar icon › ⋯ › Show Pairing Code.")
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

private struct AddressSheet: View {
    let target: HostTarget
    let model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Address of “\(target.name)”").font(.headline)
            Text("Where this Mac connects to it. Change it when that Mac is on another subnet or got a new IP address; the default port is 47800.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Address", text: $address, prompt: Text("192.168.1.20 or mac-mini.local"))
                .frame(width: 340).onSubmit(save)
            if let error = model.lastError {
                Text(FriendlyText.message(error)).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            model.lastError = nil
            address = model.pairedHost(for: target)?.address ?? ""
        }
    }

    private func save() {
        if model.setAddress(target, to: address) { dismiss() }
    }
}

/// Opens the host's whole desktop in an AnyRemote window. With several
/// displays, it opens the main one; its menu picks another.
struct FullDesktopButton: View {
    let connection: HostConnection

    var body: some View {
        let displays = connection.displays
        if displays.count > 1 {
            Menu {
                ForEach(displays, id: \.displayID) { display in
                    Button(Self.title(display)) { connection.openDesktop(displayID: display.displayID) }
                }
            } label: {
                Label("Full Desktop", systemImage: "display.2")
            } primaryAction: {
                connection.openDesktop()
            }
            .help("Show the whole desktop of this Mac; choose a display from the menu")
        } else {
            Button { connection.openDesktop() } label: { Label("Full Desktop", systemImage: "display") }
                .help("Show the whole desktop of this Mac")
                .disabled(connection.state != .connected)
        }
    }

    private static func title(_ display: DisplaySummary) -> String {
        let name = display.name ?? String(localized: "Display")
        let size = "\(Int(display.frame.width))×\(Int(display.frame.height))"
        return display.isMain == true ? String(localized: "\(name) (\(size), main)") : "\(name) (\(size))"
    }
}
