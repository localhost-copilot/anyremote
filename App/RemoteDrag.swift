import AnyRemoteClient
import AnyRemoteWindowControl
import AnyRemoteWire
import AppKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Drag")

/// A surface that takes part in drags: a mirror, or a full desktop.
@MainActor
protocol RemoteDragTarget: AnyObject {
    var connection: HostConnection { get }
    var streamID: UInt16 { get }
    func hostPoint(forScreenPoint point: NSPoint) -> CGPoint
    /// A drag that began on the host becomes this Mac's drag at this point.
    /// A mirror takes it over at once (its picture lacks the host's drag
    /// image); a full desktop shows the host's own until the pointer leaves it.
    func takesOverHostDrag(at screenPoint: NSPoint) -> Bool
    /// True for a full desktop: the drag here begins at its edge, with the host's drag waiting meanwhile.
    var handsOverAtEdge: Bool { get }
}

/// Drag and drop between this Mac and the Macs it controls, like between
/// two windows of one Mac.
///
/// The drag the user sees is always this Mac's own, so it follows the
/// pointer without delay and works with every app here. The host repeats it
/// invisibly (`HostDragBridge`), so its apps react and take drops natively:
///
/// - A drag that begins on the host is taken over by a drag here whose items
///   are file promises (and staged files when small), fetched from the host
///   when an app here takes the drop. Over the same host's windows it stays
///   the host's drag, so a Finder move there is still a move.
/// - A drag from here (or from another host's window) is offered to a host
///   when it first comes over one of its windows; the host fetches the files
///   when an app there takes the drop.
@MainActor
final class RemoteDragCoordinator: NSObject, NSDraggingSource {
    static let shared = RemoteDragCoordinator()

    /// A drag that began on a host, until this Mac's drag takes it over.
    private struct PendingHostDrag {
        weak var connection: HostConnection?
        let streamID: UInt16
        let manifest: DragManifest
    }

    /// This Mac's drag carrying a host's drag.
    private struct HostDrag {
        weak var connection: HostConnection?
        let manifest: DragManifest
        let staged: [UInt32: StagedCopy]
        var droppedOnHost = false
        /// Over one of the host's surfaces right now.
        var over = false
    }

    /// A drag from here, offered to one host.
    private final class Offer {
        let dragID: UInt32
        let sequenceNumber: Int
        weak var connection: HostConnection?
        var sources: [UInt32: DragSourceItem]
        var over = false
        var dropped = false
        var finished = false
        /// Promised contents arrive once dropped; the host's fetches wait.
        var waiting: [(itemID: UInt32, reply: @Sendable (URL?) -> Void)] = []

        init(dragID: UInt32, sequenceNumber: Int, connection: HostConnection, sources: [UInt32: DragSourceItem]) {
            self.dragID = dragID
            self.sequenceNumber = sequenceNumber
            self.connection = connection
            self.sources = sources
        }
    }

    private var pending: PendingHostDrag?
    private var hostDrag: HostDrag?
    private var offers: [Offer] = []
    private var nextDragID = UInt32.random(in: 0x8000_0000...0xffff_fff0)
    private var releaseWatch: Timer?

    /// What a surface registers for: anything worth carrying to another Mac.
    static let draggedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string, .rtf, .html, .png, .tiff, .init("public.jpeg"), .init("com.apple.flat-rtfd")]
        + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

    // MARK: Drags from a host

    func hostDragBegan(connection: HostConnection, streamID: UInt16, manifest: DragManifest) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            // Released already: the drop happened on the host.
            return
        }
        pending = PendingHostDrag(connection: connection, streamID: streamID, manifest: manifest)
    }

    /// On the press's drag events: begins this Mac's drag once the surface lets it.
    func surfaceDragged(_ surface: RemoteSurfaceView, target: any RemoteDragTarget, event: NSEvent) -> Bool {
        guard let pending, pending.connection === target.connection else { return false }
        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard target.takesOverHostDrag(at: screenPoint) else { return false }
        self.pending = nil
        beginHostDrag(pending, from: surface, target: target, event: event)
        return true
    }

    /// The press ended on the host's own terms.
    func pressEnded() { pending = nil }

    private func beginHostDrag(_ pending: PendingHostDrag, from surface: RemoteSurfaceView,
                               target: any RemoteDragTarget, event: NSEvent) {
        guard let connection = pending.connection else { return }
        let manifest = pending.manifest
        let client = connection.client
        let staged = stageAhead(manifest, client: client)
        let writers = DragItemsBuilder.writers(for: manifest) { item, file in
            TransferFilePromise(item: item, file: file, staged: staged[item.itemID]) { destination, progress, completion in
                let fetch = client.fetchDragItem(dragID: manifest.dragID, itemID: item.itemID, to: destination,
                                                 progress: progress) { result in
                    if case .failure(let error) = result {
                        log.error("fetch failed: \(error.localizedDescription, privacy: .public)")
                        completion(error)
                    } else {
                        completion(nil)
                    }
                }
                return { fetch?.cancel() }
            }
        }
        guard !writers.isEmpty else { return }
        let location = surface.convert(event.locationInWindow, from: nil)
        let items = zip(writers, manifest.items).enumerated().map { index, pair in
            let item = NSDraggingItem(pasteboardWriter: pair.0)
            let offset = CGFloat(min(index, 3)) * 4
            // Finder-sized icons under the pointer.
            item.setDraggingFrame(NSRect(x: location.x - 32 + offset, y: location.y - 32 + offset, width: 64, height: 64),
                                  contents: DragItemsBuilder.image(for: pair.1))
            return item
        }
        let over = !target.handsOverAtEdge && surface.bounds.contains(location)
        hostDrag = HostDrag(connection: connection, manifest: manifest, staged: staged, over: over)
        surface.abandonPress()
        let session = surface.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
        log.notice("took over the host's drag: \(manifest.items.count) items")
        // Past a full desktop's edge, the host's drag waits where it takes no drop.
        if !over {
            connection.client.sendDrag(.away(dragID: manifest.dragID))
            staged.values.forEach { $0.begin() }
        }
    }

    /// Small drags are fetched right away, so apps that want plain files get them.
    private func stageAhead(_ manifest: DragManifest, client: RemoteHostClient) -> [UInt32: StagedCopy] {
        let files = manifest.items.compactMap { item in item.file.map { (item.itemID, $0) } }
        guard !files.isEmpty, files.allSatisfy({ $0.1.size >= 0 }), manifest.fileBytes <= DragStaging.aheadLimit
        else { return [:] }
        DragStaging.removeStale()
        var staged: [UInt32: StagedCopy] = [:]
        for (itemID, file) in files {
            let url = DragStaging.folder("host", dragID: manifest.dragID, itemID: itemID)
                .appendingPathComponent(DragContents.sanitized(file.name))
            let dragID = manifest.dragID
            // Fetched once the drag leaves the host's windows (or an app here asks):
            // a drag that stays on the host copies nothing.
            staged[itemID] = StagedCopy(url: url) { copy in
                client.fetchDragItem(dragID: dragID, itemID: itemID, to: url) { result in
                    copy.finish((try? result.get()) != nil)
                }
            }
        }
        return staged
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Elsewhere the items are copies: they stay on the other Mac.
        context == .withinApplication ? [.copy, .move, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let drag = hostDrag else { return }
        hostDrag = nil
        guard !drag.droppedOnHost, let connection = drag.connection else { return }
        // Taken here (its files are fetched now), or cancelled.
        connection.client.sendDrag(.finish(dragID: drag.manifest.dragID, accepted: !operation.isEmpty))
    }

    // MARK: Over a host's surface

    func dragUpdated(_ info: any NSDraggingInfo, target: any RemoteDragTarget) -> NSDragOperation {
        let point = target.hostPoint(forScreenPoint: Self.screenPoint(info))
        let modifiers = CGEventSource.flagsState(.combinedSessionState).rawValue
        if var drag = hostDrag, info.draggingSource as AnyObject? === self, drag.connection === target.connection {
            drag.over = true
            hostDrag = drag
            target.connection.client.sendDrag(.over(dragID: drag.manifest.dragID, streamID: target.streamID,
                                                     point: point, modifiers: modifiers))
            // Within the host its apps decide; a move stays a move.
            return .move
        }
        guard let offer = offer(for: info, connection: target.connection) else { return [] }
        offer.over = true
        target.connection.client.sendDrag(.over(dragID: offer.dragID, streamID: target.streamID,
                                                 point: point, modifiers: modifiers))
        return .copy
    }

    func dragExited(_ info: (any NSDraggingInfo)?, target: any RemoteDragTarget) {
        if var drag = hostDrag, drag.connection === target.connection, drag.over {
            drag.over = false
            hostDrag = drag
            target.connection.client.sendDrag(.away(dragID: drag.manifest.dragID))
            // Off the host's windows, an app here may take the drop: copy small items now.
            drag.staged.values.forEach { $0.begin() }
            return
        }
        guard let info, let offer = existingOffer(for: info, connection: target.connection), offer.over else { return }
        offer.over = false
        target.connection.client.sendDrag(.away(dragID: offer.dragID))
    }

    func performDrop(_ info: any NSDraggingInfo, target: any RemoteDragTarget) -> Bool {
        let point = target.hostPoint(forScreenPoint: Self.screenPoint(info))
        let client = target.connection.client
        if var drag = hostDrag, info.draggingSource as AnyObject? === self, drag.connection === target.connection {
            drag.droppedOnHost = true
            hostDrag = drag
            client.sendDrag(.drop(dragID: drag.manifest.dragID, streamID: target.streamID, point: point, names: [:]))
            return true
        }
        guard let offer = existingOffer(for: info, connection: target.connection) else { return false }
        offer.dropped = true
        let streamID = target.streamID
        let promised = offer.sources.filter { $0.value == .promise }.keys.sorted()
        guard !promised.isEmpty else {
            client.sendDrag(.drop(dragID: offer.dragID, streamID: streamID, point: point, names: [:]))
            return true
        }
        // Contents another app here promised exist only now: receive them, then drop with their names.
        let receivers = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver] ?? []
        let pairs = Array(zip(promised, receivers))
        var names: [UInt32: String] = [:]
        var remaining = pairs.count
        let finish = { [weak self] in
            client.sendDrag(.drop(dragID: offer.dragID, streamID: streamID, point: point, names: names))
            self?.flushWaiting(offer)
        }
        if pairs.isEmpty { finish() }
        for (itemID, receiver) in pairs {
            let folder = DragStaging.folder("local", dragID: offer.dragID, itemID: itemID)
            var delivered = false
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                MainActor.assumeIsolated {
                    guard !delivered else { return }
                    delivered = true
                    if error == nil {
                        offer.sources[itemID] = .file(url)
                        names[itemID] = url.lastPathComponent
                    }
                    remaining -= 1
                    if remaining == 0 { finish() }
                }
            }
        }
        return true
    }

    /// The drag ended without a drop on this host's surfaces.
    func dragEnded(_ info: any NSDraggingInfo, target: any RemoteDragTarget) {
        guard let offer = existingOffer(for: info, connection: target.connection) else { return }
        finishIfAbandoned(offer)
    }

    private func finishIfAbandoned(_ offer: Offer) {
        guard !offer.dropped, !offer.finished else { return }
        offer.finished = true
        offer.connection?.client.sendDrag(.finish(dragID: offer.dragID, accepted: false))
    }

    private static func screenPoint(_ info: any NSDraggingInfo) -> NSPoint {
        info.draggingDestinationWindow?.convertPoint(toScreen: info.draggingLocation) ?? NSEvent.mouseLocation
    }

    // MARK: Offers

    private func existingOffer(for info: any NSDraggingInfo, connection: HostConnection) -> Offer? {
        offers.last { $0.sequenceNumber == info.draggingSequenceNumber && $0.connection === connection }
    }

    /// The drag's contents, offered to this host the first time it comes over one of its windows.
    private func offer(for info: any NSDraggingInfo, connection: HostConnection) -> Offer? {
        if let offer = existingOffer(for: info, connection: connection) { return offer.finished ? nil : offer }
        let pasteboard = info.draggingPasteboard
        guard DragContents.isTransferable(Set((pasteboard.types ?? []).map(\.rawValue))) else { return nil }
        nextDragID &+= 1
        let read = DragContents.read(DragContents.entries(of: pasteboard), dragID: nextDragID, icons: false)
        guard !read.manifest.items.isEmpty else { return nil }
        let offer = Offer(dragID: nextDragID, sequenceNumber: info.draggingSequenceNumber, connection: connection,
                          sources: read.sources)
        offers.append(offer)
        if offers.count > 8 { offers.removeFirst() }
        connection.client.sendDrag(.offer(read.manifest))
        watchForRelease()
        log.notice("offered a drag to \(connection.hostName, privacy: .public): \(read.manifest.items.count) items")
        return offer
    }

    /// AppKit doesn't always say when a drag ends away from its last
    /// destination; the button coming up says it for sure.
    private func watchForRelease() {
        guard releaseWatch == nil else { return }
        releaseWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                // A drop's own handling runs first; give it a moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    for offer in self.offers { self.finishIfAbandoned(offer) }
                }
                self.releaseWatch?.invalidate()
                self.releaseWatch = nil
            }
        }
    }

    /// The host fetches an item of a drag offered to it. Its file may arrive only at the drop.
    func resolve(connection: HostConnection, dragID: UInt32, itemID: UInt32, reply: @escaping @Sendable (URL?) -> Void) {
        guard let offer = offers.last(where: { $0.dragID == dragID && $0.connection === connection }),
              let source = offer.sources[itemID] else { return reply(nil) }
        switch source {
        case .file(let url):
            reply(url)
        case .promise:
            offer.waiting.append((itemID, reply))
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak offer] in
                guard let offer else { return }
                offer.waiting.removeAll { entry in
                    guard entry.itemID == itemID else { return false }
                    entry.reply(nil)
                    return true
                }
            }
        }
    }

    private func flushWaiting(_ offer: Offer) {
        let waiting = offer.waiting
        offer.waiting = []
        for entry in waiting {
            if case .file(let url) = offer.sources[entry.itemID] { entry.reply(url) } else { entry.reply(nil) }
        }
    }

    func connectionClosed(_ connection: HostConnection) {
        if pending?.connection === connection { pending = nil }
        offers.removeAll { $0.connection === connection || $0.connection == nil }
    }
}
