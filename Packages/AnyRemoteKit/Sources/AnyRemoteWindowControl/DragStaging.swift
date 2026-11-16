import Foundation

/// Folders for dragged items fetched ahead of a drop, and for contents
/// another app promised. Each drag gets its own; leftovers older than a day
/// go when the next drag starts.
public enum DragStaging {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AnyRemote Drops", isDirectory: true)
    }

    /// A new, empty folder for one drag's item.
    public static func folder(_ label: String, dragID: UInt32, itemID: UInt32) -> URL {
        let url = root.appendingPathComponent("\(label)-\(dragID)", isDirectory: true)
            .appendingPathComponent("\(itemID)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func removeStale() {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fileManager.removeItem(at: folder) }
        }
    }

    /// Small drags are copied ahead so apps that want plain files get them.
    public static let aheadLimit: Int64 = 64 << 20
}
