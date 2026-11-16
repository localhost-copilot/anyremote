import AnyRemoteHost
import AnyRemoteWire
import AppKit
import SwiftUI

/// What the panel shows across openings, and how it reaches the rest of the app.
@MainActor
@Observable
final class StatusPanelModel {
    let viewer: ViewerModel
    let host: HostSettingsModel
    var query = ""
    /// The highlighted result, for the arrow keys and Return.
    var highlighted = 0
    /// The app being opened, until its window arrives or a few seconds pass.
    var launching: String?
    /// Bumped on every opening so the view resets and refreshes.
    private(set) var presentation = 0
    @ObservationIgnored var actions = Actions()

    struct Actions {
        var dismiss: () -> Void = {}
        var showPicker: () -> Void = {}
        var showSettings: () -> Void = {}
        /// The content's size changed; the panel follows, keeping its top edge.
        var resize: (CGSize) -> Void = { _ in }
    }

    /// The Mac the panel works on, by host ID so it survives the Mac going
    /// offline and coming back under another target.
    @ObservationIgnored private var storedHostID: String? {
        get { UserDefaults.standard.string(forKey: "statusPanelHost") }
        set { UserDefaults.standard.set(newValue, forKey: "statusPanelHost") }
    }
    private(set) var chosenHostID: String?

    init(viewer: ViewerModel, host: HostSettingsModel) {
        self.viewer = viewer
        self.host = host
        chosenHostID = UserDefaults.standard.string(forKey: "statusPanelHost")
    }

    func willShow() {
        query = ""
        highlighted = 0
        launching = nil
        presentation += 1
    }

    /// The chosen Mac while it's still paired, else the one the picker would pick.
    var target: HostTarget? {
        let macs = viewer.myMacs
        if let chosenHostID, let chosen = macs.first(where: { Self.hostID($0) == chosenHostID }) { return chosen }
        return viewer.preferredTargetID.flatMap(viewer.target(id:))
    }

    func choose(_ target: HostTarget) {
        chosenHostID = Self.hostID(target)
        storedHostID = chosenHostID
        query = ""
        highlighted = 0
    }

    static func hostID(_ target: HostTarget) -> String { target.savedID ?? target.hostID ?? target.id }

    func showPicker(for target: HostTarget?) {
        if let target { viewer.selection = target.id }
        actions.dismiss()
        actions.showPicker()
    }
}

/// One row of the panel's list: an app to open, or a window open over there.
enum PanelResult: Identifiable {
    case app(HostApplication)
    case window(WindowSummary)

    var id: String {
        switch self {
        case .app(let app): "app:" + app.path
        case .window(let window): "window:\(window.windowID)"
        }
    }
}

/// The menu bar panel. It exists for the moments between remote windows: open
/// an app on another Mac without going through the picker window, find a
/// window that's already open here, and see at a glance whether someone is
/// controlling this Mac. So the search field has focus the moment it opens,
/// the apps used last are listed before anything is typed, and Return opens
/// the top result.
struct StatusPanelView: View {
    @Bindable var model: StatusPanelModel
    @FocusState private var searchFocused: Bool

    private var viewer: ViewerModel { model.viewer }

    var body: some View {
        let target = model.target
        let connection = target.flatMap(viewer.connection(for:))
        VStack(spacing: 0) {
            header(target: target, connection: connection)
            Divider()
            Group {
                if let target {
                    if let connection, connection.state == .connected {
                        ResultsList(model: model, connection: connection, results: results(connection),
                                    hostID: connection.welcome?.hostID ?? StatusPanelModel.hostID(target))
                    } else {
                        ConnectionStateView(model: model, target: target, connection: connection)
                    }
                } else {
                    PanelMessage(symbol: "macmini", title: String(localized: "No Macs Yet"),
                                 detail: String(localized: "Open AnyRemote on another Mac and pair with it to open its apps from here.")) {
                        Button("Pair a Mac…") { model.showPicker(for: nil) }
                    }
                }
            }
            .frame(height: 300)
            // Mirrors aren't observable; the open window and display IDs are, and change with them.
            OpenHereSection(viewer: viewer, presentation: model.presentation,
                            openCount: viewer.connections.values.reduce(0) { $0 + $1.openWindowIDs.count + $1.openDisplayIDs.count })
            Divider()
            SharingFooter(model: model)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: \.size) { model.actions.resize($0) }
        // Typing may start while the Mac is still connecting; the results follow once it's there.
        .onChange(of: model.presentation, initial: true) {
            searchFocused = true
        }
        .task(id: "\(model.presentation)|\(target?.id ?? "")") {
            await prepare(target)
        }
        .onExitCommand { model.actions.dismiss() }
    }

    // MARK: Header

    @ViewBuilder
    private func header(target: HostTarget?, connection: HostConnection?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MacTabs(model: model, target: target)
            HStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(searchPrompt(target), text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($searchFocused)
                        .onSubmit { openHighlighted() }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onChange(of: model.query) { model.highlighted = 0 }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                if let connection, connection.state == .connected {
                    PanelIconButton(symbol: "display", help: String(localized: "Show the whole desktop of this Mac")) {
                        model.actions.dismiss()
                        connection.openDesktop()
                    }
                    PanelIconButton(symbol: "rectangle.3.group", help: String(localized: "All windows and apps, with previews")) {
                        model.showPicker(for: target)
                    }
                }
            }
        }
        .padding(10)
    }

    private func searchPrompt(_ target: HostTarget?) -> String {
        guard let target else { return String(localized: "Search apps") }
        return String(localized: "Open an app on “\(target.name)”")
    }

    // MARK: Results

    /// With no search: recent apps, then running ones. With a search: apps
    /// whose name matches (names starting with it first), then windows.
    private func results(_ connection: HostConnection) -> [(title: String, items: [PanelResult])] {
        let apps = connection.offeredApplications
        let host = connection.welcome?.hostID ?? ""
        let recent = RecentApplications.applications(host: host, in: apps)
        let needle = model.query.trimmingCharacters(in: .whitespaces)
        if needle.isEmpty {
            let recentPaths = Set(recent.map(\.path))
            let running = apps.filter { $0.isRunning && !recentPaths.contains($0.path) }
            return [(String(localized: "Recent"), recent.prefix(5).map(PanelResult.app)),
                    (String(localized: "Running"), running.map(PanelResult.app))]
                .filter { !$0.items.isEmpty }
        }
        let recentRank = Dictionary(recent.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        func rank(_ app: HostApplication) -> (Int, Int, Int, String) {
            let prefix = app.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            return (prefix ? 0 : 1, recentRank[app.path] ?? Int.max, app.isRunning ? 0 : 1, app.name.lowercased())
        }
        let matchingApps = apps.filter { $0.name.localizedStandardContains(needle) }
            .sorted { rank($0) < rank($1) }
        let windows = (connection.listing?.windows ?? []).filter {
            $0.title.localizedStandardContains(needle) || $0.applicationName.localizedStandardContains(needle)
        }
        return [(String(localized: "Apps"), matchingApps.prefix(8).map(PanelResult.app)),
                (String(localized: "Windows"), windows.prefix(6).map(PanelResult.window))]
            .filter { !$0.items.isEmpty }
    }

    private var flatResults: [PanelResult] {
        guard let target = model.target, let connection = viewer.connection(for: target),
              connection.state == .connected else { return [] }
        return results(connection).flatMap(\.items)
    }

    private func move(_ offset: Int) {
        let count = flatResults.count
        guard count > 0 else { return }
        model.highlighted = min(max(model.highlighted + offset, 0), count - 1)
    }

    private func openHighlighted() {
        let results = flatResults
        guard let target = model.target, let connection = viewer.connection(for: target),
              results.indices.contains(model.highlighted) else { return }
        ResultsList.open(results[model.highlighted], model: model, connection: connection)
    }

    /// Connects to the Mac when needed and brings its app and window lists up to date.
    private func prepare(_ target: HostTarget?) async {
        guard let target else { return }
        if viewer.connection(for: target) == nil, viewer.code(for: target) != nil, target.kind != .offline {
            await viewer.connect(target)
        }
        guard let connection = viewer.connection(for: target), connection.state == .connected else { return }
        await connection.loadApplications()
        await connection.refresh()
    }
}

// MARK: - Mac switcher

/// Every paired Mac as a tab, so with several the choice is one click (or
/// ⌘1…⌘9) and their states are visible at once. The panel remembers the
/// last one; each Mac keeps its own recent apps.
private struct MacTabs: View {
    let model: StatusPanelModel
    let target: HostTarget?

    var body: some View {
        let macs = model.viewer.myMacs
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(macs.enumerated()), id: \.element.id) { index, mac in
                    MacTab(mac: mac, model: model, isSelected: mac.id == target?.id, number: index + 1)
                }
                Button { model.showPicker(for: nil) } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Pair a Mac…")
            }
        }
    }
}

private struct MacTab: View {
    let mac: HostTarget
    let model: StatusPanelModel
    let isSelected: Bool
    let number: Int
    @State private var hovering = false

    var body: some View {
        Button { model.choose(mac) } label: {
            HStack(spacing: 5) {
                StatusDot(color: PanelHostStatus(model: model.viewer, target: mac).color)
                Text(verbatim: mac.name).lineLimit(1).truncationMode(.middle)
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .frame(maxWidth: 150)
            .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.22)
                                      : hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .modifier(NumberShortcut(number: number))
        .help(Text(verbatim: number <= 9 ? "⌘\(number)" : ""))
    }
}

/// ⌘1…⌘9 for the first nine Macs.
private struct NumberShortcut: ViewModifier {
    let number: Int

    func body(content: Content) -> some View {
        if number <= 9 {
            content.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
        } else {
            content
        }
    }
}

/// The connection state of a Mac as a color, matching the picker's sidebar.
@MainActor
private struct PanelHostStatus {
    let model: ViewerModel
    let target: HostTarget

    var color: Color {
        switch model.connection(for: target)?.state {
        case .connected?: .green
        case .connecting?: .orange
        case .failed?: .red
        case .disconnected?, nil: target.kind == .offline ? .gray.opacity(0.5) : .gray
        }
    }
}

private struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

// MARK: - Results list

private struct ResultsList: View {
    let model: StatusPanelModel
    let connection: HostConnection
    let results: [(title: String, items: [PanelResult])]
    let hostID: String

    var body: some View {
        if connection.applications == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            if model.query.isEmpty {
                PanelMessage(symbol: "app.dashed", title: String(localized: "Nothing Open Yet"),
                             detail: String(localized: "Type the name of an app on “\(connection.hostName)” to open it here.")) {}
            } else {
                PanelMessage(symbol: "magnifyingglass", title: String(localized: "No Results"),
                             detail: String(localized: "No app or window on “\(connection.hostName)” matches “\(model.query)”.")) {}
            }
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        let offsets = sectionOffsets
                        ForEach(Array(results.enumerated()), id: \.offset) { section, entry in
                            Text(entry.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, section == 0 ? 4 : 10)
                                .padding(.bottom, 2)
                            ForEach(Array(entry.items.enumerated()), id: \.element.id) { index, item in
                                let position = offsets[section] + index
                                ResultRow(item: item, connection: connection,
                                          isHighlighted: position == model.highlighted,
                                          isLaunching: { if case .app(let app) = item { app.path == model.launching } else { false } }())
                                    .id(position)
                                    .onTapGesture { Self.open(item, model: model, connection: connection) }
                                    .onHover { if $0 { model.highlighted = position } }
                                    .contextMenu { contextMenu(item) }
                            }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.highlighted) { _, position in scroller.scrollTo(position) }
            }
        }
    }

    private var sectionOffsets: [Int] {
        var offsets: [Int] = []
        var total = 0
        for entry in results {
            offsets.append(total)
            total += entry.items.count
        }
        return offsets
    }

    @ViewBuilder
    private func contextMenu(_ item: PanelResult) -> some View {
        switch item {
        case .app(let app):
            Button(app.isRunning ? "Show" : "Open") { Self.open(item, model: model, connection: connection) }
            if app.isRunning {
                Divider()
                Button("Quit") { connection.quit(app, force: false) }
                Button("Force Quit") { connection.quit(app, force: true) }
            }
        case .window:
            Button("Open") { Self.open(item, model: model, connection: connection) }
        }
    }

    /// Opens an app or window. A window that's already listed opens at once,
    /// so the panel goes; an app may take a while to show a window, so the
    /// panel stays with a spinner until the window takes focus away from it.
    static func open(_ item: PanelResult, model: StatusPanelModel, connection: HostConnection) {
        switch item {
        case .window(let window):
            model.actions.dismiss()
            model.viewer.open(window, on: connection, keepPicker: true)
        case .app(let app):
            model.launching = app.path
            model.viewer.launch(app, on: connection, keepPicker: true)
            Task {
                try? await Task.sleep(for: .seconds(8))
                if model.launching == app.path { model.launching = nil }
            }
        }
    }
}

private struct ResultRow: View {
    let item: PanelResult
    let connection: HostConnection
    let isHighlighted: Bool
    let isLaunching: Bool

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).lineLimit(1).foregroundStyle(isHighlighted ? .white : .primary)
                if let subtitle {
                    Text(subtitle).font(.caption).lineLimit(1)
                        .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
                }
            }
            Spacer(minLength: 4)
            if isLaunching {
                ProgressView().controlSize(.small)
            } else if isOpenHere {
                Text("Open Here").font(.caption2.weight(.medium))
                    .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
            } else if case .app(let app) = item, app.isRunning {
                Circle().fill(isHighlighted ? Color.white.opacity(0.8) : .secondary).frame(width: 4, height: 4)
                    .help("Running")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: subtitle == nil ? 30 : 36)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    private var title: String {
        switch item {
        case .app(let app): app.name
        case .window(let window): window.title.isEmpty ? window.applicationName : window.title
        }
    }

    private var subtitle: String? {
        switch item {
        case .app: nil
        case .window(let window): window.title.isEmpty ? nil : window.applicationName
        }
    }

    private var isOpenHere: Bool {
        if case .window(let window) = item { return connection.openWindowIDs.contains(window.windowID) }
        return false
    }

    @ViewBuilder
    private var icon: some View {
        let data: Data? = switch item {
        case .app(let app): connection.applications?.icons[app.path]
        case .window(let window): window.bundleIdentifier.flatMap { connection.listing?.icons[$0] }
        }
        if let data, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: { if case .window = item { "macwindow" } else { "app.dashed" } }())
                .font(.title3).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Not connected

/// What stands between the user and the Mac's apps, and the one thing to do about it.
private struct ConnectionStateView: View {
    let model: StatusPanelModel
    let target: HostTarget
    let connection: HostConnection?

    var body: some View {
        let failure: String? = if case .failed(let message)? = connection?.state { message } else { nil }
        if connection?.state == .connecting {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Connecting to “\(target.name)”…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.viewer.code(for: target) == nil || failure.map(FriendlyText.isPairingFailure) == true {
            PanelMessage(symbol: "lock.shield", title: String(localized: "Pair with “\(target.name)”"),
                         detail: String(localized: "Enter that Mac’s pairing code once, in the AnyRemote window.")) {
                Button("Pair…") { model.showPicker(for: target) }
            }
        } else if let failure, FriendlyText.isBusy(failure) {
            PanelMessage(symbol: "person.2.fill", title: FriendlyText.message(failure),
                         detail: String(localized: "Taking over disconnects the other one.")) {
                Button("Take Over") { Task { await model.viewer.connect(target, takeOver: true) } }
            }
        } else if let failure {
            PanelMessage(symbol: "exclamationmark.triangle", title: String(localized: "Can’t connect to “\(target.name)”"),
                         detail: FriendlyText.message(failure)) {
                Button("Try Again") { Task { await model.viewer.connect(target) } }
            }
        } else if target.kind == .offline {
            PanelMessage(symbol: "moon.zzz", title: String(localized: "“\(target.name)” is offline"),
                         detail: String(localized: "It appears automatically once it’s on and running AnyRemote.")) {
                Button("Try Anyway") { Task { await model.viewer.connect(target) } }
            }
        } else {
            PanelMessage(symbol: "macmini", title: target.name, detail: String(localized: "Disconnected.")) {
                Button("Connect") { Task { await model.viewer.connect(target) } }
            }
        }
    }
}

private struct PanelMessage<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(verbatim: title).font(.headline).multilineTextAlignment(.center)
            Text(verbatim: detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions.padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Open here

/// Remote windows open on this Mac, from every Mac, so one that went behind
/// other windows is one click away.
private struct OpenHereSection: View {
    let viewer: ViewerModel
    /// Together these change whenever the open windows may have.
    let presentation: Int
    let openCount: Int

    var body: some View {
        let windows = ((viewer.allDesktops as [NSWindowController]) + viewer.allMirrors)
            .sorted { ($0.window?.title ?? "") < ($1.window?.title ?? "") }
        if !windows.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 1) {
                Text("Open on This Mac")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(windows, id: \.self) { OpenHereRow(controller: $0) }
                    }
                }
                .frame(maxHeight: 4 * 28)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }
}

private struct OpenHereRow: View {
    let controller: NSWindowController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: controller is DesktopWindowController ? "display" : "macwindow")
                .foregroundStyle(.secondary).frame(width: 22)
            Text(controller.window?.title ?? String(localized: "Window")).lineLimit(1)
            Spacer(minLength: 4)
            if hovering {
                Button { controller.close() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close on This Mac; the window stays open on the other Mac.")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            NSApp.activate()
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Sharing footer

/// This Mac as a host: whether others can control it, who does right now
/// (with a way to cut them off), and everything else AnyRemote has, behind ⋯.
private struct SharingFooter: View {
    let model: StatusPanelModel

    private var host: HostSettingsModel { model.host }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if host.status.viewers.isEmpty {
                    HStack(spacing: 8) {
                        StatusDot(color: summary.color)
                        Text(verbatim: summary.text).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        if !host.settings.isEnabled {
                            Button("Turn On") { host.setEnabled(true) }.controlSize(.small)
                        } else if !host.permissions.allGranted {
                            Button("Fix…") { model.actions.dismiss(); model.actions.showSettings() }.controlSize(.small)
                        }
                    }
                }
                ForEach(host.status.viewers) { viewer in
                    HStack(spacing: 8) {
                        StatusDot(color: .orange)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: viewer.name).lineLimit(1).truncationMode(.middle)
                            Text("Is controlling this Mac").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("Disconnect") { host.service.disconnectViewer(id: viewer.id) }
                            .controlSize(.small)
                    }
                }
            }
            moreMenu
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: (text: String, color: Color) {
        if !host.settings.isEnabled { return (String(localized: "Others can’t control this Mac"), .gray) }
        if !host.permissions.allGranted { return (String(localized: "Sharing needs permissions"), .yellow) }
        if host.status.isListening { return (String(localized: "Others can control this Mac"), .green) }
        return (String(localized: "Sharing: Starting…"), .orange)
    }

    private var moreMenu: some View {
        Menu {
            if host.settings.isEnabled {
                Button("Copy Pairing Code") { host.copyCode() }
                Button("Show Pairing Code…") { model.actions.dismiss(); model.actions.showSettings() }
                Button("Stop Sharing This Mac") { host.setEnabled(false) }
            } else {
                Button("Allow Other Macs to Control This Mac") { host.setEnabled(true) }
            }
            Divider()
            Button("Open AnyRemote Window") { model.showPicker(for: model.target) }
            Button("Settings…") { model.actions.dismiss(); model.actions.showSettings() }
            if case .ready(let staged) = SoftwareUpdate.shared.state {
                Button("Install AnyRemote \(staged.manifest.version)…") {
                    model.actions.dismiss()
                    Task { await SoftwareUpdate.shared.check(userInitiated: true) }
                }
            } else if SoftwareUpdate.shared.isSupported {
                Button("Check for Updates…") {
                    model.actions.dismiss()
                    Task { await SoftwareUpdate.shared.check(userInitiated: true) }
                }
            }
            Divider()
            Button("Quit AnyRemote") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pairing code, settings and more")
    }
}

private struct PanelIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}
