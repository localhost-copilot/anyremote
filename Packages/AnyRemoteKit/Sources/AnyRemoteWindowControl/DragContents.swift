import AnyRemoteWire
import AppKit
import UniformTypeIdentifiers

/// Where a dragged item's file comes from on the side the drag started.
public enum DragSourceItem: Sendable, Equatable {
    case file(URL)
    /// Another app promised it (Photos, a browser's image, a mail
    /// attachment): it exists only once a drop asks for it.
    case promise
}

/// Turns what is on a drag pasteboard into a `DragManifest`.
///
/// Works on pasteboard items given as their flavors and a reader, so both an
/// `NSPasteboard` (viewer, main thread) and a Pasteboard Manager reference
/// (host, off the main thread) can be read the same way.
public enum DragContents {
    public struct PasteboardEntry {
        public var flavors: [String]
        public var data: (String) -> Data?

        public init(flavors: [String], data: @escaping (String) -> Data?) {
            self.flavors = flavors
            self.data = data
        }
    }

    static let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue
    static let promiseTypes: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-url", "Apple files promise pasteboard type",
    ]
    static let suggestedNameType = "com.apple.pasteboard.promised-suggested-file-name"
    static let promisedNameType = "com.apple.pasteboard.promised-file-name"
    static let promisedContentType = "com.apple.pasteboard.promised-file-content-type"
    /// Inline contents travel up to this size in all.
    public static let maximumInlineBytes = PasteboardBridge.maximumBytes
    /// Icons for the drag image: the first few items get one.
    static let iconCount = 4

    /// True when the pasteboard holds something worth carrying to another Mac.
    public static func isTransferable(_ flavors: Set<String>) -> Bool {
        flavors.contains(fileURLType) || !flavors.isDisjoint(with: promiseTypes)
            || !flavors.isDisjoint(with: PasteboardBridge.sharedTypes.map(\.rawValue) + [NSPasteboard.PasteboardType.tiff.rawValue])
    }

    public static func read(_ entries: [PasteboardEntry], dragID: UInt32,
                            icons: Bool) -> (manifest: DragManifest, sources: [UInt32: DragSourceItem]) {
        var items: [DragItem] = []
        var sources: [UInt32: DragSourceItem] = [:]
        var inlineBytes = 0
        var usedNames = Set<String>()
        for entry in entries {
            let itemID = UInt32(items.count + 1)
            let flavors = Set(entry.flavors)
            if flavors.contains(fileURLType), let data = entry.data(fileURLType),
               let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                var file = describe(url)
                file.name = unique(file.name, in: &usedNames)
                if icons, items.count < iconCount { file.icon = icon(forFile: url) }
                items.append(DragItem(itemID: itemID, file: file))
                sources[itemID] = .file(url)
                continue
            }
            var types = inlineTypes(entry, flavors: flavors, budget: maximumInlineBytes - inlineBytes)
            inlineBytes += types.values.reduce(0) { $0 + $1.count }
            if !flavors.isDisjoint(with: promiseTypes) {
                let typeIdentifier = entry.data(promisedContentType).flatMap { String(data: $0, encoding: .utf8) }
                    ?? UTType.data.identifier
                let suggested = [suggestedNameType, promisedNameType].lazy
                    .compactMap { entry.data($0).flatMap { String(data: $0, encoding: .utf8) } }
                    .first { !$0.isEmpty }
                let type = UTType(typeIdentifier)
                var name = suggested ?? String(localized: "Untitled")
                if suggested == nil, let ext = type?.preferredFilenameExtension { name += "." + ext }
                var file = DragFile(name: unique(sanitized(name), in: &usedNames), typeIdentifier: typeIdentifier,
                                    isDirectory: type?.conforms(to: .directory) ?? false, size: -1)
                if icons, items.count < iconCount { file.icon = icon(forType: type ?? .data) }
                // A link next to promised contents (a browser's image) is kept for apps that want it.
                items.append(DragItem(itemID: itemID, types: types, file: file))
                sources[itemID] = .promise
                continue
            }
            guard !types.isEmpty else { continue }
            if types[NSPasteboard.PasteboardType.string.rawValue] == nil,
               let url = types[NSPasteboard.PasteboardType.URL.rawValue] {
                // Plain text alongside a link, for fields that take only text.
                types[NSPasteboard.PasteboardType.string.rawValue] = url
            }
            items.append(DragItem(itemID: itemID, types: types))
        }
        return (DragManifest(dragID: dragID, items: items), sources)
    }

    /// Entries of an `NSPasteboard` (main thread).
    @MainActor
    public static func entries(of pasteboard: NSPasteboard) -> [PasteboardEntry] {
        (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardEntry(flavors: item.types.map(\.rawValue)) { item.data(forType: .init($0)) }
        }
    }

    /// Entries of a Pasteboard Manager reference (any one thread).
    public static func entries(of board: ClipboardReference) -> [PasteboardEntry] {
        board.items().map { item in
            PasteboardEntry(flavors: item.flavors) { board.data(item, $0) }
        }
    }

    private static func inlineTypes(_ entry: PasteboardEntry, flavors: Set<String>, budget: Int) -> [String: Data] {
        var types: [String: Data] = [:]
        var used = 0
        for type in PasteboardBridge.sharedTypes.map(\.rawValue) where flavors.contains(type) {
            guard let data = entry.data(type), used + data.count <= budget else { continue }
            types[type] = data
            used += data.count
        }
        let tiff = NSPasteboard.PasteboardType.tiff.rawValue
        let png = NSPasteboard.PasteboardType.png.rawValue
        if types[png] == nil, types["public.jpeg"] == nil, flavors.contains(tiff), let data = entry.data(tiff),
           let converted = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]),
           used + converted.count <= budget {
            types[png] = converted
        }
        return types
    }

    static func describe(_ url: URL) -> DragFile {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey, .fileSizeKey])
        let isDirectory = values?.isDirectory ?? false
        let size: Int64 = isDirectory ? directorySize(url) : Int64(values?.fileSize ?? 0)
        return DragFile(name: url.lastPathComponent,
                        typeIdentifier: values?.contentType?.identifier
                            ?? (isDirectory ? UTType.folder.identifier : UTType.data.identifier),
                        isDirectory: isDirectory, size: size)
    }

    /// The bytes inside a folder, or -1 when it is too big to count quickly.
    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                                              options: [], errorHandler: { _, _ in true })
        else { return -1 }
        var total: Int64 = 0
        var count = 0
        let deadline = Date().addingTimeInterval(0.3)
        for case let child as URL in enumerator {
            count += 1
            if count % 256 == 0, Date() > deadline { return -1 }
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func icon(forFile url: URL) -> Data? {
        png(NSWorkspace.shared.icon(forFile: url.path))
    }

    static func icon(forType type: UTType) -> Data? {
        png(NSWorkspace.shared.icon(for: type))
    }

    /// 64 pt icons at 2x.
    static func png(_ image: NSImage, points: CGFloat = 64) -> Data? {
        let pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.current?.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    /// File names from another Mac never reach outside their folder.
    public static func sanitized(_ name: String) -> String {
        var clean = name.replacingOccurrences(of: "/", with: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "." || clean == ".." { clean = String(localized: "Untitled") }
        return String(clean.prefix(255))
    }

    static func unique(_ name: String, in used: inout Set<String>) -> String {
        var candidate = name
        var suffix = 2
        while used.contains(candidate.lowercased()) {
            let ext = (name as NSString).pathExtension
            let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
            candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}

/// A local copy of a dragged item fetched ahead of the drop, so apps that
/// take only file URLs (not promises) get a real file. The copy starts on
/// `begin()`, or at the latest when an app asks for the file.
public final class StagedCopy: @unchecked Sendable {
    public let url: URL
    private let lock = NSCondition()
    // Under lock.
    private var state: Bool? // nil while not done, then success
    private var start: (@Sendable (StagedCopy) -> Void)?

    /// `start` fetches the item to `url` and calls `finish`.
    public init(url: URL, start: @escaping @Sendable (StagedCopy) -> Void) {
        self.url = url
        self.start = start
    }

    /// Starts the copy, once.
    public func begin() {
        lock.lock()
        let start = self.start
        self.start = nil
        lock.unlock()
        start?(self)
    }

    public func finish(_ success: Bool) {
        lock.lock()
        state = success
        lock.broadcast()
        lock.unlock()
    }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == true
    }

    /// Waits for the copy; false if it failed or took too long.
    public func wait(timeout: TimeInterval) -> Bool {
        begin()
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while state == nil {
            if !lock.wait(until: deadline) { return false }
        }
        return state == true
    }
}

/// A dragged item from another Mac, as the local drag offers it: a file
/// promise that fetches the item when an app takes the drop (with Finder
/// showing the copy's progress on the new file), a ready file URL when the
/// item was staged ahead, and any inline contents.
public final class TransferFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    /// Fetches the item to `destination`, reporting bytes; returns a cancel action.
    public typealias Fetch = @Sendable (_ destination: URL, _ progress: @escaping @Sendable (Int64) -> Void,
                                        _ completion: @escaping @Sendable (Error?) -> Void) -> (@Sendable () -> Void)

    private let lock = NSLock()
    private var name: String
    public let item: DragItem
    private let fetch: Fetch
    private let staged: StagedCopy?
    private static let workQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    public init(item: DragItem, file: DragFile, staged: StagedCopy?, fetch: @escaping Fetch) {
        self.item = item
        name = DragContents.sanitized(file.name)
        self.fetch = fetch
        self.staged = staged
        super.init()
        fileType = file.isDirectory ? UTType.folder.identifier : file.typeIdentifier
        delegate = self
    }

    /// The name became known only at the drop.
    public func rename(_ newName: String) {
        lock.lock()
        name = DragContents.sanitized(newName)
        lock.unlock()
    }

    nonisolated override public func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if staged != nil { types.append(.fileURL) }
        types += item.types.keys.map { NSPasteboard.PasteboardType($0) }
        return types
    }

    nonisolated override public func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL, let staged {
            // Apps read the URL while hovering too; a small item arrives in moments.
            guard staged.wait(timeout: 10) else { return nil }
            return (staged.url as NSURL).pasteboardPropertyList(forType: .fileURL)
        }
        if let data = item.types[type.rawValue] { return data }
        return super.pasteboardPropertyList(forType: type)
    }

    nonisolated public func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return name
    }

    nonisolated public func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        return Self.workQueue
    }

    nonisolated public func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                    completionHandler: @escaping (Error?) -> Void) {
        nonisolated(unsafe) let completionHandler = completionHandler
        if let staged, staged.isReady {
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.copyItem(at: staged.url, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
            return
        }
        // Finder shows this on the new file, with a button that cancels it.
        let total = max(item.file?.size ?? -1, 0)
        let progress = Progress(totalUnitCount: total > 0 ? total : -1)
        progress.kind = .file
        progress.fileOperationKind = .copying
        progress.fileURL = url
        progress.isCancellable = true
        progress.publish()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        let cancel = fetch(url, { bytes in
            if total > 0 { progress.completedUnitCount = min(bytes, total) }
        }, { error in
            failure = error
            done.signal()
        })
        progress.cancellationHandler = { cancel() }
        // On the delegate's own queue: waiting here keeps the promise open until the copy is in place.
        done.wait()
        progress.unpublish()
        completionHandler(failure)
    }
}

/// Builds what a local drag offers for items of another Mac's drag.
public enum DragItemsBuilder {
    /// One pasteboard writer per item: a promise for files, plain pasteboard
    /// data for the rest.
    @MainActor
    public static func writers(for manifest: DragManifest,
                               promise: (DragItem, DragFile) -> TransferFilePromise) -> [NSPasteboardWriting] {
        manifest.items.compactMap { item in
            if let file = item.file { return promise(item, file) }
            guard !item.types.isEmpty else { return nil }
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.types { pasteboardItem.setData(data, forType: .init(type)) }
            return pasteboardItem
        }
    }

    /// The item's picture in the drag: its icon from the other Mac, or one for its kind.
    @MainActor
    public static func image(for item: DragItem) -> NSImage {
        if let data = item.file?.icon, let image = NSImage(data: data) { return image }
        if let file = item.file {
            return NSWorkspace.shared.icon(for: file.isDirectory ? .folder : UTType(file.typeIdentifier) ?? .data)
        }
        if let data = item.types[NSPasteboard.PasteboardType.png.rawValue] ?? item.types["public.jpeg"],
           let image = NSImage(data: data) { return image }
        if item.types[NSPasteboard.PasteboardType.URL.rawValue] != nil { return NSWorkspace.shared.icon(for: .url) }
        return NSWorkspace.shared.icon(for: .plainText)
    }
}
