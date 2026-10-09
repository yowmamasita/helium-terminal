// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "helium-terminal",
    platforms: [.macOS(.v13)],
    targets: [
        // Built by scripts/build-ghostty.sh from the pinned Ghostty checkout.
        .binaryTarget(name: "GhosttyKit", path: "vendor/ghostty/macos/GhosttyKit.xcframework"),
        .executableTarget(
            name: "helium-terminal",
            dependencies: ["GhosttyKit"],
            path: "Sources/Helium",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
