import AnyRemoteNetwork
import AnyRemoteUpdate
import AnyRemoteWire
import AppKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Update")

/// Keeps AnyRemote up to date from its GitHub releases.
///
/// New releases are downloaded and checked in the background (see
/// `UpdateStager`), then offered with Install and Relaunch. One that is put
/// off installs when AnyRemote quits. A paired Mac may also ask this one to
/// update itself, which it then does without asking: being allowed to
/// control this Mac covers that.
@MainActor
@Observable
final class SoftwareUpdate {
    static let shared = SoftwareUpdate()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(version: String, fraction: Double)
        case ready(StagedUpdate)
        case installing(version: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?
    /// Development builds are ad-hoc signed: no release can prove it comes
    /// from the same signer, so they don't update.
    let isSupported: Bool
    var currentVersion: String { AppVersionInfo.runningAppVersion }

    var automaticallyChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecks, forKey: Self.automaticKey)
            scheduleChecks()
        }
    }

    /// Shows the update window (an update became ready, or the user asked).
    @ObservationIgnored var showWindow: (() -> Void)?
    /// Whether people would lose something by a relaunch now, for the window.
    @ObservationIgnored var activityDescription: (() -> [String])?

    @ObservationIgnored private let requirement: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var work: Task<StagedUpdate?, Never>?
    /// The version the user put off; not offered again until relaunch.
    @ObservationIgnored private var postponedVersion: String?

    private static let automaticKey = "AnyRemoteChecksForUpdates"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private init() {
        requirement = CodeSignature.runningAppRequirement()
        isSupported = requirement != nil
        automaticallyChecks = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    /// Where the latest release's manifest is (`ANYREMOTE_UPDATE_FEED`
    /// points at a test server).
    private var feedURL: URL {
        ProcessInfo.processInfo.environment["ANYREMOTE_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? UpdateManifest.latestURL
    }

    private var stager: UpdateStager? {
        guard let requirement, let identifier = Bundle.main.bundleIdentifier else { return nil }
        let directory: URL
        if let home = ProcessInfo.processInfo.environment["ANYREMOTE_HOME"] {
            directory = URL(fileURLWithPath: home).appendingPathComponent("Updates", isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(identifier, isDirectory: true)
                .appendingPathComponent("Updates", isDirectory: true)
        }
        return UpdateStager(directory: directory, bundleIdentifier: identifier, requirement: requirement)
    }

    /// Called once at launch.
    func start() {
        guard isSupported else {
            log.notice("updates are off: this build isn't signed by the release identity")
            return
        }
        // What an earlier install left (the archive, the install script, which
        // has finished by now). Nothing else is staged at launch.
        if let directory = stager?.directory {
            Task {
                try? await Task.sleep(for: .seconds(10))
                if case .idle = state { try? FileManager.default.removeItem(at: directory) }
            }
        }
        scheduleChecks()
    }

    private func scheduleChecks() {
        timer?.invalidate()
        timer = nil
        guard isSupported, automaticallyChecks else { return }
        // Shortly after launch, then daily. A check finding nothing is quiet.
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in _ = await SoftwareUpdate.shared.check(userInitiated: false) }
        }
        Task {
            try? await Task.sleep(for: .seconds(15))
            if automaticallyChecks, lastChecked == nil { _ = await check(userInitiated: false) }
        }
    }

    /// Checks for a newer release and downloads it. The window opens for a
    /// ready update, and when the user asked, for every outcome.
    /// `quiet`: never opens the window (for another Mac's request).
    @discardableResult
    func check(userInitiated: Bool, quiet: Bool = false) async -> StagedUpdate? {
        if userInitiated { showWindow?() }
        switch state {
        case .ready(let staged):
            if !quiet, userInitiated || staged.manifest.version != postponedVersion { showWindow?() }
            return staged
        case .installing: return nil
        default: break
        }
        if let work { return await work.value }
        let task = Task<StagedUpdate?, Never> { await download(userInitiated: userInitiated, quiet: quiet) }
        work = task
        let staged = await task.value
        work = nil
        return staged
    }

    private func download(userInitiated: Bool, quiet: Bool) async -> StagedUpdate? {
        guard let stager else { return nil }
        state = .checking
        do {
            let manifest = try await UpdateStager.fetchManifest(from: feedURL)
            lastChecked = Date()
            guard manifest.isNewer(than: currentVersion), manifest.supportsThisSystem else {
                state = .upToDate
                return nil
            }
            log.notice("downloading AnyRemote \(manifest.version, privacy: .public)")
            state = .downloading(version: manifest.version, fraction: 0)
            let staged = try await stager.download(manifest) { [weak self] fraction in
                if case .downloading? = self?.state {
                    self?.state = .downloading(version: manifest.version, fraction: fraction)
                }
            }
            log.notice("AnyRemote \(manifest.version, privacy: .public) is ready to install")
            state = .ready(staged)
            if !quiet, userInitiated || manifest.version != postponedVersion { showWindow?() }
            return staged
        } catch {
            log.error("update failed: \(error.localizedDescription, privacy: .public)")
            // A failed background check is retried tomorrow without a word.
            state = userInitiated ? .failed(error.localizedDescription) : .idle
            return nil
        }
    }

    /// The user put the ready update off: it installs when AnyRemote quits.
    func postpone() {
        if case .ready(let staged) = state { postponedVersion = staged.manifest.version }
    }

    var canReplaceApp: Bool { UpdateInstaller.canReplace(Bundle.main.bundleURL) }

    /// Quits and relaunches with the ready update.
    func installAndRelaunch() {
        guard case .ready(let staged) = state else { return }
        guard install(staged, relaunch: true) else { return }
        // Give the window a moment to show that it is relaunching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    /// From `applicationWillTerminate`: a ready update replaces the app now
    /// that it quits, without relaunching it.
    func installOnQuit() {
        guard case .ready(let staged) = state else { return }
        _ = install(staged, relaunch: false)
    }

    private func install(_ staged: StagedUpdate, relaunch: Bool) -> Bool {
        let app = Bundle.main.bundleURL
        do {
            guard UpdateInstaller.canReplace(app) else {
                throw UpdateError.install(String(localized: "AnyRemote can't replace itself where it is (\(app.deletingLastPathComponent().path)). Move it to Applications, or replace it with the downloaded copy shown in Finder."))
            }
            // The staging folder is this user's: check again what is about to run.
            try stager?.check(staged.appURL, version: staged.manifest.version)
            // Development launches keep their own settings and test feed.
            let kept = ProcessInfo.processInfo.environment.filter { key, _ in
                ["ANYREMOTE_HOME", "ANYREMOTE_UPDATE_FEED", "ANYREMOTE_LOOPBACK"].contains(key)
            }
            try UpdateInstaller.start(staged, replacing: app, waitingFor: getpid(), relaunch: relaunch,
                                      environment: kept)
            log.notice("installing AnyRemote \(staged.manifest.version, privacy: .public)")
            state = .installing(version: staged.manifest.version)
            return true
        } catch {
            log.error("install failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            if !UpdateInstaller.canReplace(app) {
                NSWorkspace.shared.activateFileViewerSelecting([staged.appURL])
            }
            return false
        }
    }

    // MARK: Requests from other Macs

    /// A paired Mac asked this one to update (on the host's queue).
    nonisolated static func remoteRequestHandler() -> RemoteUpdateHandler {
        { viewerName, reply in
            Task { @MainActor in
                let outcome = await SoftwareUpdate.shared.updateForRemoteRequest(from: viewerName)
                reply(outcome)
                // Relaunch once the answer is on its way.
                if case .started = outcome {
                    try? await Task.sleep(for: .seconds(1))
                    SoftwareUpdate.shared.installAndRelaunch()
                }
            }
        }
    }

    /// The refusals are English: they travel to the other Mac, which
    /// translates them (`FriendlyText`).
    private func updateForRemoteRequest(from viewerName: String) async -> RemoteUpdateOutcome {
        log.notice("\(viewerName, privacy: .public) asked to update this Mac")
        guard isSupported else {
            return .refused(reason: "That Mac runs a development build of AnyRemote, which doesn't update.")
        }
        guard canReplaceApp else {
            return .refused(reason: "AnyRemote on that Mac can't replace itself where it is installed.")
        }
        if case .installing(let version) = state { return .started(version: version) }
        if let staged = await check(userInitiated: false, quiet: true) { return .started(version: staged.manifest.version) }
        switch state {
        case .upToDate: return .refused(reason: "That Mac already runs the latest AnyRemote (\(currentVersion)).")
        default: return .refused(reason: "That Mac couldn't download the update. Check its internet connection.")
        }
    }
}
