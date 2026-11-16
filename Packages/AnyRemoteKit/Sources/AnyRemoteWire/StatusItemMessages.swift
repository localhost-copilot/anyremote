import CoreGraphics
import Foundation

/// An item on the right of the host's menu bar (a menu bar extra, status
/// item): Wi-Fi, a VPN client, a utility's menu.
public struct HostStatusItem: Codable, Equatable, Sendable {
    /// Names the item while the app runs: its pid and its place among the
    /// app's items.
    public var id: String
    public var applicationName: String
    public var bundleIdentifier: String?
    /// What the item says about itself (its accessibility description or
    /// title), else empty.
    public var title: String
    /// The app's icon, as a PNG. (The menu bar draws its items itself; they
    /// can't be captured one by one.)
    public var image: Data?
    /// Where it is on the host, in global points.
    public var frame: CGRect

    public init(id: String, applicationName: String, bundleIdentifier: String?, title: String, image: Data?,
                frame: CGRect) {
        self.id = id
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.image = image
        self.frame = frame
    }
}
