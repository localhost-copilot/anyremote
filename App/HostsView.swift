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
            Section("我的 Mac") {
                if model.myMacs.isEmpty {
                    Text("还没有配对的 Mac").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(model.myMacs) { target in
                    HostRow(target: target, model: model).tag(target.id)
                        .contextMenu {
                            if model.connection(for: target)?.state == .connected {
                                Button("断开连接") { model.disconnect(target) }
                            }
                            if target.kind != .thisMac {
                                Button("重命名…") { renaming = target }
                                Divider()
                                Button("忘记这台 Mac", role: .destructive) { model.forget(target) }
                            }
                        }
                }
            }
            Section("附近") {
                if model.newNearby.isEmpty {
                    Text("没有发现其他 Mac").foregroundStyle(.secondary).font(.callout)
                        .help("其他 Mac 需要运行 AnyRemote 并在同一网络。没出现的话，检查 系统设置 › 隐私与安全性 › 本地网络 "
                              + "里是否允许了 AnyRemote，或者用下方「按地址添加」。")
                }
                ForEach(model.newNearby) { target in
                    HostRow(target: target, model: model).tag(target.id)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { addingHost = true } label: {
                Label("按地址添加…", systemImage: "plus")
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
            return (count.map { "已连接 · \($0) 个窗口" } ?? "已连接", .green)
        case .connecting?:
            return ("正在连接…", .orange)
        case .failed(let message)?:
            if FriendlyText.isBusy(message) { return ("正被他人控制", .orange) }
            if FriendlyText.isPairingFailure(message) { return ("配对码错误", .red) }
            return ("连接失败", .red)
        case .disconnected?, nil:
            break
        }
        if model.code(for: target) == nil { return ("需要配对", .gray) }
        switch target.kind {
        case .offline: return ("不在线", .gray.opacity(0.5))
        case .saved: return (model.pairedHost(for: target)?.address ?? "按地址连接", .gray)
        case .discovered, .thisMac: return ("在线", .blue)
        }
    }
}

private struct EmptyHostsView: View {
    let model: ViewerModel
    @Binding var addingHost: Bool

    var body: some View {
        ContentUnavailableView {
            Label("连接另一台 Mac", systemImage: "macmini")
        } description: {
            Text("在另一台 Mac 上安装并打开 AnyRemote，它会出现在左侧「附近」里。\n不在同一网络时，可以按 IP 地址添加。")
        } actions: {
            Button("按地址添加…") { addingHost = true }
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
                Text("正在连接「\(target.name)」…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.code(for: target) == nil || isFailure(FriendlyText.isPairingFailure) {
            PairingPane(target: target, model: model, error: failureMessage.map(FriendlyText.message))
        } else if isFailure(FriendlyText.isBusy) {
            StatusPane(symbol: "person.2.fill", title: FriendlyText.message(failureMessage ?? ""),
                       detail: "同一时间只能有一台 Mac 控制它。接管后，对方会被断开。") {
                Button("接管控制") { Task { await connect(takeOver: true) } }.keyboardShortcut(.defaultAction)
            }
        } else if let failureMessage {
            StatusPane(symbol: "exclamationmark.triangle", title: "连不上「\(target.name)」",
                       detail: FriendlyText.message(failureMessage)) {
                Button("重试") { Task { await connect() } }.keyboardShortcut(.defaultAction)
            }
        } else if target.kind == .offline {
            StatusPane(symbol: "moon.zzz", title: "「\(target.name)」现在不在线",
                       detail: "它开机并运行 AnyRemote 后会自动出现。") {
                Button("仍然尝试连接") { Task { await connect() } }
            }
        } else {
            StatusPane(symbol: "macmini", title: target.name, detail: "已断开连接。") {
                Button("连接") { Task { await connect() } }.keyboardShortcut(.defaultAction)
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
            Text(detail)
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
            Text("与「\(target.name)」配对").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("在「\(target.name)」上点菜单栏的 AnyRemote 图标，选「显示配对码」。", systemImage: "1.circle")
                Label("把那 20 位配对码输入到下面。每台 Mac 只需配对一次。", systemImage: "2.circle")
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
                Button("配对并连接", action: pair)
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
                                           select: { selection = $0; gridFocused = true },
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
        .searchable(text: $query, placement: .toolbar, prompt: "搜索窗口或 App")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { openSelected(in: flat) }
        .onChange(of: query) { selection = flat.first?.windowID }
        .onChange(of: flat.map(\.windowID)) { _, ids in
            if selection.map({ !ids.contains($0) }) ?? true { selection = ids.first }
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
            Button { Task { await connection.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .help("刷新窗口列表")
            Button { FullDesktop.open(connection) } label: { Label("完整桌面", systemImage: "display") }
                .help("用屏幕共享打开整个桌面（装了 iScreenSharing 时用它）")
            Button { model.disconnect(target) } label: { Label("断开", systemImage: "xmark.circle") }
                .help("断开与这台 Mac 的连接，并关闭它的所有窗口")
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let reason = connection.captureBlockedReason ?? connection.inputBlockedReason {
            Label(reason + " 在那台 Mac 上打开 AnyRemote › 设置 授权后，这里会自动恢复。",
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
                ContentUnavailableView("没有可共享的窗口", systemImage: "macwindow",
                                       description: Text("「\(connection.hostName)」上没有打开的窗口。"))
            }
        } else if connection.listing == nil {
            ProgressView()
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("双击或按 ↩ 打开 · 方向键选择 · 按住 ⌥ 打开时保留此窗口")
            Spacer()
            Text("随时按 ⌃⌥⌘0 回到这里")
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
                        .contextMenu { Button(connection.openWindowIDs.contains(window.windowID) ? "切换到这个窗口" : "打开") { open(window) } }
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
                    Text("已打开")
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
                Text("\(Int(window.frame.width)) × \(Int(window.frame.height))")
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
            Text("按地址添加 Mac").font(.title3.weight(.semibold))
            Text("不在同一局域网、或者「附近」里找不到时使用。配对码在那台 Mac 的菜单栏 AnyRemote 图标 › 显示配对码。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("地址", text: $address, prompt: Text("192.168.1.20 或 mac-mini.local"))
                TextField("配对码", text: $code, prompt: Text("XXXXX-XXXXX-XXXXX-XXXXX"))
                    .font(.system(.body, design: .monospaced))
                TextField("名称", text: $name, prompt: Text("可选，默认用那台 Mac 的名字"))
            }
            if let error = model.lastError {
                Text(FriendlyText.message(error)).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("连接") {
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
            Text("重命名「\(target.name)」").font(.headline)
            TextField("名称", text: $name).frame(width: 300).onSubmit(save)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("好", action: save).keyboardShortcut(.defaultAction).disabled(name.isEmpty)
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
