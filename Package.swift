// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NASMover",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "NASMover",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NASMover",
            linkerSettings: [
                // Sparkle.framework is embedded in NAS Mover.app/Contents/Frameworks by build.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
