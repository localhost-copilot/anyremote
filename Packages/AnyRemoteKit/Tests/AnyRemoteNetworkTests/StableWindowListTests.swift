import AnyRemoteClient
import AnyRemoteWire
import CoreGraphics
import Testing

struct StableWindowListTests {
    func window(_ id: UInt32, _ app: String, width: CGFloat = 800, height: CGFloat = 600) -> WindowSummary {
        WindowSummary(windowID: id, pid: 1, applicationName: app, bundleIdentifier: "com.example.\(app)",
                      title: "\(id)", frame: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @Test func aWindowComingForwardOnTheHostKeepsItsPlace() {
        var list = StableWindowList([window(1, "A"), window(2, "B"), window(3, "C")])
        list.update(with: [window(3, "C"), window(1, "A"), window(2, "B")])
        #expect(list.windows.map(\.windowID) == [1, 2, 3])
    }

    @Test func closedWindowsDropOut() {
        var list = StableWindowList([window(1, "A"), window(2, "B"), window(3, "C")])
        list.update(with: [window(3, "C"), window(1, "A")])
        #expect(list.windows.map(\.windowID) == [1, 3])
    }

    @Test func aNewWindowGoesInFrontOfItsAppsOthers() {
        var list = StableWindowList([window(1, "A"), window(2, "B"), window(3, "B")])
        list.update(with: [window(4, "B"), window(1, "A"), window(2, "B"), window(3, "B")])
        #expect(list.windows.map(\.windowID) == [1, 4, 2, 3])
    }

    @Test func aNewAppsWindowsComeFirstInTheirOwnOrder() {
        var list = StableWindowList([window(1, "A")])
        list.update(with: [window(5, "D"), window(6, "D"), window(1, "A")])
        #expect(list.windows.map(\.windowID) == [5, 6, 1])
    }

    @Test func titlesAndFramesFollowTheHost() {
        var list = StableWindowList([window(1, "A")])
        var renamed = window(1, "A")
        renamed.title = "New"
        list.update(with: [renamed])
        #expect(list.windows[0].title == "New")
    }

    @Test func smallResizesKeepTheShapeShown() {
        var list = StableWindowList([window(1, "A", width: 800, height: 600)])
        let shown = list.aspect(of: list.windows[0])
        list.update(with: [window(1, "A", width: 830, height: 600)])
        #expect(list.aspect(of: list.windows[0]) == shown)
        list.update(with: [window(1, "A", width: 1200, height: 600)])
        #expect(list.aspect(of: list.windows[0]) == 2)
    }

    @Test func resetTakesTheHostsOrder() {
        var list = StableWindowList([window(1, "A"), window(2, "B")])
        list.reset(to: [window(2, "B"), window(1, "A")])
        #expect(list.windows.map(\.windowID) == [2, 1])
    }
}
