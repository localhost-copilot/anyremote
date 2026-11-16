import AnyRemoteNetwork
import AnyRemoteWindowControl
import AnyRemoteWire
import AppKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Drag")

/// Host side of drag and drop for one session.
///
/// The drag the user sees is always the viewer's own. The host repeats it
/// with a drag of its own that is invisible, driven by the viewer's
/// positions, so apps here highlight folders, show insertion points and take
/// drops natively:
///
/// - A drag that starts here under the viewer's press is noticed on the drag
///   pasteboard and offered to the viewer (`hostDragBegan`), which takes it
///   over. Dropped over one of this Mac's windows, the drop happens here;
///   dropped on the viewer, its files are fetched from here and the drag
///   here ends in `HostDragSurfaces`' catcher, which also takes contents an
///   app only promised.
/// - A drag from the viewer (`DragEvent.offer`) starts here from an injected
///   press in an invisible, non-activating panel. Its items are file promises
///   fetched from the viewer when an app takes the drop; small ones are
///   copied ahead so apps that want plain files get them.
///
/// While the viewer's pointer is over none of this Mac's windows, the drag
/// here waits over a spot that takes no drop, so it can never land by
/// accident. Queue-confined to the session queue; the AppKit parts run on
/// the main thread.
final class HostDragBridge: @unchecked Sendable {
    private let queue: DispatchQueue
    private let injector: InputInjector
    private let send: @Sendable (ControlMessage) -> Void
    /// The global top-left of a stream's surface now, nil for streams that take no input.
    var streamOrigin: (UInt16) -> CGPoint? = { _ in nil }
    /// Brings a stream's window to the front, so a drop at its place lands in it.
    var raiseStream: (UInt16) -> Void = { _ in }

    private let transferLock = NSLock()
    private var transferChannel: FileTransferChannel? // under transferLock
    var transfer: FileTransferChannel? {
        get { transferLock.lock(); defer { transferLock.unlock() }; return transferChannel }
        set { transferLock.lock(); transferChannel = newValue; transferLock.unlock() }
    }

    private enum Helper { case none, starting, running }
    private enum Ending { case drop(CGPoint), finish(accepted: Bool) }

    private struct Drag {
        var manifest: DragManifest
        let fromHost: Bool
        var streamID: UInt16?
        var helper: Helper = .none
        /// The latest position, while the helper drag is starting.
        var pending: CGPoint?
        var pendingEnding: Ending?
        var modifiers: UInt64 = 0
        var dragID: UInt32 { manifest.dragID }
    }

    // Queue-confined.
    private var drag: Drag?
    private var watching: UInt16?
    private var watchTimer: DispatchSourceTimer?
    private var polling = false
    /// Items of this Mac's recent drags, for fetching.
    private var offered: [(dragID: UInt32, sources: [UInt32: DragSourceItem])] = []
    /// Promised contents the catcher received, by drag and item.
    private var caught: [UInt32: [UInt32: URL]] = [:]
    private var waitingForCatch: [UInt32: [(itemID: UInt32, reply: @Sendable (URL?) -> Void)]] = [:]
    /// Drags whose catch is over, received or not.
    private var catchDone: Set<UInt32> = []
    private var nextDragID = UInt32.random(in: 1...0x7fff_ffff)

    private let readQueue = DispatchQueue(label: "anyremote.drag.read", qos: .userInitiated)
    /// Read only on `readQueue`.
    private let board = ClipboardReference(name: .drag)

    init(queue: DispatchQueue, injector: InputInjector, send: @escaping @Sendable (ControlMessage) -> Void) {
        self.queue = queue
        self.injector = injector
        self.send = send
    }

    var isActive: Bool { drag != nil }

    // MARK: Drags starting here

    /// The viewer pressed the left button in a stream: a drag may start.
    func pressBegan(streamID: UInt16) {
        guard drag == nil else { return }
        watching = streamID
        readQueue.async { [board] in _ = board?.synchronize() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        watchTimer?.cancel()
        watchTimer = timer
    }

    /// The viewer's press ended normally: a drag here ended here too.
    func pressEnded() {
        stopWatching()
        if let drag, drag.fromHost, drag.helper == .none {
            self.drag = nil
            HostDragSurfaces.hide()
        }
    }

    private func stopWatching() {
        watching = nil
        watchTimer?.cancel()
        watchTimer = nil
    }

    private func poll() {
        guard watching != nil, !polling else { return }
        polling = true
        nextDragID &+= 1
        let dragID = nextDragID
        readQueue.async { [self] in
            // Writing the drag pasteboard is how every drag begins.
            let result: (manifest: DragManifest, sources: [UInt32: DragSourceItem])? =
                if let board, board.synchronize() {
                    DragContents.read(DragContents.entries(of: board), dragID: dragID, icons: true)
                } else { nil }
            queue.async { [self] in
                polling = false
                guard let result else { return }
                hostDragStarted(result.manifest, sources: result.sources)
            }
        }
    }

    private func hostDragStarted(_ manifest: DragManifest, sources: [UInt32: DragSourceItem]) {
        guard let streamID = watching, injector.isPressed, drag == nil else { return }
        stopWatching()
        guard !manifest.items.isEmpty else { return }
        log.notice("drag began here: \(manifest.items.count) items")
        drag = Drag(manifest: manifest, fromHost: true, streamID: streamID)
        remember(manifest.dragID, sources)
        HostDragSurfaces.show()
        send(.hostDragBegan(streamID: streamID, manifest))
    }

    private func remember(_ dragID: UInt32, _ sources: [UInt32: DragSourceItem]) {
        offered.append((dragID, sources))
        if offered.count > 4 {
            let gone = offered.removeFirst().dragID
            caught[gone] = nil
            catchDone.remove(gone)
            waitingForCatch.removeValue(forKey: gone)?.forEach { $0.reply(nil) }
        }
    }

    /// Serves the viewer's fetch of an item of this Mac's drag.
    func resolve(dragID: UInt32, itemID: UInt32, reply: @escaping @Sendable (URL?) -> Void) {
        guard let source = offered.last(where: { $0.dragID == dragID })?.sources[itemID] else { return reply(nil) }
        switch source {
        case .file(let url):
            reply(url)
        case .promise:
            if let url = caught[dragID]?[itemID] { return reply(url) }
            if catchDone.contains(dragID) { return reply(nil) }
            waitingForCatch[dragID, default: []].append((itemID, reply))
            queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, var waiting = self.waitingForCatch[dragID] else { return }
                waiting.removeAll { entry in
                    guard entry.itemID == itemID else { return false }
                    entry.reply(nil)
                    return true
                }
                self.waitingForCatch[dragID] = waiting
            }
        }
    }

    private func caughtPromises(dragID: UInt32, _ urls: [UInt32: URL]) {
        caught[dragID, default: [:]].merge(urls) { $1 }
        catchDone.insert(dragID)
        // Whatever didn't arrive won't any more.
        for entry in waitingForCatch.removeValue(forKey: dragID) ?? [] {
            entry.reply(caught[dragID]?[entry.itemID])
        }
    }

    // MARK: The viewer's drag

    func handle(_ event: DragEvent) {
        switch event {
        case .offer(let manifest):
            if let drag, drag.dragID != manifest.dragID { end(drag, .finish(accepted: false)) }
            guard drag == nil else { return }
            log.notice("viewer offers a drag: \(manifest.items.count) items")
            drag = Drag(manifest: manifest, fromHost: false)
            HostDragSurfaces.show()
            stageAhead(manifest)

        case let .over(dragID, streamID, point, modifiers):
            guard var drag, drag.dragID == dragID, let origin = streamOrigin(streamID) else { return }
            let location = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
            if drag.streamID != streamID {
                drag.streamID = streamID
                raiseStream(streamID)
            }
            drag.modifiers = modifiers
            switch drag.helper {
            case .none where !drag.fromHost:
                drag.helper = .starting
                drag.pending = location
                self.drag = drag
                startHelper(at: location)
            case .starting:
                drag.pending = location
                self.drag = drag
            default:
                self.drag = drag
                injector.drag(to: location, modifiers: modifiers)
            }

        case .away(let dragID):
            guard var drag, drag.dragID == dragID else { return }
            drag.streamID = nil
            self.drag = drag
            // Only over the spot that is known to take no drop; if it isn't
            // up, the drag stays over the window the pointer just left.
            if drag.fromHost || drag.helper == .running, HostDragSurfaces.isParkingReady {
                injector.drag(to: HostDragSurfaces.parkingPoint, modifiers: drag.modifiers)
            }

        case let .drop(dragID, streamID, point, names):
            guard let drag, drag.dragID == dragID else { return }
            guard let origin = streamOrigin(streamID) else { return end(drag, .finish(accepted: false)) }
            if !names.isEmpty {
                DispatchQueue.main.async { MainActor.assumeIsolated { HostDragSurfaces.rename(names) } }
            }
            end(drag, .drop(CGPoint(x: origin.x + point.x, y: origin.y + point.y)))

        case let .finish(dragID, accepted):
            guard let drag, drag.dragID == dragID else { return }
            end(drag, .finish(accepted: accepted))
        }
    }

    /// Ends the drag here: drops it, lets the catcher take it, or cancels it.
    private func end(_ current: Drag, _ ending: Ending) {
        if current.helper == .starting {
            drag?.pendingEnding = ending
            return
        }
        drag = nil
        defer {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.drag == nil { HostDragSurfaces.hide() }
            }
        }
        // The viewer's drag never came over a window here: nothing is held.
        guard current.fromHost || current.helper == .running else { return }
        switch ending {
        case .drop(let location):
            // Through the main queue, so the drop's names reach the promises first.
            DispatchQueue.main.async { [self] in
                queue.async { [self] in
                    injector.drag(to: location, modifiers: current.modifiers)
                    injector.releaseDrag(at: location)
                }
            }
        case .finish(let accepted):
            let promised = current.manifest.items.filter { item in
                offered.last { $0.dragID == current.dragID }?.sources[item.itemID] == .promise
            }.map(\.itemID)
            guard current.fromHost, accepted, !promised.isEmpty else {
                // Taken on the viewer (plain files are fetched as they are)
                // or cancelled: either way the drag here ends without a drop.
                return cancelInPlace()
            }
            // Promised contents exist only once dropped: the spot catches the drag.
            let dragID = current.dragID
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    HostDragSurfaces.catchNext(dragID: dragID, promisedItemIDs: promised) { [self] urls in
                        queue.async { [self] in caughtPromises(dragID: dragID, urls) }
                    }
                }
                queue.async { [self] in
                    guard HostDragSurfaces.isParkingReady else {
                        log.error("the catcher is not up; cancelling the drag")
                        cancelInPlace()
                        caughtPromises(dragID: dragID, [:])
                        return
                    }
                    let parking = HostDragSurfaces.parkingPoint
                    injector.drag(to: parking, modifiers: 0)
                    injector.releaseDrag(at: parking)
                }
            }
        }
    }

    /// Escape ends the drag wherever it is, without a drop; then the button comes up.
    private func cancelInPlace() {
        injector.cancelDrag()
        injector.releaseDrag(at: CGEvent(source: nil)?.location ?? HostDragSurfaces.parkingPoint)
    }

    /// The session is ending: nothing stays held.
    func cancel() {
        stopWatching()
        if let drag { end(drag, .finish(accepted: false)) }
    }

    // MARK: The helper drag

    private func startHelper(at location: CGPoint) {
        guard let drag else { return }
        let manifest = drag.manifest
        let fetcher = fetcher(dragID: drag.dragID)
        let staged = stagedCopies
        DispatchQueue.main.async { [self] in
            let panel = MainActor.assumeIsolated {
                HostDragSurfaces.prepareSource(at: location, manifest: manifest, staged: staged, fetch: fetcher)
            }
            queue.async { [self] in helperReady(at: location, panel: panel, attempt: 0) }
        }
    }

    private func helperReady(at location: CGPoint, panel: CGWindowID, attempt: Int) {
        guard var drag, drag.helper == .starting else {
            DispatchQueue.main.async { MainActor.assumeIsolated { HostDragSurfaces.discardSource() } }
            return
        }
        // The press must land in the panel, never in the app beneath it: the
        // window server shows a new window a moment after it is ordered in.
        guard HostDragSurfaces.isFrontmost(panel, at: location) else {
            if attempt < 25 {
                queue.asyncAfter(deadline: .now() + .milliseconds(8)) { [self] in
                    helperReady(at: location, panel: panel, attempt: attempt + 1)
                }
            } else {
                log.error("the drag panel did not come up; dropping the drag")
                self.drag = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { HostDragSurfaces.discardSource() } }
                HostDragSurfaces.hide()
            }
            return
        }
        // A press in the panel, then a little movement: AppKit begins the drag.
        injector.pressForDrag(at: location)
        for step in 1...3 {
            usleep(8_000)
            injector.drag(to: CGPoint(x: location.x + CGFloat(step * 2), y: location.y), modifiers: drag.modifiers)
        }
        drag.helper = .running
        let pending = drag.pending
        let ending = drag.pendingEnding
        drag.pending = nil
        drag.pendingEnding = nil
        self.drag = drag
        if let pending { injector.drag(to: pending, modifiers: drag.modifiers) }
        if let ending { end(drag, ending) }
    }

    // MARK: Fetching the viewer's items

    private var stagedCopies: [UInt32: StagedCopy] = [:]

    /// Copies a small drag's files ahead, so they are plain files by the drop.
    private func stageAhead(_ manifest: DragManifest) {
        stagedCopies = [:]
        let files = manifest.items.compactMap { item in item.file.map { (item.itemID, $0) } }
        guard !files.isEmpty, files.allSatisfy({ $0.1.size >= 0 }),
              manifest.fileBytes <= DragStaging.aheadLimit, let transfer else { return }
        DragStaging.removeStale()
        for (itemID, file) in files {
            let url = DragStaging.folder("viewer", dragID: manifest.dragID, itemID: itemID)
                .appendingPathComponent(DragContents.sanitized(file.name))
            let dragID = manifest.dragID
            let copy = StagedCopy(url: url) { copy in
                transfer.fetch(dragID: dragID, itemID: itemID, to: url) { result in
                    if case .failure(let error) = result {
                        log.error("copying ahead failed: \(error.localizedDescription, privacy: .public)")
                    }
                    copy.finish((try? result.get()) != nil)
                }
            }
            stagedCopies[itemID] = copy
            // The drag came over this Mac's windows: it is likely dropped here.
            copy.begin()
        }
    }

    private func fetcher(dragID: UInt32) -> @Sendable (UInt32) -> TransferFilePromise.Fetch {
        let bridge = WeakBox(self)
        return { itemID in
            { destination, progress, completion in
                guard let transfer = bridge.value?.transfer else {
                    completion(FileTransferChannel.TransferError.closed)
                    return {}
                }
                let fetch = transfer.fetch(dragID: dragID, itemID: itemID, to: destination, progress: progress) {
                    if let error = $0.error {
                        log.error("fetch failed: \(error.localizedDescription, privacy: .public)")
                    }
                    completion($0.error)
                }
                return { fetch.cancel() }
            }
        }
    }
}

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

private extension Result {
    var error: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

// MARK: - Windows

/// The invisible windows behind bridged drags, shared by all sessions (there
/// is one pointer): a non-activating panel a helper drag starts from, and the
/// parking spot where a drag waits while the viewer's pointer is elsewhere.
/// The spot takes no drop, except when told to catch one.
@MainActor
enum HostDragSurfaces {
    private static var zone: NSPanel?
    private static var zoneView: DragZoneView?
    private static var source: NSPanel?
    private static var promises: [UInt32: TransferFilePromise] = [:]

    nonisolated private static let parkingLock = NSLock()
    nonisolated(unsafe) private static var parking = CGPoint(x: 400, y: 400)
    nonisolated(unsafe) private static var zoneWindowID: CGWindowID = 0
    /// Global top-left points of the parking spot. Thread-safe.
    nonisolated static var parkingPoint: CGPoint {
        parkingLock.lock()
        defer { parkingLock.unlock() }
        return parking
    }

    /// True when the spot is up and on top. Thread-safe.
    nonisolated static var isParkingReady: Bool {
        parkingLock.lock()
        let window = zoneWindowID
        let point = parking
        parkingLock.unlock()
        return isFrontmost(window, at: point)
    }

    nonisolated static func show() {
        DispatchQueue.main.async { MainActor.assumeIsolated { showZone() } }
    }

    nonisolated static func hide() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                zone?.orderOut(nil)
                zoneView?.catching = nil
            }
        }
    }

    private static func showZone() {
        // Low on the main display, clear of the Dock and of hot corners.
        guard let screen = NSScreen.screens.first else { return }
        let size: CGFloat = 48
        let frame = NSRect(x: screen.frame.midX - size / 2, y: screen.frame.minY + screen.frame.height * 0.3,
                           width: size, height: size)
        if zone == nil {
            let view = DragZoneView(frame: NSRect(origin: .zero, size: frame.size))
            let panel = invisiblePanel(frame)
            panel.contentView = view
            zone = panel
            zoneView = view
        }
        zone?.setFrame(frame, display: false)
        zone?.orderFrontRegardless()
        parkingLock.lock()
        parking = CGPoint(x: frame.midX, y: screen.frame.maxY - frame.midY)
        zoneWindowID = CGWindowID(zone?.windowNumber ?? 0)
        parkingLock.unlock()
    }

    /// The next drop on the spot is taken, receiving the promised items.
    static func catchNext(dragID: UInt32, promisedItemIDs: [UInt32], completion: @escaping @Sendable ([UInt32: URL]) -> Void) {
        showZone()
        zoneView?.catching = (dragID, promisedItemIDs, completion)
    }

    /// Returns the panel's window number.
    static func prepareSource(at location: CGPoint, manifest: DragManifest, staged: [UInt32: StagedCopy],
                              fetch: @escaping @Sendable (UInt32) -> TransferFilePromise.Fetch) -> CGWindowID {
        discardSource()
        guard let screen = NSScreen.screens.first else { return 0 }
        let size: CGFloat = 16
        let frame = NSRect(x: location.x - size / 2, y: screen.frame.maxY - location.y - size / 2,
                           width: size, height: size)
        var made: [UInt32: TransferFilePromise] = [:]
        let writers = DragItemsBuilder.writers(for: manifest) { item, file in
            let promise = TransferFilePromise(item: item, file: file, staged: staged[item.itemID],
                                              fetch: fetch(item.itemID))
            made[item.itemID] = promise
            return promise
        }
        promises = made
        let view = DragSourceView(frame: NSRect(origin: .zero, size: frame.size))
        view.writers = writers
        let panel = invisiblePanel(frame)
        panel.contentView = view
        panel.orderFrontRegardless()
        source = panel
        return CGWindowID(panel.windowNumber)
    }

    /// True when the window server has `window` on top at `location`
    /// (global top-left points). Thread-safe.
    nonisolated static func isFrontmost(_ window: CGWindowID, at location: CGPoint) -> Bool {
        guard window != 0, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        // Drag images (and whatever is as high) don't take drops: drags see through them.
        let dragLevel = Int(CGWindowLevelForKey(.draggingWindow))
        let top = list.first { info in
            guard (info[kCGWindowLayer as String] as? Int ?? 0) < dragLevel,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.contains(location) && (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
        return (top?[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } == window
    }

    static func discardSource() {
        source?.orderOut(nil)
        source = nil
    }

    static func rename(_ names: [UInt32: String]) {
        for (itemID, name) in names { promises[itemID]?.rename(name) }
    }

    /// Takes clicks without activating AnyRemote (the app being dropped on
    /// stays in front), above apps' windows, practically invisible.
    private static func invisiblePanel(_ frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        // Fully clear windows are skipped when finding what's under the pointer.
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        panel.hasShadow = false
        // Above apps' windows and panels, but not as high as the screen
        // saver level: drags pass through windows up there to what is beneath.
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        // AnyRemote is rarely the active app on the host.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = .none
        return panel
    }
}

/// Starts the helper drag on the injected press.
private final class DragSourceView: NSView, NSDraggingSource {
    var writers: [NSPasteboardWriting] = []
    private var began = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { log.debug("helper press") }

    override func mouseDragged(with event: NSEvent) {
        guard !began else { return }
        began = true
        let clear = NSImage(size: NSSize(width: 1, height: 1))
        let items = writers.map { writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            // The viewer shows the drag; here it is invisible.
            item.setDraggingFrame(NSRect(x: 0, y: 0, width: 1, height: 1), contents: clear)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
        window?.orderOut(nil)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copies: the items live on the other Mac.
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        log.notice("drag here ended: operation \(operation.rawValue)")
    }
}

/// The parking spot: refuses drops, or catches the next one.
private final class DragZoneView: NSView {
    var catching: (dragID: UInt32, promisedItemIDs: [UInt32], completion: @Sendable ([UInt32: URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .string, .URL, .png, .tiff, .rtf, .html]
                                + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { catching == nil ? [] : .copy }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { catching == nil ? [] : .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let catching else { return false }
        self.catching = nil
        let receivers = sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver] ?? []
        let pairs = Array(zip(catching.promisedItemIDs, receivers))
        guard !pairs.isEmpty else {
            catching.completion([:])
            return true
        }
        let collected = Collected(count: pairs.count, completion: catching.completion)
        for (itemID, receiver) in pairs {
            Collected.receive(receiver, itemID: itemID, dragID: catching.dragID, into: collected)
        }
        return true
    }
}

/// Gathers promised files as they arrive.
private final class Collected: @unchecked Sendable {
    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var remaining: Int
    private var urls: [UInt32: URL] = [:]
    private let completion: @Sendable ([UInt32: URL]) -> Void

    init(count: Int, completion: @escaping @Sendable ([UInt32: URL]) -> Void) {
        remaining = count
        self.completion = completion
    }

    /// Off the main actor: the reader runs on `queue`.
    nonisolated static func receive(_ receiver: NSFilePromiseReceiver, itemID: UInt32, dragID: UInt32,
                                    into collected: Collected) {
        let folder = DragStaging.folder("host", dragID: dragID, itemID: itemID)
        nonisolated(unsafe) var delivered = false
        receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
            // One item may hold several files; the first stands for it.
            guard !delivered else { return }
            delivered = true
            collected.add(itemID, error == nil ? url : nil)
        }
    }

    /// On `queue`.
    func add(_ itemID: UInt32, _ url: URL?) {
        if let url { urls[itemID] = url }
        remaining -= 1
        if remaining == 0 { completion(urls) }
    }
}
