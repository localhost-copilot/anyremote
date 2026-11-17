import CoreGraphics
import Foundation

/// What a drag carries between Macs, sent when it starts.
///
/// Inline contents (text, links, small images) travel in the manifest; files
/// and folders are listed by name and fetched over the transfer connection
/// when something on the other side asks for them. Files are named by
/// `(dragID, itemID)` only, never by path, so a peer can fetch only what was
/// actually dragged.
public struct DragManifest: Codable, Equatable, Sendable {
    /// Chosen by the side the drag started on.
    public var dragID: UInt32
    public var items: [DragItem]

    public init(dragID: UInt32, items: [DragItem]) {
        self.dragID = dragID
        self.items = items
    }

    /// Bytes of all files (folders counted by their contents), when known.
    public var fileBytes: Int64 {
        items.reduce(0) { $0 + max(0, $1.file?.size ?? 0) }
    }

    public var hasFiles: Bool { items.contains { $0.file != nil } }
}

public struct DragItem: Codable, Equatable, Sendable {
    public var itemID: UInt32
    /// Pasteboard data by type identifier (text, URL, image), for items
    /// without a file, or alongside one.
    public var types: [String: Data]
    public var file: DragFile?

    public init(itemID: UInt32, types: [String: Data] = [:], file: DragFile? = nil) {
        self.itemID = itemID
        self.types = types
        self.file = file
    }
}

public struct DragFile: Codable, Equatable, Sendable {
    /// The file or folder name, as it will be created on the other side.
    public var name: String
    /// Uniform type identifier ("public.folder", "public.png").
    public var typeIdentifier: String
    public var isDirectory: Bool
    /// Bytes, or -1 when unknown (contents an app only promises).
    public var size: Int64
    /// A small PNG of its icon (host → viewer, for the drag image).
    public var icon: Data?

    public init(name: String, typeIdentifier: String, isDirectory: Bool, size: Int64, icon: Data? = nil) {
        self.name = name
        self.typeIdentifier = typeIdentifier
        self.isDirectory = isDirectory
        self.size = size
        self.icon = icon
    }
}

/// Viewer → host: where the viewer's drag is, over the host's surfaces.
///
/// The drag the user sees is always the viewer's own; the host repeats it
/// with an invisible drag so its apps react natively. `dragID` names either
/// a drag the host started (`hostDragBegan`) or one the viewer offered.
public enum DragEvent: Codable, Equatable, Sendable {
    /// The viewer's drag with these contents may come over the host's
    /// surfaces. Sent once per drag, before its first `over`.
    case offer(DragManifest)
    /// Over a stream at `point` (stream points from its top-left corner),
    /// with these modifier flags (CGEventFlags).
    case over(dragID: UInt32, streamID: UInt16, point: CGPoint, modifiers: UInt64)
    /// Over none of the host's surfaces: the host's drag waits where nothing takes a drop.
    case away(dragID: UInt32)
    /// Released over a stream. `names` renames files whose names became
    /// known only at the drop (contents another app had promised).
    case drop(dragID: UInt32, streamID: UInt16, point: CGPoint, names: [UInt32: String])
    /// The drag ended elsewhere. `accepted`: something on the viewer took
    /// it (and may now fetch its files); otherwise it was cancelled.
    case finish(dragID: UInt32, accepted: Bool)
}

/// Frames of the transfer connection (a second sealed connection, so files,
/// images and clipboard contents never hold up input). Contents flow as raw `TransferChunk`s between these.
public enum TransferMessage: Codable, Equatable, Sendable {
    /// The first message: joins the session that sent `transferToken`.
    case attach(sessionID: UInt32, token: Data)
    /// Asks for one dragged item. The reply is chunks of a `ditto` archive
    /// holding it, then `ended`.
    case fetch(requestID: UInt32, dragID: UInt32, itemID: UInt32)
    /// The requester has written this many more bytes: the sender may send as many.
    case credit(requestID: UInt32, bytes: Int64)
    /// All chunks are sent (`error`: the item could not be sent).
    case ended(requestID: UInt32, error: String?)
    case cancel(requestID: UInt32)
    /// Asks for these images. The reply is one chunk per image the host has
    /// (an `ImageChunk`), within the requester's credit, then `ended`.
    case images(requestID: UInt32, [HostImage])
    /// Asks for one type of an item the other Mac's clipboard offered
    /// (`PasteboardOffer`). The reply is its bytes in chunks, within the
    /// requester's credit, then `ended` (with an error when the clipboard
    /// has changed since).
    case pasteboard(requestID: UInt32, offerID: UInt32, item: UInt16, type: String)
}

/// An image a viewer fetches from the host for its lists.
public enum HostImage: Codable, Hashable, Sendable {
    /// A 96 px PNG of the app at this path.
    case applicationIcon(path: String)
    /// A 128 px PNG of the running app with this bundle identifier.
    case windowIcon(bundleIdentifier: String)
    /// A JPEG of the window now, longest side at most `maximumPixels`.
    case thumbnail(windowID: UInt32, maximumPixels: Int)
}

/// The bytes of one image chunk: `u16` index into the request's images,
/// then the image file's own bytes (no Base64).
public enum ImageChunk {
    public static func encode(index: Int, image: Data) -> Data {
        var writer = ByteWriter(capacity: 2 + image.count)
        writer.u16(UInt16(index))
        writer.bytes(image)
        return writer.data
    }

    public static func decode(_ bytes: Data) throws -> (index: Int, image: Data) {
        guard bytes.count >= 2 else { throw WireError.truncated }
        var reader = ByteReader(bytes.prefix(2))
        let index = Int(try reader.u16())
        return (index, Data(bytes.dropFirst(2)))
    }
}

/// A raw piece of a transfer: `u32 requestID` followed by the bytes.
public enum TransferChunk {
    public static func encode(requestID: UInt32, bytes: Data) -> Data {
        var writer = ByteWriter(capacity: 4 + bytes.count)
        writer.u32(requestID)
        writer.bytes(bytes)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> (requestID: UInt32, bytes: Data) {
        guard data.count >= 4 else { throw WireError.truncated }
        var reader = ByteReader(data.prefix(4))
        let requestID = try reader.u32()
        return (requestID, Data(data.dropFirst(4)))
    }
}
