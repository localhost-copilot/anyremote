import AnyRemoteHost
import AppKit
import ServiceManagement
import SwiftUI

/// Settings for letting other Macs control this one.
@MainActor
@Observable
final class HostSettingsModel {
    let service: HostService
    private(set) var settings: HostSettings
    private(set) var status: HostService.Status
    private(set) var permissions = HostService.permissions
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ObservationIgnored var onStatusChange: ((HostService.Status) -> Void)?

    init(service: HostService) {
        self.service = service
        settings = service.settingsStore.settings
        status = service.currentStatus
        service.onStatusChange = { [weak self] status in
            self?.status = status
            self?.onStatusChange?(status)
        }
    }

    func refreshPermissions() {
        let current = HostService.permissions
        if current != permissions { permissions = current }
    }

    func setEnabled(_ enabled: Bool) {
        service.settingsStore.update { $0.isEnabled = enabled }
        settings = service.settingsStore.settings
        if enabled {
            try? service.start()
        } else {
            service.stop()
        }
    }

    func resetCode() {
        service.settingsStore.resetPairingCode()
        settings = service.settingsStore.settings
        service.disconnectViewer()
    }

    func setVirtualDisplay(_ mode: HostSettings.VirtualDisplayMode) {
        service.settingsStore.update { $0.virtualDisplay = mode }
        settings = service.settingsStore.settings
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(settings.code?.description ?? "", forType: .string)
    }

    /// Screen Recording only takes effect in a new process.
    static func relaunch() {
        // A shell outlives us and opens a fresh copy once this one has quit.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

struct HostSettingsView: View {
    @Bindable var model: HostSettingsModel

    var body: some View {
        Form {
            sharingSection
            if model.settings.isEnabled { permissionsSection }
            if model.settings.isEnabled { pairingSection }
            Section("显示") {
                Picker("HiDPI 虚拟显示器", selection: Binding(
                    get: { model.settings.virtualDisplay }, set: { model.setVirtualDisplay($0) })) {
                    Text("没有 Retina 显示器时").tag(HostSettings.VirtualDisplayMode.automatic)
                    Text("始终").tag(HostSettings.VirtualDisplayMode.always)
                    Text("从不").tag(HostSettings.VirtualDisplayMode.never)
                }
                Text("被控制时，窗口移到一块 \(model.settings.virtualDisplayWidth)×\(model.settings.virtualDisplayHeight) pt、"
                     + "2 倍渲染的虚拟显示器上，所以没接显示器的 Mac mini 也能显示清晰的窗口。关闭后窗口移回原处。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("通用") {
                Toggle("登录时打开 AnyRemote", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Text("作为被控端的 Mac mini 建议打开，重启后不用手动启动。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .frame(minHeight: 560)
        .onAppear { model.refreshPermissions() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in model.refreshPermissions() }
    }

    // MARK: Sections

    private var sharingSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.settings.isEnabled }, set: { model.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许其他 Mac 控制这台 Mac").font(.headline)
                    Text(statusText).font(.callout).foregroundStyle(statusColor)
                }
            }
            .toggleStyle(.switch)
            if let viewer = model.status.viewerName {
                HStack {
                    Label("「\(viewer)」正在控制这台 Mac", systemImage: "person.crop.circle.badge.checkmark")
                    Spacer()
                    Button("断开") { model.service.disconnectViewer() }
                }
            }
        }
    }

    private var permissionsSection: some View {
        Section {
            permissionRow("屏幕录制", detail: "让对方看到窗口内容", granted: model.permissions.screenRecording,
                          pane: "Privacy_ScreenCapture")
            permissionRow("辅助功能", detail: "让对方点击、打字、调整窗口大小、使用菜单",
                          granted: model.permissions.accessibility && model.permissions.postEvents,
                          pane: "Privacy_Accessibility")
            if !model.permissions.allGranted {
                VStack(alignment: .leading, spacing: 8) {
                    Text("在系统设置里打开 AnyRemote 的开关。如果列表里已经有 AnyRemote 但开着也不生效，"
                         + "先用「−」删掉它再重新授权，然后重新启动 AnyRemote。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("需要授权的是这一份：\(Bundle.main.bundlePath)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("请求权限") {
                            HostService.requestPermissions()
                            model.refreshPermissions()
                        }
                        Button("重新启动 AnyRemote") { HostSettingsModel.relaunch() }
                    }
                }
            }
        } header: {
            HStack {
                Text("权限")
                Spacer()
                if model.permissions.allGranted {
                    Label("已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
            }
        }
    }

    private var pairingSection: some View {
        Section("配对码") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.settings.code?.description ?? "–")
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("拷贝") { model.copyCode() }
                }
                Text("在要控制这台 Mac 的那台 Mac 上输入一次即可。拿到配对码的人都能控制这台 Mac，不要外传。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("重置配对码…") {
                let alert = NSAlert()
                alert.messageText = "重置配对码？"
                alert.informativeText = "已经配对的 Mac 都需要重新输入新的配对码，当前的控制会被断开。"
                alert.addButton(withTitle: "重置")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn { model.resetCode() }
            }
        }
    }

    // MARK: Helpers

    private var statusText: String {
        if !model.settings.isEnabled { return "已关闭：其他 Mac 连不上这台 Mac" }
        if let error = model.status.error { return "出错：\(error)" }
        if model.status.viewerName != nil { return "正在被控制" }
        if !model.permissions.allGranted { return "缺少权限，对方连上后无法正常使用" }
        if model.status.isListening { return "已就绪，等待连接（端口 \(model.status.port ?? 0)）" }
        return "正在启动…"
    }

    private var statusColor: Color {
        if !model.settings.isEnabled { return .secondary }
        if model.status.error != nil || !model.permissions.allGranted { return .orange }
        return .green
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("打开系统设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
    }
}
