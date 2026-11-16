import Testing
@testable import AnyRemoteWindowControl

@Suite struct NotificationBannerTests {
    @Test func applicationNameComesBeforeTheTexts() {
        // As Notification Center on macOS 27 describes a banner.
        #expect(NotificationBannerReader.applicationName(
            description: "Script Editor, AnyRemote probe, Sub, Body text 123",
            title: "AnyRemote probe", subtitle: "Sub", body: "Body text 123") == "Script Editor")
        // Commas inside the app's name or the texts.
        #expect(NotificationBannerReader.applicationName(
            description: "Foo, Inc. Tool, Done, Copied 3 files, 2 folders",
            title: "Done", subtitle: "", body: "Copied 3 files, 2 folders") == "Foo, Inc. Tool")
    }

    @Test func otherwiseTheFirstPartNamesTheApp() {
        #expect(NotificationBannerReader.applicationName(
            description: "Messages, Anna, sent a photo", title: "Anna", subtitle: "", body: "Photo") == "Messages")
        #expect(NotificationBannerReader.applicationName(
            description: "Messages", title: "Anna", subtitle: "", body: "Hi") == nil)
        #expect(NotificationBannerReader.applicationName(description: "", title: "", subtitle: "", body: "") == nil)
    }
}
