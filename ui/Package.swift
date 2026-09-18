// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mirage",
    // MirageKit is the shared core: the iPhone app links it too, so it declares an iOS
    // minimum. The `Mirage` executable below is macOS-only and is simply never built for
    // iOS. Raising a platform here does not change how the Mac app compiles.
    platforms: [.macOS(.v14), .iOS(.v17)],
    // The iPhone app consumes this package from Xcode, so the shared core has to be a
    // product. Only MirageKit is published: MirageDevice carries linker flags for a
    // library built out of tree, and those have no business leaking into a consumer.
    products: [
        .library(name: "MirageKit", targets: ["MirageKit"]),
    ],
    targets: [
        // Pure-Foundation logic, split out so it can be tested without launching the app.
        .target(name: "MirageKit", path: "Sources/MirageKit"),
        // Named MirageMac rather than Mirage so that nothing else can be called Mirage.
        // The iPhone app's Xcode target has that name, and two schemes with one name is a
        // trap: picking the wrong one compiles this target's AppKit for iOS and produces
        // errors that point at the Mac app for no reason a reader could guess.
        // The bundle is still Mirage.app — scripts/build_app.sh renames the binary.
        .executableTarget(name: "MirageMac", dependencies: ["MirageKit"], path: "Sources/Mirage"),
        // The location bridge. Kept separate from MirageKit so the pure core, and its
        // tests, never depend on a Rust toolchain being present.
        // Requires ./scripts/build-native.sh to have run.
        .systemLibrary(name: "CMirageIdevice", path: "Sources/CMirageIdevice"),
        .target(
            name: "MirageDevice",
            dependencies: ["MirageKit", "CMirageIdevice"],
            path: "Sources/MirageDevice",
            linkerSettings: [
                .unsafeFlags(["-L../native/mirage-idevice/target/release"]),
            ]
        ),
        // Points IdeviceInjector at a real phone. An executable, not a test: it moves a
        // real device's reported location and must never run under `swift test`.
        .executableTarget(
            name: "mirage-device-check",
            dependencies: ["MirageKit", "MirageDevice"],
            path: "Sources/mirage-device-check"
        ),
        .testTarget(
            name: "MirageKitTests",
            dependencies: ["MirageKit"],
            path: "Tests/MirageKitTests",
            // golden.json is generated from the Python engine by scripts/gen-golden.py.
            resources: [.process("Resources")]
        ),
    ]
)
