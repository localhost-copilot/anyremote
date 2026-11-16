@testable import AnyRemoteUpdate
import AnyRemoteWire
import CryptoKit
import Foundation
import Testing

@Suite struct UpdateTests {
    static let identifier = "com.localhost-copilot.anyremote.update-test"

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anyremote-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A minimal ad-hoc signed app bundle.
    static func makeApp(in directory: URL, version: String, identifier: String = identifier) throws -> URL {
        let app = directory.appendingPathComponent("AnyRemote.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                    "CFBundleExecutable": "AnyRemote", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: macOS.appendingPathComponent("AnyRemote"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path], error: UpdateError.signature)
        return app
    }

    static func zip(_ app: URL, to archive: URL) throws -> UpdateManifest {
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path], error: UpdateError.archive)
        let data = try Data(contentsOf: archive)
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return UpdateManifest(version: version, protocolVersion: anyRemoteProtocolVersion, minimumSystemVersion: "15.0",
                              url: archive, size: data.count,
                              sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                              notes: ["en": ["Faster."], "zh-Hans": ["更快。"]], releaseURL: nil)
    }

    @Test func versionsCompareNumerically() {
        #expect(AppVersion("0.10.0")! > AppVersion("0.9.9")!)
        #expect(AppVersion("v1.2")! == AppVersion("1.2.0")!)
        #expect(AppVersion("0.26.0")! < AppVersion("0.26.1")!)
        #expect(AppVersion("1.x") == nil)
        #expect(AppVersion("") == nil)
    }

    @Test func manifestChecksItsFields() throws {
        func json(url: String, sha: String = String(repeating: "a", count: 64)) -> Data {
            Data("""
            {"version":"0.26.0","protocolVersion":20,"minimumSystemVersion":"15.0","url":"\(url)",
             "size":10,"sha256":"\(sha)","notes":{"en":["One"],"zh-Hans":["一"]}}
            """.utf8)
        }
        let manifest = try UpdateManifest.decode(json(url: "https://github.com/a.zip"))
        #expect(manifest.isNewer(than: "0.25.0"))
        #expect(!manifest.isNewer(than: "0.26.0"))
        #expect(manifest.supportsThisSystem)
        #expect(manifest.notes(preferring: ["zh-Hans"]) == ["一"])
        #expect(manifest.notes(preferring: ["fr", "en"]) == ["One"])
        #expect(manifest.notes(preferring: ["de"]) == ["One"])
        #expect(throws: UpdateError.self) { try UpdateManifest.decode(json(url: "http://example.com/a.zip")) }
        #expect(throws: UpdateError.self) { try UpdateManifest.decode(json(url: "https://x/a.zip", sha: "12")) }
        _ = try UpdateManifest.decode(json(url: "http://127.0.0.1:8000/a.zip"))
    }

    @Test func stagesASignedReleaseAndRejectsOthers() throws {
        let work = try Self.scratch()
        defer { try? FileManager.default.removeAll(at: work) }
        let built = try Self.makeApp(in: work.appendingPathComponent("build"), version: "9.0.0")
        let manifest = try Self.zip(built, to: work.appendingPathComponent("AnyRemote-9.0.0.zip"))
        let stager = UpdateStager(directory: work.appendingPathComponent("staging"), bundleIdentifier: Self.identifier,
                                  requirement: "identifier \"\(Self.identifier)\"")

        let staged = try stager.stage(manifest, archive: manifest.url)
        #expect(staged.appURL.lastPathComponent == "AnyRemote.app")

        var damaged = manifest
        damaged.sha256 = String(repeating: "0", count: 64)
        #expect(throws: UpdateError.checksum) { try stager.stage(damaged, archive: manifest.url) }

        var otherVersion = manifest
        otherVersion.version = "9.0.1"
        #expect { try stager.stage(otherVersion, archive: manifest.url) } throws: {
            if case .wrongApp = $0 as? UpdateError { true } else { false }
        }

        let otherSigner = UpdateStager(directory: work.appendingPathComponent("staging2"),
                                       bundleIdentifier: Self.identifier,
                                       requirement: "identifier \"\(Self.identifier)\" and anchor apple")
        #expect { try otherSigner.stage(manifest, archive: manifest.url) } throws: {
            if case .signature = $0 as? UpdateError { true } else { false }
        }

        // Changed after signing.
        let tampered = try Self.makeApp(in: work.appendingPathComponent("tampered"), version: "9.0.0")
        let handle = try FileHandle(forWritingTo: tampered.appendingPathComponent("Contents/MacOS/AnyRemote"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let tamperedManifest = try Self.zip(tampered, to: work.appendingPathComponent("tampered.zip"))
        #expect { try stager.stage(tamperedManifest, archive: tamperedManifest.url) } throws: {
            if case .signature = $0 as? UpdateError { true } else { false }
        }
    }

    @Test func adHocSignaturesHaveNoUpdateRequirement() throws {
        let work = try Self.scratch()
        defer { try? FileManager.default.removeAll(at: work) }
        let app = try Self.makeApp(in: work, version: "1.0")
        #expect(CodeSignature.requirement(ofBundleAt: app) == nil)
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        #expect(CodeSignature.requirement(ofBundleAt: calculator)?.contains("com.apple.calculator") == true)
    }

    @Test func installerSwapsTheAppOnceTheProcessExits() async throws {
        let work = try Self.scratch()
        defer { try? FileManager.default.removeAll(at: work) }
        let installed = try Self.makeApp(in: work.appendingPathComponent("Applications"), version: "1.0.0")
        let built = try Self.makeApp(in: work.appendingPathComponent("build"), version: "2.0.0")
        let manifest = try Self.zip(built, to: work.appendingPathComponent("AnyRemote-2.0.0.zip"))
        let stager = UpdateStager(directory: work.appendingPathComponent("staging"), bundleIdentifier: Self.identifier,
                                  requirement: "identifier \"\(Self.identifier)\"")
        let staged = try stager.stage(manifest, archive: manifest.url)
        #expect(UpdateInstaller.canReplace(installed))

        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["1"]
        try running.run()
        try UpdateInstaller.start(staged, replacing: installed, waitingFor: running.processIdentifier, relaunch: false)
        func version() -> String? {
            NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"]
                as? String
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(version() == "1.0.0")
        for _ in 0..<50 where version() != "2.0.0" { try await Task.sleep(for: .milliseconds(100)) }
        #expect(version() == "2.0.0")
        // The old copy is deleted only after the new one is in place, so wait for that too.
        func leftovers() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)) ?? []
        }
        for _ in 0..<50 where leftovers() != ["AnyRemote.app"] { try await Task.sleep(for: .milliseconds(100)) }
        #expect(leftovers() == ["AnyRemote.app"])
    }
}

extension FileManager {
    func removeAll(at url: URL) throws { try removeItem(at: url) }
}
