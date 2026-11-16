import Foundation
import Testing
@testable import AnyRemoteWire

@Suite struct NoticeMessageTests {
    @Test func noticeMessagesRoundTrip() throws {
        let notification = HostNotification(
            id: "5397D86B-8F8E-4200-91DE-925F8361E631", applicationName: "Mail", bundleIdentifier: "com.apple.mail",
            applicationPath: "/System/Applications/Mail.app", title: "Anna", subtitle: "Lunch?",
            body: "See you at noon, 你好", icon: Data([0x89, 0x50, 0x4E, 0x47]))
        let messages: [ControlMessage] = [
            .notices(NoticeSubscription(notifications: true, badges: false)),
            .hostNotification(notification),
            .badges([HostBadge(applicationName: "Mail", bundleIdentifier: "com.apple.mail", label: "3"),
                     HostBadge(applicationName: "Tool", bundleIdentifier: nil, label: "!")]),
            .badges([]),
            .openNotification(id: notification.id, applicationPath: nil),
        ]
        for message in messages {
            let data = try ControlCoding.encode(message)
            #expect(try ControlCoding.decode(ControlMessage.self, from: data) == message)
        }
    }

    @Test func emptySubscriptionMeansStop() {
        #expect(NoticeSubscription(notifications: false, badges: false).isEmpty)
        #expect(!NoticeSubscription(notifications: false, badges: true).isEmpty)
    }
}
