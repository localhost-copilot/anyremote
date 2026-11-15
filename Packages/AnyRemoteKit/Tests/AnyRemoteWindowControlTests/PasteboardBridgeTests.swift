import AnyRemoteWire
import AppKit
import Testing
@testable import AnyRemoteWindowControl

@MainActor
@Suite struct PasteboardBridgeTests {
    final class Outbox: @unchecked Sendable {
        var sent: [[PasteboardItem]] = []
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        return board
    }

    @Test func copiesTextToTheOtherMac() {
        let here = pasteboard(), there = pasteboard()
        let outbox = Outbox()
        let local = PasteboardBridge(pasteboard: here) { outbox.sent.append($0) }
        let remote = PasteboardBridge(pasteboard: there) { _ in }
        local.poll()
        here.clearContents()
        here.setString("hello from here", forType: .string)
        local.poll()
        #expect(outbox.sent.count == 1)
        remote.apply(outbox.sent[0])
        #expect(there.string(forType: .string) == "hello from here")
    }

    @Test func doesNotEchoWhatItApplied() {
        let board = pasteboard()
        let outbox = Outbox()
        let bridge = PasteboardBridge(pasteboard: board) { outbox.sent.append($0) }
        bridge.poll()
        bridge.apply([PasteboardItem(types: [NSPasteboard.PasteboardType.string.rawValue: Data("x".utf8)])])
        bridge.poll()
        #expect(outbox.sent.isEmpty)
        // Two bridges on one pasteboard (a viewer mirroring this Mac) don't ping-pong either.
        let other = PasteboardBridge(pasteboard: board) { outbox.sent.append($0) }
        other.apply([PasteboardItem(types: [NSPasteboard.PasteboardType.string.rawValue: Data("y".utf8)])])
        bridge.poll()
        #expect(outbox.sent.count == 1)
        other.poll()
        #expect(outbox.sent.count == 1)
    }

    @Test func keepsPasswordsAndFilesLocal() {
        let board = pasteboard()
        let outbox = Outbox()
        let bridge = PasteboardBridge(pasteboard: board) { outbox.sent.append($0) }
        bridge.poll()
        board.clearContents()
        board.setString("secret", forType: .string)
        board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        bridge.poll()
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp") as NSURL])
        bridge.poll()
        #expect(outbox.sent.isEmpty)
    }

    @Test func sendsTIFFAsPNG() throws {
        let board = pasteboard()
        let outbox = Outbox()
        let bridge = PasteboardBridge(pasteboard: board) { outbox.sent.append($0) }
        bridge.poll()
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        board.clearContents()
        board.setData(try #require(image.tiffRepresentation), forType: .tiff)
        bridge.poll()
        let types = try #require(outbox.sent.first?.first?.types)
        #expect(types[NSPasteboard.PasteboardType.png.rawValue] != nil)
        #expect(types[NSPasteboard.PasteboardType.tiff.rawValue] == nil)
    }
}
