import Foundation

/// A notification that appeared on the host, as its banner showed it.
public struct HostNotification: Codable, Equatable, Sendable {
    /// The banner's identifier on the host, to open it from the viewer.
    public var id: String
    /// The app's name as Notification Center shows it.
    public var applicationName: String
    public var bundleIdentifier: String?
    /// The app's bundle on the host, to open it when the banner is gone.
    public var applicationPath: String?
    public var title: String
    public var subtitle: String
    public var body: String
    /// The app's icon as a PNG, sent the first time this app notifies in a
    /// session; the viewer keeps it.
    public var icon: Data?

    public init(id: String, applicationName: String, bundleIdentifier: String?, applicationPath: String?,
                title: String, subtitle: String, body: String, icon: Data? = nil) {
        self.id = id
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.icon = icon
    }
}

/// The badge an app shows on its Dock icon on the host ("3", "!").
public struct HostBadge: Codable, Equatable, Hashable, Sendable {
    public var applicationName: String
    public var bundleIdentifier: String?
    public var label: String

    public init(applicationName: String, bundleIdentifier: String?, label: String) {
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.label = label
    }
}

/// What the viewer wants to hear about the host's apps.
public struct NoticeSubscription: Codable, Equatable, Sendable {
    /// New notifications, as `ControlMessage.hostNotification`.
    public var notifications: Bool
    /// Dock badges, as `ControlMessage.badges`.
    public var badges: Bool

    public init(notifications: Bool, badges: Bool) {
        self.notifications = notifications
        self.badges = badges
    }

    public var isEmpty: Bool { !notifications && !badges }
}
