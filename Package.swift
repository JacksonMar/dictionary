// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VocabCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VocabCore", targets: ["VocabCore"])
    ],
    targets: [
        .target(name: "VocabCore"),
        .testTarget(name: "VocabCoreTests", dependencies: ["VocabCore"])
    ],
    swiftLanguageVersions: [.v5]
)
