@testable import AnyRemoteHost
import Foundation
import Testing

struct AppActorTests {
    @Test func appsActForWhoeverActedOnThemLast() {
        let actors = AppActors()
        // Not a running process: no launcher to go by either.
        let editor: pid_t = 900_002
        #expect(actors.actor(of: editor) == nil)

        actors.note(.viewer(7), pid: editor)
        #expect(actors.actor(of: editor) == .viewer(7))
        // This Mac's user types in it: what it opens next is theirs, until the viewer acts again.
        actors.note(.host, pid: editor)
        #expect(actors.actor(of: editor) == .host)
        actors.note(.viewer(7), pid: editor)
        #expect(actors.actor(of: editor) == .viewer(7))

        // This host itself acts for no one.
        actors.note(.host, pid: getpid())
        #expect(actors.actor(of: getpid()) == nil)
    }
}
