// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnyRemoteKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AnyRemoteWire", targets: ["AnyRemoteWire"]),
        .library(name: "AnyRemoteMedia", targets: ["AnyRemoteMedia"]),
        .library(name: "AnyRemoteWindowControl", targets: ["AnyRemoteWindowControl"]),
        .library(name: "AnyRemoteDiagnostics", targets: ["AnyRemoteDiagnostics"]),
        .library(name: "AnyRemoteNetwork", targets: ["AnyRemoteNetwork"]),
        .library(name: "AnyRemoteHost", targets: ["AnyRemoteHost"]),
        .library(name: "AnyRemoteClient", targets: ["AnyRemoteClient"]),
        .library(name: "AnyRemoteUpdate", targets: ["AnyRemoteUpdate"]),
        .library(name: "AnyRemoteTailnet", targets: ["AnyRemoteTailnet"]),
        .executable(name: "anyremote-bench", targets: ["anyremote-bench"]),
    ],
    targets: [
        // Deterministic wire formats. No Apple media or UI frameworks.
        .target(name: "AnyRemoteWire"),
        // Capture, encode, decode and presentation of per-window video.
        .target(name: "AnyRemoteMedia", dependencies: ["AnyRemoteWire"]),
        // Host-side window enumeration and geometry control (Accessibility).
        .target(name: "AnyRemoteWindowControl", dependencies: ["AnyRemoteWire"]),
        // Sealed TCP control channel, UDP datagram socket, Bonjour.
        .target(name: "AnyRemoteNetwork", dependencies: ["AnyRemoteWire"]),
        // Declarations of CoreGraphics' private CGVirtualDisplay classes.
        .target(name: "CGVirtualDisplayPrivate", linkerSettings: [.linkedFramework("CoreGraphics")]),
        // Host agent: sessions, window streams, input injection, cursor, menus.
        .target(
            name: "AnyRemoteHost",
            dependencies: ["AnyRemoteWire", "AnyRemoteMedia", "AnyRemoteNetwork", "AnyRemoteWindowControl",
                           "CGVirtualDisplayPrivate"]
        ),
        // Viewer side of a host connection (UI-free).
        .target(name: "AnyRemoteClient", dependencies: ["AnyRemoteWire", "AnyRemoteMedia", "AnyRemoteNetwork"]),
        // Software update: release manifest, download, signature checks, install.
        .target(name: "AnyRemoteUpdate", dependencies: ["AnyRemoteWire"]),
        // The embedded Tailscale node's C interface. Its functions are Go
        // (Tailnet/), built by scripts/build-tailnet.sh and linked by the app
        // alone: nothing else here depends on this, so the package builds
        // and tests without Go.
        .target(name: "CAnyRemoteTailnet"),
        .target(
            name: "AnyRemoteTailnet",
            dependencies: ["CAnyRemoteTailnet", "AnyRemoteNetwork"],
            linkerSettings: [
                .linkedLibrary("anyremotetailnet"), .linkedLibrary("resolv"),
                .linkedFramework("CoreFoundation"), .linkedFramework("Security"),
                .linkedFramework("IOKit"), .linkedFramework("SystemConfiguration"),
            ]
        ),
        // Reproducible workloads for latency measurements.
        .target(name: "AnyRemoteDiagnostics"),
        .executableTarget(
            name: "anyremote-bench",
            dependencies: ["AnyRemoteWire", "AnyRemoteMedia", "AnyRemoteDiagnostics", "AnyRemoteHost",
                           "AnyRemoteClient"]
        ),
        .testTarget(name: "AnyRemoteWireTests", dependencies: ["AnyRemoteWire"]),
        .testTarget(name: "AnyRemoteWindowControlTests", dependencies: ["AnyRemoteWindowControl", "AnyRemoteWire"]),
        .testTarget(name: "AnyRemoteMediaTests", dependencies: ["AnyRemoteMedia", "AnyRemoteWire"]),
        .testTarget(name: "AnyRemoteUpdateTests", dependencies: ["AnyRemoteUpdate", "AnyRemoteWire"]),
        .testTarget(name: "AnyRemoteNetworkTests",
                    dependencies: ["AnyRemoteNetwork", "AnyRemoteWire", "AnyRemoteHost", "AnyRemoteClient"]),
    ]
)
