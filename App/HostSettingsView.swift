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

    private(set) var language = AppLanguage.current

    private(set) var showsRemoteAppsInDock = DockProxies.isEnabled
    private(set) var sharesClipboard = ClipboardSharing.isEnabled
    private(set) var playsRemoteSound = SoundSharing.isEnabled
    private(set) var composesOnThisMac = TextInputPreferences.composesOnThisMac

    func setComposesOnThisMac(_ value: Bool) {
        composesOnThisMac = value
        TextInputPreferences.composesOnThisMac = value
    }

    func setPlaysRemoteSound(_ value: Bool) {
        playsRemoteSound = value
        SoundSharing.isEnabled = value
    }

    func setMutesSoundWhileShared(_ value: Bool) {
        service.settingsStore.update { $0.mutesSoundWhileShared = value }
        settings = service.settingsStore.settings
        service.settingsChanged()
    }

    func setSharesClipboard(_ value: Bool) {
        sharesClipboard = value
        ClipboardSharing.isEnabled = value
    }

    func setShowsRemoteAppsInDock(_ value: Bool) {
        showsRemoteAppsInDock = value
        DockProxies.isEnabled = value
    }

    func setLanguage(_ language: AppLanguage) {
        guard language != self.language else { return }
        AppLanguage.choose(language)
        self.language = language
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart AnyRemote to change the language?")
        alert.informativeText = String(localized: "The new language is used the next time AnyRemote opens. Open remote windows will close.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { Self.relaunch() }
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
            Section("Display") {
                Picker("HiDPI Virtual Display", selection: Binding(
                    get: { model.settings.virtualDisplay }, set: { model.setVirtualDisplay($0) })) {
                    Text("When No Retina Display Is Connected").tag(HostSettings.VirtualDisplayMode.automatic)
                    Text("Always").tag(HostSettings.VirtualDisplayMode.always)
                    Text("Never").tag(HostSettings.VirtualDisplayMode.never)
                }
                Text("While being controlled, windows move to a \(String(model.settings.virtualDisplayWidth))×\(String(model.settings.virtualDisplayHeight)) pt virtual display rendered at 2×, so even a Mac mini without a display shows sharp windows. They move back afterwards.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Sound") {
                Toggle("Play Sound from Other Macs", isOn: Binding(
                    get: { model.playsRemoteSound }, set: { model.setPlaysRemoteSound($0) }))
                Text("You hear the apps whose windows are open here, or everything while a full desktop is open.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Mute This Mac While Its Sound Plays Elsewhere", isOn: Binding(
                    get: { model.settings.mutesSoundWhileShared }, set: { model.setMutesSoundWhileShared($0) }))
                Text("When another Mac controls this one, the apps it listens to go quiet here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Typing") {
                Picker("Input Method", selection: Binding(
                    get: { model.composesOnThisMac }, set: { model.setComposesOnThisMac($0) })) {
                    Text("This Mac's").tag(true)
                    Text("The Other Mac's").tag(false)
                }
                Text(model.composesOnThisMac
                     ? "Type with this Mac's input method; its candidates show next to the other Mac's text."
                     : "The other Mac's input method composes. It switches along with the input source you select here, if that Mac has it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("General") {
                Picker("Language", selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                    Text("Follow System").tag(AppLanguage.system)
                }
                Toggle("Share Clipboard", isOn: Binding(
                    get: { model.sharesClipboard }, set: { model.setSharesClipboard($0) }))
                Text("Copy on one Mac, paste on the other: text, images and links. Files and passwords stay on their Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Show Remote Apps in the Dock", isOn: Binding(
                    get: { model.showsRemoteAppsInDock }, set: { model.setShowsRemoteAppsInDock($0) }))
                Text("Each app with windows open here gets its own Dock icon and ⌘Tab entry. Quitting it closes its windows on this Mac only.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Open AnyRemote at Login", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Text("Recommended on a Mac mini that is controlled remotely, so it’s ready after a restart.")
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
                    Text("Allow Other Macs to Control This Mac").font(.headline)
                    Text(statusText).font(.callout).foregroundStyle(statusColor)
                }
            }
            .toggleStyle(.switch)
            ForEach(model.status.viewers) { viewer in
                HStack {
                    Label("“\(viewer.name)” is controlling this Mac", systemImage: "person.crop.circle.badge.checkmark")
                    Spacer()
                    Button("Disconnect") { model.service.disconnectViewer(id: viewer.id) }
                }
            }
        }
    }

    private var permissionsSection: some View {
        Section {
            permissionRow("Screen Recording", detail: "Lets the other Mac see window contents", permission: .screenRecording)
            permissionRow("Accessibility", detail: "Lets the other Mac click, type, resize windows and use menus",
                          permission: .accessibility)
        } header: {
            HStack {
                Text("Permissions")
                Spacer()
                if model.permissions.allGranted {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
            }
        }
    }

    private var pairingSection: some View {
        Section("Pairing Code") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.settings.code?.description ?? "–")
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") { model.copyCode() }
                }
                Text("Enter it once on the Mac that will control this one. Anyone with this code can control this Mac, so keep it private.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Reset Pairing Code…") {
                let alert = NSAlert()
                alert.messageText = String(localized: "Reset the pairing code?")
                alert.informativeText = String(localized: "Paired Macs will need to enter the new code, and the current session will be disconnected.")
                alert.addButton(withTitle: String(localized: "Reset"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                if alert.runModal() == .alertFirstButtonReturn { model.resetCode() }
            }
        }
    }

    // MARK: Helpers

    private var statusText: String {
        if !model.settings.isEnabled { return String(localized: "Off: other Macs can’t connect to this Mac") }
        if let error = model.status.error { return String(localized: "Error: \(error)") }
        if model.status.viewerName != nil { return String(localized: "Being controlled") }
        if !model.permissions.allGranted { return String(localized: "Permissions missing; the other Mac won’t work properly when it connects") }
        if model.status.isListening { return String(localized: "Ready, waiting for a connection (port \(String(model.status.port ?? 0)))") }
        return String(localized: "Starting…")
    }

    private var statusColor: Color {
        if !model.settings.isEnabled { return .secondary }
        if model.status.error != nil || !model.permissions.allGranted { return .orange }
        return .green
    }

    private func permissionRow(_ title: LocalizedStringKey, detail: LocalizedStringKey,
                               permission: PermissionGuide.Permission) -> some View {
        let granted = permission.isGranted(model.permissions)
        let isNext = PermissionGuide.Permission.allCases.first { !$0.isGranted(model.permissions) } == permission
        return HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("On").foregroundStyle(.secondary)
            } else if isNext {
                Button("Turn On…") { PermissionGuide.shared.start(permission) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Turn On…") { PermissionGuide.shared.start(permission) }
            }
        }
    }
}
