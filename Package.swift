// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeltaruneModManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DeltaruneModManager", targets: ["DeltaruneModManager"])
    ],
    targets: [
        .executableTarget(name: "DeltaruneModManager", exclude: ["Resources"])
    ],
    swiftLanguageVersions: [.v5]
)
