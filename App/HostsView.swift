import AnyRemoteClient
import AnyRemoteWire
import AppKit
import Combine
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

/// One part of the Apps grid: the row of recent apps, then every app by name.
/// An app can be in both, so a tile is named by its shelf and path (`key`).
struct AppShelf: Identifiable {
    var id: String
    var apps: [HostApplication]

    func key(_ app: HostApplication) -> String { id + "\u{1F}" + app.path }
    var keys: [String] { apps.map(key) }

    static func path(ofKey key: String) -> String {
        String(key.split(separator: "\u{1F}", maxSplits: 1).last ?? "")
    }

    /// The tile an arrow key moves the selection to. `offset` is ±1 for
    /// left/right and ±`columns` for up/down; up and down stay in the same
    /// column and cross into the neighbouring shelf, whose rows start afresh.
    static func move(from selected: String?, by offset: Int, columns: Int, in shelves: [[String]]) -> String? {
        let shelves = shelves.filter { !$0.isEmpty }
        guard !shelves.isEmpty else { return nil }
        let columns = max(1, columns)
        guard let selected,
              let s = shelves.firstIndex(where: { $0.contains(selected) }),
              let i = shelves[s].firstIndex(of: selected) else {
            return offset > 0 ? shelves.first?.first : shelves.last?.last
        }
        if abs(offset) < columns || columns == 1 {
            let flat = shelves.flatMap { $0 }
            let position = flat.firstIndex(of: selected) ?? 0
            return flat[min(max(position + offset.signum(), 0), flat.count - 1)]
        }
        let shelf = shelves[s]
        let column = i % columns
        if offset > 0 {
            if i + columns < shelf.count { return shelf[i + columns] }
            // The last row may be short: land on its last tile before leaving the shelf.
            if i / columns < (shelf.count - 1) / columns { return shelf[shelf.count - 1] }
            guard s + 1 < shelves.count else { return selected }
            let next = shelves[s + 1]
            return next[min(column, next.count - 1)]
        } else {
            if i >= columns { return shelf[i - columns] }
            guard s > 0 else { return selected }
            let previous = shelves[s - 1]
            let lastRow = (previous.count - 1) / columns * columns
            return previous[min(lastRow + column, previous.count - 1)]
        }
    }
}

private enum PickerMode: String {
    case windows, apps
}

/// How the Windows list is laid out: grouped under each app, or all at once
/// at their own shapes, as Mission Control shows them.
private enum WindowLayout: String {
    case byApp, all
}

private struct WindowPicker: View {
    let connection: HostConnection
    let model: ViewerModel
    let target: HostTarget
    /// What is shown, and how. Kept in @State and only saved to the
    /// defaults below: a change that comes back through @AppStorage arrives
    /// from UserDefaults' notification and loses the click's animation, so
    /// the lists would swap without moving.
    @State private var mode: PickerMode
    @State private var windowLayout: WindowLayout
    @AppStorage("pickerMode") private var savedMode = PickerMode.windows
    @AppStorage("windowLayout") private var savedWindowLayout = WindowLayout.byApp
    /// Lets a window's thumbnail move from one layout to the other.
    @Namespace private var thumbnails
    @State private var query = ""
    @State private var selection: UInt32?
    /// The selected app tile, by `AppShelf.key`.
    @State private var appSelection: String?
    @State private var category: AppCategory?
    /// The recent apps' order as it was when the picker was last shown.
    /// Opening an app moves it to the front of `RecentApplications` at once,
    /// but the row keeps this order until the picker is hidden, so the tile
    /// under the pointer never changes between the clicks of a double-click.
    @State private var recentOrder: [String] = []
    @State private var launching: String?
    /// Until the user picks a window, the selection follows the first match.
    @State private var userSelected = false
    @State private var columns = 3
    /// The grids' width inside their padding, for arrow keys in the All Windows layout.
    @State private var gridWidth: CGFloat = 0
    @State private var showsVideoQuality = false
    @FocusState private var gridFocused: Bool

    init(connection: HostConnection, model: ViewerModel, target: HostTarget) {
        self.connection = connection
        self.model = model
        self.target = target
        let defaults = UserDefaults.standard
        _mode = State(initialValue: defaults.string(forKey: "pickerMode").flatMap(PickerMode.init) ?? .windows)
        _windowLayout = State(initialValue: defaults.string(forKey: "windowLayout").flatMap(WindowLayout.init) ?? .byApp)
    }

    /// Windows matching the search, grouped by app in the host's front-to-back order.
    private var groups: [AppGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var groups: [AppGroup] = []
        var index: [String: Int] = [:]
        for window in connection.listing?.windows ?? [] {
            if !SearchMatch.matches(window.title, needle), !SearchMatch.matches(window.applicationName, needle) { continue }
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

    /// The groups the host's apps fall into, in the chips' order.
    private var categories: [AppCategory] {
        let present = Set(connection.offeredApplications.compactMap(AppCategory.init))
        return AppCategory.allCases.filter(present.contains)
    }

    /// Like the Mac's own Apps view: one row of the apps opened from here
    /// lately, then every app by name. A search or a chosen group shows just
    /// the matching apps by name.
    private var appShelves: [AppShelf] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var apps = connection.offeredApplications
        if let category { apps = apps.filter { AppCategory($0) == category } }
        if !needle.isEmpty { apps = apps.filter { SearchMatch.matches($0.name, needle) } }
        var shelves = [AppShelf(id: "all", apps: apps)]
        if needle.isEmpty, category == nil {
            let byPath = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            shelves.insert(AppShelf(id: "recent", apps: Array(recentOrder.compactMap { byPath[$0] }.prefix(columns))), at: 0)
        }
        return shelves.filter { !$0.apps.isEmpty }
    }

    var body: some View {
        let groups = groups
        let flat = groups.flatMap(\.windows)
        let shelves = mode == .apps ? appShelves : []
        let apps = shelves.flatMap(\.apps)
        let appKeys = shelves.flatMap(\.keys)
        VStack(spacing: 0) {
            banners
            Picker("Show", selection: $mode.animation(.smooth(duration: 0.3))) {
                Text("Windows").tag(PickerMode.windows)
                Text("Apps").tag(PickerMode.apps)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Windows open on that Mac, or apps to open there")
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if mode == .windows {
                    Picker("Layout", selection: $windowLayout.animation(.smooth(duration: 0.4))) {
                        Label("By App", systemImage: "square.grid.2x2").tag(WindowLayout.byApp)
                        Label("All Windows", systemImage: "rectangle.3.group").tag(WindowLayout.all)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .labelsHidden()
                    .fixedSize()
                    .help("Group windows by app, or show them all at once")
                    .padding(.trailing, 20)
                    .transition(.opacity)
                }
            }
            .padding(.top, 12)
            GeometryReader { proxy in
                // Each list slides in from the side its segment is on.
                ZStack {
                    if mode == .windows {
                        windowsPane(groups, flat: flat)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    } else {
                        appsPane(shelves, isEmpty: apps.isEmpty)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .onAppear {
                    columns = Self.columnCount(width: proxy.size.width, mode: mode)
                    gridWidth = proxy.size.width - 40
                }
                .onChange(of: proxy.size.width) { _, width in
                    columns = Self.columnCount(width: width, mode: mode)
                    gridWidth = width - 40
                }
                .onChange(of: mode) { _, mode in columns = Self.columnCount(width: proxy.size.width, mode: mode) }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(.return) { openSelected(in: flat, apps: apps); return .handled }
            .onKeyPress(.leftArrow) { move(.left, in: flat, shelves: shelves); return .handled }
            .onKeyPress(.rightArrow) { move(.right, in: flat, shelves: shelves); return .handled }
            .onKeyPress(.upArrow) { move(.up, in: flat, shelves: shelves); return .handled }
            .onKeyPress(.downArrow) { move(.down, in: flat, shelves: shelves); return .handled }
            .overlay { if mode == .windows { emptyState(isEmpty: flat.isEmpty) } }
            footer
        }
        .onChange(of: query) {
            userSelected = false
            selection = flat.first?.windowID
            appSelection = appKeys.first
        }
        .onChange(of: appKeys, initial: true) { _, keys in
            if appSelection.map({ !keys.contains($0) }) ?? true { appSelection = keys.first }
        }
        .onChange(of: categories) { _, categories in
            if let category, !categories.contains(category) { self.category = nil }
        }
        .onChange(of: mode) { savedMode = mode }
        .onChange(of: windowLayout) { savedWindowLayout = windowLayout }
        .task(id: mode) {
            if mode == .apps { await connection.loadApplications() }
        }
        .onChange(of: flat.map(\.windowID), initial: true) { _, ids in
            if !userSelected || selection.map({ !ids.contains($0) }) ?? true {
                userSelected = false
                selection = ids.first
            }
        }
        .toolbar {
            toolbar
            ToolbarItem {
                LiveSearchField(text: $query, prompt: String(localized: mode == .windows ? "Search windows" : "Search apps"),
                                onSubmit: { openSelected(in: flat, apps: apps) },
                                onMove: { move($0, in: flat, shelves: shelves) })
                    .frame(minWidth: 140, idealWidth: 220, maxWidth: 260)
            }
        }
        .onAppear {
            refreshRecentOrder()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            // The hosts window is kept when closed, so this view never
            // reappears; take the new order once it's out of sight instead.
            guard let window = note.object as? NSWindow, window.frameAutosaveName == "AnyRemoteHosts",
                  !window.occlusionState.contains(.visible) else { return }
            refreshRecentOrder()
        }
        .task {
            // Thumbnails and the window list stay fresh while the picker is visible.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await connection.refresh()
            }
        }
    }

    private func windowsPane(_ groups: [AppGroup], flat: [WindowSummary]) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                // Each thumbnail is matched across the two layouts, so
                // switching moves every window to its new place.
                Group {
                    if windowLayout == .byApp {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(groups) { group in
                                AppSection(group: group, connection: connection, namespace: thumbnails) { window in
                                    WindowCard(window: window, thumbnail: connection.thumbnails[window.windowID],
                                               isSelected: selection == window.windowID,
                                               isOpen: connection.openWindowIDs.contains(window.windowID),
                                               namespace: thumbnails)
                                        .modifier(windowActions(window))
                                        .tiltOnHover()
                                }
                            }
                        }
                    } else {
                        MasonryLayout(aspects: flat.map(Self.aspect), columns: columns, spacing: Self.masonrySpacing,
                                      captionHeight: WindowTile.captionHeight) {
                            ForEach(flat, id: \.windowID) { window in
                                WindowTile(window: window, thumbnail: connection.thumbnails[window.windowID],
                                           icon: window.bundleIdentifier.flatMap { connection.windowIcons[$0] },
                                           isSelected: selection == window.windowID,
                                           isOpen: connection.openWindowIDs.contains(window.windowID),
                                           namespace: thumbnails)
                                    .modifier(windowActions(window))
                                    .tiltOnHover()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: selection) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) } }
            }
        }
    }

    private func appsPane(_ shelves: [AppShelf], isEmpty: Bool) -> some View {
        VStack(spacing: 0) {
            if !categories.isEmpty {
                CategoryChips(categories: categories, selection: $category)
                    .padding(.top, 12)
            }
            ScrollViewReader { scroller in
                ScrollView {
                    // Not lazy: scrollTo can only reach tiles of shelves that have been laid out.
                    VStack(spacing: 0) {
                        ForEach(Array(shelves.enumerated()), id: \.element.id) { index, shelf in
                            if index > 0 { Divider().padding(.vertical, 14) }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.appSpacing, alignment: .top),
                                                     count: columns),
                                      spacing: 14) {
                                ForEach(shelf.apps, id: \.path) { app in appTile(app, key: shelf.key(app)) }
                            }
                        }
                    }
                    // Full width even when nothing matches; an empty grid
                    // would otherwise shrink the scroll view (and the
                    // no-results message over it) to nothing.
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: appSelection) { _, key in
                    if let key { withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(key) } }
                }
            }
            .overlay { appsEmptyState(isEmpty: isEmpty) }
        }
    }

    private static let appTileWidth: CGFloat = 96
    private static let masonrySpacing: CGFloat = 16

    private static func aspect(_ window: WindowSummary) -> CGFloat {
        window.frame.height > 0 ? window.frame.width / window.frame.height : 1
    }

    private func windowActions(_ window: WindowSummary) -> WindowCardActions {
        WindowCardActions(window: window, connection: connection,
                          select: { selection = window.windowID; userSelected = true; gridFocused = true },
                          open: { open(window) })
    }
    private static let appSpacing: CGFloat = 8

    private static func columnCount(width: CGFloat, mode: PickerMode) -> Int {
        // Mirrors the grids inside their 20 pt side padding.
        let (tile, spacing): (CGFloat, CGFloat) = mode == .windows ? (200, 16) : (appTileWidth, appSpacing)
        return max(1, Int((width - 40 + spacing) / (tile + spacing)))
    }

    private func refreshRecentOrder() {
        recentOrder = RecentApplications.paths(host: connection.welcome?.hostID ?? "")
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

    private func move(_ direction: MasonryPlacement.Direction, in flat: [WindowSummary], shelves: [AppShelf]) {
        let offset = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columns
        case .down: columns
        }
        if mode == .apps {
            appSelection = AppShelf.move(from: appSelection, by: offset, columns: columns, in: shelves.map(\.keys))
                ?? appSelection
            return
        }
        guard !flat.isEmpty else { return }
        if windowLayout == .all {
            let placement = MasonryPlacement(aspects: flat.map(Self.aspect), columns: columns, width: gridWidth,
                                             spacing: Self.masonrySpacing, captionHeight: WindowTile.captionHeight)
            if let current = flat.firstIndex(where: { $0.windowID == selection }) {
                if let next = placement.neighbour(of: current, direction) { selection = flat[next].windowID }
            } else {
                selection = flat.first?.windowID
            }
            userSelected = true
            return
        }
        let current = flat.firstIndex { $0.windowID == selection } ?? (offset > 0 ? -1 : flat.count)
        selection = flat[min(max(current + offset, 0), flat.count - 1)].windowID
        userSelected = true
    }

    private func openSelected(in flat: [WindowSummary], apps: [HostApplication]) {
        if mode == .apps {
            let path = appSelection.map(AppShelf.path(ofKey:))
            if let app = apps.first(where: { $0.path == path }) ?? apps.first { launch(app) }
            return
        }
        if let window = flat.first(where: { $0.windowID == selection }) ?? flat.first { open(window) }
    }

    private func appTile(_ app: HostApplication, key: String) -> some View {
        AppTile(application: app, icon: connection.applicationIcons[app.path],
                isSelected: appSelection == key, isLaunching: launching == app.path)
            .tiltOnHover(tilts: false)
            .id(key)
            .onAppear { connection.needIcon(forApplicationAt: app.path) }
            .onTapGesture(count: 2) { launch(app) }
            .simultaneousGesture(TapGesture().onEnded { appSelection = key; gridFocused = true })
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

/// The row of group chips above the Apps grid; choosing the chosen one again
/// shows every app.
private struct CategoryChips: View {
    let categories: [AppCategory]
    @Binding var selection: AppCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { category in
                    let isSelected = selection == category
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { selection = isSelected ? nil : category }
                    } label: {
                        Text(category.title)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.7)),
                                        in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// An app as the Mac's Apps view shows it: a large icon with its name below,
/// and a dot under the icon while it's running, as in the Dock.
private struct AppTile: View {
    let application: HostApplication
    let icon: Data?
    let isSelected: Bool
    let isLaunching: Bool

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let icon, let image = NSImage(data: icon) {
                    Image(nsImage: image).resizable()
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 46)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 64, height: 64)
            .pressBounce()
            .opacity(isLaunching ? 0.5 : 1)
            .overlay { if isLaunching { ProgressView().controlSize(.small) } }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3))
            Circle()
                .fill(application.isRunning ? Color.secondary : .clear)
                .frame(width: 4, height: 4)
            Text(application.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(application.isRunning ? String(localized: "\(application.name) — Running") : application.name)
    }
}

private struct AppSection<Card: View>: View {
    let group: AppGroup
    let connection: HostConnection
    let namespace: Namespace.ID
    @ViewBuilder let card: (WindowSummary) -> Card

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
                ForEach(group.windows, id: \.windowID, content: card)
            }
        }
    }
}

/// What a window's card does in either layout: a click selects it, a
/// double-click opens it, and its menu opens or closes it here.
private struct WindowCardActions: ViewModifier {
    let window: WindowSummary
    let connection: HostConnection
    let select: () -> Void
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .id(window.windowID)
            .onTapGesture(count: 2, perform: open)
            .simultaneousGesture(TapGesture().onEnded(select))
            .contextMenu {
                if connection.openWindowIDs.contains(window.windowID) {
                    Button("Switch to This Window", action: open)
                    Button("Close on This Mac") { connection.closeMirror(windowID: window.windowID) }
                } else {
                    Button("Open", action: open)
                }
            }
    }
}

private struct OpenedBadge: View {
    var body: some View {
        Text("Opened")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.tint, in: Capsule())
            .foregroundStyle(.white)
            .padding(8)
    }
}

private struct WindowCard: View {
    let window: WindowSummary
    let thumbnail: Data?
    let isSelected: Bool
    let isOpen: Bool
    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6))
                if let thumbnail, let image = NSImage(data: thumbnail) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .matchedGeometryEffect(id: window.windowID, in: namespace)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if isOpen { OpenedBadge() }
            }
            .frame(height: 140)
            .tiltGlare(cornerRadius: 10)
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

/// A window in the All Windows layout: its thumbnail at the window's own
/// shape, and the app's icon with the window's title below, as in Mission Control.
private struct WindowTile: View {
    let window: WindowSummary
    let thumbnail: Data?
    let icon: Data?
    let isSelected: Bool
    let isOpen: Bool
    let namespace: Namespace.ID

    static let captionHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let thumbnail, let image = NSImage(data: thumbnail) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .tiltGlare(cornerRadius: 8)
                        .matchedGeometryEffect(id: window.windowID, in: namespace)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6))
                }
                if isOpen { OpenedBadge() }
            }
            .padding(5)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3))
            HStack(spacing: 5) {
                if let icon, let image = NSImage(data: icon) {
                    Image(nsImage: image).resizable().frame(width: 16, height: 16)
                }
                Text(window.title.isEmpty ? window.applicationName : window.title)
                    .lineLimit(1)
                    .fontWeight(isSelected ? .medium : .regular)
            }
            .font(.callout)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: Self.captionHeight)
        }
        .contentShape(Rectangle())
        .help(window.title.isEmpty ? window.applicationName : "\(window.applicationName) — \(window.title)")
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
