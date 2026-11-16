// Drag and drop through the real host agent and viewer client over
// 127.0.0.1. The viewer side is played by this tool (it sends what the
// app's drag would), so one Mac can check the host's half end to end:
//
//   anyremote-bench --drag-test <scenario> --file <path> [--from x,y] [--to x,y]
//
// Points are global (top-left) points on the main display, which the tool
// opens as a full desktop. Scenarios:
//   offer     a drag from the viewer carrying --file, dropped at --to
//   take      a drag started on the host at --from (press and move there),
//             taken by the viewer: its first item is fetched next to --file
//   take-cancel  the same, then cancelled on the viewer
//   within    a drag started at --from, dropped on the host at --to
//
// It moves this Mac's pointer: use test windows (scratch apps) as sources
// and targets, never real documents.

import AnyRemoteClient
import AnyRemoteHost
import AnyRemoteNetwork
import AnyRemoteWire
import AppKit
import Network

func runDragBench(scenario: String, file: String?, from: CGPoint, to: CGPoint) async throws {
    setenv("ANYREMOTE_HOME", NSTemporaryDirectory() + "anyremote-bench-drag", 1)
    let store = HostSettingsStore()
    let host = HostService(settings: store, options: .init(port: 0, advertise: false))
    try host.start()
    defer { host.stop() }
    while host.port == nil || host.port == 0 { try await Task.sleep(for: .milliseconds(20)) }
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: host.port!)!)
    let client = RemoteHostClient(endpoint: endpoint, code: store.settings.code!, viewerName: "drag-bench")

    let events = AsyncStream<RemoteHostClient.Event>.makeStream()
    let drags = AsyncStream<DragManifest>.makeStream()
    client.onEvent = { event in
        if case .hostDragBegan(_, let manifest) = event { drags.continuation.yield(manifest) }
        events.continuation.yield(event)
    }
    let fileURL = file.map { URL(fileURLWithPath: $0) }
    client.dragResolver = { _, itemID, reply in reply(itemID == 1 ? fileURL : nil) }
    _ = try await client.connect()
    let displayID = CGMainDisplayID()
    client.openDisplay(displayID)
    var streamID: UInt16?
    var iterator = events.stream.makeAsyncIterator()
    while streamID == nil, let event = await iterator.next() {
        if case .streamStarted(let description) = event, description.role == .display { streamID = description.streamID }
    }
    guard let streamID else { throw ConnectionError.closed }
    // The transfer connection joins right after the welcome.
    try await Task.sleep(for: .milliseconds(300))
    print("desktop stream \(streamID) open")

    func over(_ dragID: UInt32, _ point: CGPoint) {
        client.sendDrag(.over(dragID: dragID, streamID: streamID, point: point, modifiers: 0))
    }
    func glide(_ dragID: UInt32, from a: CGPoint, to b: CGPoint) async throws {
        for step in 1...20 {
            let t = CGFloat(step) / 20
            over(dragID, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try await Task.sleep(for: .milliseconds(16))
        }
    }
    let started = Date()
    func elapsed() -> String { String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000) }

    switch scenario {
    case "offer":
        guard let fileURL else { print("--file needed"); exit(2) }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? -1
        let manifest = DragManifest(dragID: 0x8000_0001, items: [DragItem(itemID: 1, file: DragFile(
            name: fileURL.lastPathComponent, typeIdentifier: "public.data", isDirectory: false, size: size ?? -1))])
        client.sendDrag(.offer(manifest))
        over(manifest.dragID, from)
        try await Task.sleep(for: .milliseconds(200))
        try await glide(manifest.dragID, from: from, to: to)
        try await Task.sleep(for: .milliseconds(200))
        client.sendDrag(.drop(dragID: manifest.dragID, streamID: streamID, point: to, names: [:]))
        print("dropped at \(to) after \(elapsed())")
        try await Task.sleep(for: .seconds(3))

    case "take", "take-cancel", "within":
        client.send(.input(streamID: streamID, .mouseDown(point: from, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0)))
        var manifest: DragManifest?
        let watcher = Task { () -> DragManifest? in
            var drags = drags.stream.makeAsyncIterator()
            return await drags.next()
        }
        for step in 1...30 {
            client.send(.input(streamID: streamID, .mouseMove(point: CGPoint(x: from.x + CGFloat(step) * 3, y: from.y),
                                                                pressedButtons: 1, modifiers: 0)))
            try await Task.sleep(for: .milliseconds(16))
        }
        let timeout = Task { try await Task.sleep(for: .seconds(2)); watcher.cancel() }
        manifest = await watcher.value
        timeout.cancel()
        guard let manifest else {
            print("FAIL: no hostDragBegan")
            client.send(.input(streamID: streamID, .mouseUp(point: from, button: .left, buttonNumber: 0, clickCount: 1, modifiers: 0)))
            exit(1)
        }
        print("hostDragBegan after \(elapsed()): \(manifest.items.map { "\($0.itemID): \($0.file.map { "\($0.name) \($0.size) B icon \($0.icon?.count ?? 0) B" } ?? $0.types.keys.joined(separator: ","))" })")
        switch scenario {
        case "within":
            try await glide(manifest.dragID, from: CGPoint(x: from.x + 90, y: from.y), to: to)
            try await Task.sleep(for: .milliseconds(200))
            client.sendDrag(.drop(dragID: manifest.dragID, streamID: streamID, point: to, names: [:]))
            print("dropped on the host at \(to)")
        case "take-cancel":
            client.sendDrag(.away(dragID: manifest.dragID))
            try await Task.sleep(for: .milliseconds(200))
            client.sendDrag(.finish(dragID: manifest.dragID, accepted: false))
            print("cancelled")
        default:
            // As when this Mac's drag leaves the host's window and an app here takes the drop.
            client.sendDrag(.away(dragID: manifest.dragID))
            try await Task.sleep(for: .milliseconds(200))
            client.sendDrag(.finish(dragID: manifest.dragID, accepted: true))
            guard let item = manifest.items.first, let name = item.file?.name else { break }
            let folder = URL(fileURLWithPath: file ?? NSTemporaryDirectory()).deletingLastPathComponent()
            let destination = folder.appendingPathComponent("fetched-" + name)
            let fetchStart = Date()
            let result: Result<URL, Error> = await withCheckedContinuation { continuation in
                client.fetchDragItem(dragID: manifest.dragID, itemID: item.itemID, to: destination) {
                    continuation.resume(returning: $0)
                }
            }
            switch result {
            case .success(let url):
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
                print(String(format: "fetched %@ (%lld B) in %.0f ms", url.path, size ?? -1,
                             Date().timeIntervalSince(fetchStart) * 1000))
            case .failure(let error):
                print("FAIL: fetch: \(error.localizedDescription)")
            }
        }
        try await Task.sleep(for: .seconds(2))

    default:
        print("unknown scenario \(scenario)")
        exit(2)
    }
    client.disconnect()
}
