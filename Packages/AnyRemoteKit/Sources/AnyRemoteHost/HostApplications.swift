import AnyRemoteWire
import AppKit

/// The host's applications, for opening one from the viewer.
@MainActor
enum HostApplications {
    private static let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                                  "/System/Applications/Utilities"]

    /// Apps in the usual folders (one level of subfolders, for suites such as
    /// "Microsoft Office") plus regular apps running from elsewhere, by name.
    static func list() -> [HostApplication] {
        let fileManager = FileManager.default
        let ownPath = Bundle.main.bundleURL.standardizedFileURL.path
        // Finder lives in CoreServices, with much that isn't an app to open.
        var urls = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        var folders = folders.map { URL(fileURLWithPath: $0).standardizedFileURL }
        folders.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        for folder in folders {
            guard let entries = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                if entry.pathExtension == "app" {
                    urls.append(entry)
                } else if folder.lastPathComponent == "Applications",
                          (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let inner = (try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles])) ?? []
                    urls += inner.filter { $0.pathExtension == "app" }
                }
            }
        }

        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let runningPaths = Set(running.compactMap { $0.bundleURL?.standardizedFileURL.path })
        for app in running {
            if let url = app.bundleURL { urls.append(url) }
        }

        var seen: Set<String> = []
        var result: [HostApplication] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard path != ownPath, seen.insert(path).inserted else { continue }
            let bundle = Bundle(url: url)
            // Skip agents and helpers that have no UI to show.
            if bundle?.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
                || bundle?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true { continue }
            let name = fileManager.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            result.append(HostApplication(path: path, name: name, bundleIdentifier: bundle?.bundleIdentifier,
                                          isRunning: runningPaths.contains(path),
                                          category: bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A 128 px PNG of the app's icon, sharp at the Apps grid's 64 pt on Retina.
    static func icon(path: String) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 128, height: 128)
        var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
        guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return HostWindows.encode(image, type: .png)
    }
}
