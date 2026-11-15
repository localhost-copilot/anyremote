import AnyRemoteWire
import Foundation

/// The apps opened on each host from this Mac, most recent first, so the
/// menu bar panel can offer them again without a search. Keyed by host ID
/// and app path; paths are what `launchApplication` takes.
enum RecentApplications {
    private static let key = "recentApplications"
    private static let limit = 8

    static func paths(host: String) -> [String] {
        (UserDefaults.standard.dictionary(forKey: key)?[host] as? [String]) ?? []
    }

    static func record(_ path: String, host: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        var paths = (all[host] as? [String]) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        all[host] = Array(paths.prefix(limit))
        UserDefaults.standard.set(all, forKey: key)
    }

    /// The apps of `listing` that were opened recently, in that order. Apps
    /// that have since been deleted on the host drop out.
    static func applications(host: String, in listing: [HostApplication]) -> [HostApplication] {
        let byPath = Dictionary(listing.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return paths(host: host).compactMap { byPath[$0] }
    }
}
