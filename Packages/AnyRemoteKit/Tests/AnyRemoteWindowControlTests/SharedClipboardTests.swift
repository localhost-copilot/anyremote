import AnyRemoteWire
import AppKit
import Testing
@testable import AnyRemoteWindowControl

/// Shared clipboards of "different Macs" on pasteboards of their own, linked
/// directly the way a connection links them.
@MainActor
@Suite(.serialized) struct SharedClipboardTests {
    /// Both ends of one connection, and what crossed it.
    final class Link: @unchecked Sendable {
        private let lock = NSLock()
        private var _offers: [PasteboardOffer] = []
        private var _fetches = 0
        var left: SharedClipboard.Peer?
        var right: SharedClipboard.Peer?

        var offers: [PasteboardOffer] { lock.withLock { _offers } }
        var fetches: Int { lock.withLock { _fetches } }

        func carry(_ offer: PasteboardOffer, to peer: SharedClipboard.Peer?) {
            lock.withLock { _offers.append(offer) }
            peer?.receive(offer)
        }

        func fetch(from peer: SharedClipboard.Peer?, _ offerID: UInt32, _ item: Int, _ type: String,
                   _ reply: @escaping @Sendable (Data?) -> Void) {
            lock.withLock { _fetches += 1 }
            guard let peer else { return reply(nil) }
            peer.provide(offerID: offerID, item: item, type: type, reply: reply)
        }
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        return board
    }

    @discardableResult
    private func connect(_ left: SharedClipboard, _ right: SharedClipboard, leftSendsCurrent: Bool = false) -> Link {
        let link = Link()
        link.right = right.join(sendingCurrent: false,
                                send: { [link] in link.carry($0, to: link.left) },
                                fetch: { [link] in link.fetch(from: link.left, $0, $1, $2, $3) })
        link.left = left.join(sendingCurrent: leftSendsCurrent,
                              send: { [link] in link.carry($0, to: link.right) },
                              fetch: { [link] in link.fetch(from: link.right, $0, $1, $2, $3) })
        left.waitUntilIdle()
        return link
    }

    /// Waits for `condition`, which reads pasteboards on the main thread as AppKit does.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func image(side: Int) throws -> Data {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        return try #require(image.tiffRepresentation)
    }

    @Test func textArrivesInline() async {
        let here = pasteboard(), there = pasteboard()
        let local = SharedClipboard(pasteboard: here.name), remote = SharedClipboard(pasteboard: there.name)
        let link = connect(local, remote)
        here.clearContents()
        here.setString("hello from here", forType: .string)
        local.pollNow()
        #expect(await eventually { there.string(forType: .string) == "hello from here" })
        #expect(link.offers.count == 1)
        #expect(link.fetches == 0)
    }

    /// The offer only names a large type; its bytes go by fetch.
    @Test func imagesAndLongTextAreFetched() async throws {
        let here = pasteboard(), there = pasteboard()
        let local = SharedClipboard(pasteboard: here.name), remote = SharedClipboard(pasteboard: there.name)
        let link = connect(local, remote)
        let long = String(repeating: "long text ", count: 10_000)
        here.clearContents()
        let item = NSPasteboardItem()
        item.setString(long, forType: .string)
        item.setData(try image(side: 64), forType: .tiff)
        here.writeObjects([item])
        local.pollNow()
        // Offered at once, but nothing crosses until something pastes.
        #expect(await eventually { there.types?.contains(.png) == true })
        #expect(link.fetches == 0)
        #expect(there.data(forType: .png) != nil)
        #expect(link.fetches == 1)
        #expect(there.string(forType: .string) == long)
        #expect(link.fetches == 2)
        let offered = try #require(link.offers.first?.items.first)
        #expect(offered.inline.isEmpty)
        #expect(Set(offered.fetched.keys) == [NSPasteboard.PasteboardType.string.rawValue,
                                              NSPasteboard.PasteboardType.png.rawValue])
    }

    /// Two Macs connected both ways: each copy crosses once and stops.
    @Test func copiesDoNotComeBack() async {
        let one = pasteboard(), two = pasteboard()
        let first = SharedClipboard(pasteboard: one.name), second = SharedClipboard(pasteboard: two.name)
        let forward = connect(first, second), backward = connect(second, first)
        one.clearContents()
        one.setString("only once", forType: .string)
        first.pollNow()
        #expect(await eventually { two.string(forType: .string) == "only once" })
        try? await Task.sleep(for: .milliseconds(100))
        let settled = forward.offers.count + backward.offers.count
        second.pollNow()
        first.pollNow()
        try? await Task.sleep(for: .milliseconds(100))
        // `first` offered it on both connections; `second` took the first to
        // arrive and passed it back on the other at most, where it stopped.
        #expect(settled <= 3)
        #expect(forward.offers.count + backward.offers.count == settled)
        #expect((forward.offers + backward.offers).allSatisfy { $0.origin == first.origin })
        #expect(one.string(forType: .string) == "only once")
    }

    /// A Mac between two others passes copies on, and serves fetches from the first.
    @Test func relaysThroughAMiddleMac() async throws {
        let a = pasteboard(), b = pasteboard(), c = pasteboard()
        let first = SharedClipboard(pasteboard: a.name), middle = SharedClipboard(pasteboard: b.name),
            last = SharedClipboard(pasteboard: c.name)
        connect(first, middle)
        connect(middle, last)
        a.clearContents()
        a.setData(try image(side: 32), forType: .tiff)
        first.pollNow()
        #expect(await eventually { c.types?.contains(.png) == true })
        #expect(c.data(forType: .png) != nil)
        #expect(b.data(forType: .png) != nil)
    }

    @Test func sendsWhatIsThereWhenAsked() async {
        let here = pasteboard(), there = pasteboard()
        here.setString("copied before connecting", forType: .string)
        let local = SharedClipboard(pasteboard: here.name), remote = SharedClipboard(pasteboard: there.name)
        connect(local, remote, leftSendsCurrent: true)
        #expect(await eventually { there.string(forType: .string) == "copied before connecting" })
    }

    @Test func keepsPasswordsAndFilesLocal() {
        let board = pasteboard(), other = pasteboard()
        let local = SharedClipboard(pasteboard: board.name), remote = SharedClipboard(pasteboard: other.name)
        let link = connect(local, remote)
        board.clearContents()
        board.setString("secret", forType: .string)
        board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        local.pollNow()
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp") as NSURL])
        local.pollNow()
        #expect(link.offers.isEmpty)
    }

    /// A fetch of an offer that's been replaced fails rather than serve the newer copy.
    @Test func staleFetchesFail() async throws {
        let board = pasteboard(), other = pasteboard()
        let local = SharedClipboard(pasteboard: board.name), remote = SharedClipboard(pasteboard: other.name)
        let link = connect(local, remote)
        board.clearContents()
        board.setData(try image(side: 16), forType: .tiff)
        local.pollNow()
        let old = try #require(link.offers.first)
        board.clearContents()
        board.setData(try image(side: 24), forType: .tiff)
        local.pollNow()
        let peer = try #require(link.left)
        let data: Data? = await withCheckedContinuation { continuation in
            peer.provide(offerID: old.offerID, item: 0, type: NSPasteboard.PasteboardType.png.rawValue) {
                continuation.resume(returning: $0)
            }
        }
        #expect(data == nil)
    }

    /// A paste whose Mac has gone fails at once instead of waiting.
    @Test func pasteFailsWhenTheOtherMacIsGone() async throws {
        let here = pasteboard(), there = pasteboard()
        let local = SharedClipboard(pasteboard: here.name), remote = SharedClipboard(pasteboard: there.name)
        let link = connect(local, remote)
        here.clearContents()
        here.setData(try image(side: 16), forType: .tiff)
        local.pollNow()
        #expect(await eventually { there.types?.contains(.png) == true })
        link.left?.leave()
        local.waitUntilIdle()
        let started = Date()
        #expect(there.data(forType: .png) == nil)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// The pasteboard changing back to what was written here (Universal
    /// Clipboard, a viewer of this Mac) isn't a new copy.
    @Test func sameContentsAgainAreNotACopy() async {
        let here = pasteboard(), there = pasteboard()
        let local = SharedClipboard(pasteboard: here.name), remote = SharedClipboard(pasteboard: there.name)
        let link = connect(local, remote)
        here.clearContents()
        here.setString("round trip", forType: .string)
        local.pollNow()
        #expect(await eventually { there.string(forType: .string) == "round trip" })
        there.clearContents()
        there.setString("round trip", forType: .string)
        remote.pollNow()
        here.clearContents()
        here.setString("round trip", forType: .string)
        local.pollNow()
        remote.waitUntilIdle()
        #expect(link.offers.count == 1)
    }

    /// AppKit uses the NSPasteboard object on the main thread while the
    /// clipboard reads on its queue; sharing that object between threads crashed.
    @Test func readsWhileTheMainThreadUsesThePasteboard() async throws {
        let board = pasteboard()
        let reference = try #require(ClipboardReference(name: board.name))
        let reader = Task.detached {
            var reads = 0
            for _ in 0..<2000 where ClipboardReference.queue.sync(execute: { SharedClipboard.read(reference) }) != nil {
                reads += 1
            }
            return reads
        }
        for index in 0..<2000 {
            board.clearContents()
            board.setString("copy \(index)", forType: .string)
            _ = board.pasteboardItems?.first?.string(forType: .string)
        }
        #expect(await reader.value >= 0)
    }
}
