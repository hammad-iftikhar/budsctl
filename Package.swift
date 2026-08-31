// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BudsKit",
    platforms: [.macOS("26.0")],
    products: [
        // Dynamic so the app and the control extension share one image of the
        // AppIntent types. Two static copies risk Control Center failing to bind.
        .library(name: "BudsKit", type: .dynamic, targets: ["BudsKit"]),
        .executable(name: "budsctl-cli", targets: ["budsctl-cli"]),
    ],
    targets: [
        .target(name: "BudsKit"),
        .executableTarget(
            name: "budsctl-cli",
            dependencies: ["BudsKit"],
            // Not a resource — the linker consumes it directly, so keep SPM
            // from trying to bundle it.
            exclude: ["Info.plist"],
            linkerSettings: [
                // A bare SPM executable has no bundle, so CoreBluetooth would be
                // denied for want of NSBluetoothAlwaysUsageDescription. Embed the
                // plist directly into the Mach-O.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/budsctl-cli/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "BudsKitTests", dependencies: ["BudsKit"]),
    ]
)
