import AnyRemoteNetwork
import AnyRemoteWire
import Foundation
import Network
import Testing

/// Dragged items over a real sealed connection pair on 127.0.0.1.
@Suite(.serialized, .timeLimit(.minutes(2))) struct FileTransferTests {
    final class Pair: @unchecked Sendable {
        let listener: ControlListener
        var host: FileTransferChannel?
        var viewer: FileTransferChannel?

        init() throws {
            let code = PairingCredential.generate()
            let hostQueue = DispatchQueue(label: "test.host")
            listener = try ControlListener(port: 0, serviceName: nil, hostID: "test", queue: hostQueue)
            let ready = DispatchSemaphore(value: 0)
            let secured = DispatchSemaphore(value: 0)
            listener.onStateChange = { if case .ready = $0 { ready.signal() } }
            listener.onConnection = { [self] connection in
                let control = ControlConnection(connection: connection,
                                                role: .host(credentials: { $0 == code.id ? .found(code) : .unknown },
                                                            hostID: "test", hostName: "Host", sessionID: 7),
                                                queue: hostQueue)
                control.onSecured = { _ in secured.signal() }
                host = FileTransferChannel(connection: control)
                control.start()
            }
            listener.start()
            // A listener that never gets ready (a CI machine refusing local
            // connections) fails the test instead of hanging the run.
            guard ready.wait(timeout: .now() + 10) == .success else { throw ListenerNotReady() }
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: listener.port!)!)
            let control = ControlConnection(connection: NWConnection(to: endpoint, using: ControlConnection.parameters(bulk: true)),
                                            role: .viewer(credential: code, viewerName: "Viewer"),
                                            queue: DispatchQueue(label: "test.viewer"))
            viewer = FileTransferChannel(connection: control)
            control.onSecured = { [weak control] _ in control?.send(.transfer(.credit(requestID: 0, bytes: 0))) }
            control.start()
            // The host side is secured once the viewer's first sealed frame opens.
            #expect(secured.wait(timeout: .now() + 5) == .success)
        }

        func close() {
            viewer?.close()
            host?.close()
            listener.cancel()
        }
    }

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anyremote-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func fetch(_ channel: FileTransferChannel, itemID: UInt32, to url: URL) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            channel.fetch(dragID: 1, itemID: itemID, to: url) { continuation.resume(returning: $0) }
        }
    }

    @Test func folderArrivesWithItsContentsAndAttributes() async throws {
        let pair = try Pair()
        defer { pair.close() }
        let source = try Self.scratch()
        let folder = source.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("sub/a.txt"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path,
                                                   withDestinationPath: "sub/a.txt")
        let big = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try big.write(to: folder.appendingPathComponent("big.bin"))
        let tagged = folder.appendingPathComponent("sub/a.txt")
        _ = tagged.withUnsafeFileSystemRepresentation { path in
            setxattr(path, "com.anyremote.test", "v", 1, 0, 0)
        }
        pair.viewer?.resolve = { _, itemID, reply in reply(itemID == 1 ? folder : nil) }

        let destination = try Self.scratch().appendingPathComponent("Copied Project")
        let result = await Self.fetch(pair.host!, itemID: 1, to: destination)
        let url = try result.get()
        #expect(url == destination)
        #expect(try Data(contentsOf: url.appendingPathComponent("sub/a.txt")) == Data("hello".utf8))
        #expect(try Data(contentsOf: url.appendingPathComponent("big.bin")) == big)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.appendingPathComponent("link").path) == "sub/a.txt")
        var value = [UInt8](repeating: 0, count: 4)
        let length = url.appendingPathComponent("sub/a.txt").withUnsafeFileSystemRepresentation { path in
            getxattr(path, "com.anyremote.test", &value, value.count, 0, 0)
        }
        #expect(length == 1)
    }

    @Test func fileGetsTheDestinationName() async throws {
        let pair = try Pair()
        defer { pair.close() }
        let file = try Self.scratch().appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: file)
        // Both ways: here the viewer fetches from the host.
        pair.host?.resolve = { _, _, reply in reply(file) }
        let destination = try Self.scratch().appendingPathComponent("photo 2.png")
        let url = try await Self.fetch(pair.viewer!, itemID: 5, to: destination).get()
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    @Test func missingItemFails() async throws {
        let pair = try Pair()
        defer { pair.close() }
        pair.viewer?.resolve = { _, _, reply in reply(nil) }
        let result = await Self.fetch(pair.host!, itemID: 9, to: try Self.scratch().appendingPathComponent("x"))
        #expect(throws: (any Error).self) { try result.get() }
    }

    @Test func cancelledFetchLeavesNothing() async throws {
        let pair = try Pair()
        defer { pair.close() }
        let file = try Self.scratch().appendingPathComponent("large.bin")
        try Data(count: 64 << 20).write(to: file)
        // Resolved late, so the cancel lands first.
        pair.viewer?.resolve = { _, _, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { reply(file) }
        }
        let destination = try Self.scratch().appendingPathComponent("large.bin")
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            let fetch = pair.host!.fetch(dragID: 1, itemID: 1, to: destination) { continuation.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { fetch.cancel() }
        }
        #expect(throws: (any Error).self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func imagesArriveWithinTheCreditWindow() async throws {
        let pair = try Pair()
        defer { pair.close() }
        // Together several times the window, so the host must wait for credit.
        let images = (0..<12).map { HostImage.applicationIcon(path: "/Applications/App\($0).app") }
            + [.windowIcon(bundleIdentifier: "missing")]
        let image: @Sendable (Int) -> Data = { index in Data((0..<(300 << 10)).map { UInt8(truncatingIfNeeded: $0 &+ index) }) }
        pair.host?.provideImages = { requested, reply in
            DispatchQueue.global().async {
                reply(requested.enumerated().map { index, item in
                    if case .windowIcon = item { return nil }
                    return image(index)
                })
            }
        }
        let received: [HostImage: Data] = await withCheckedContinuation { continuation in
            pair.viewer!.fetchImages(images) { continuation.resume(returning: $0) }
        }
        #expect(received.count == 12)
        for (index, item) in images.prefix(12).enumerated() { #expect(received[item] == image(index)) }
        #expect(received[.windowIcon(bundleIdentifier: "missing")] == nil)
    }

    /// Clipboard contents go both ways, in chunks within the credit window.
    @Test func clipboardTypesArriveEitherWay() async throws {
        let pair = try Pair()
        defer { pair.close() }
        // Several times the window, so the sender must wait for credit.
        let big = Data((0..<(13 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        pair.viewer?.providePasteboard = { offerID, item, type, reply in
            DispatchQueue.global().async {
                reply(offerID == 3 && item == 1 && type == "public.png" ? big : nil)
            }
        }
        let fetch: @Sendable (FileTransferChannel, UInt32, String) async -> Data? = { channel, offerID, type in
            await withCheckedContinuation { continuation in
                channel.fetchPasteboard(offerID: offerID, item: 1, type: type) { continuation.resume(returning: $0) }
            }
        }
        #expect(await fetch(pair.host!, 3, "public.png") == big)
        #expect(await fetch(pair.host!, 2, "public.png") == nil)
        // The host has no provider: nothing to fetch, and no hang.
        #expect(await fetch(pair.viewer!, 3, "public.png") == nil)
    }

    @Test func imagesWithoutAProviderEndEmpty() async throws {
        let pair = try Pair()
        defer { pair.close() }
        let received: [HostImage: Data] = await withCheckedContinuation { continuation in
            pair.viewer!.fetchImages([.thumbnail(windowID: 1, maximumPixels: 480)]) { continuation.resume(returning: $0) }
        }
        #expect(received.isEmpty)
    }
}
