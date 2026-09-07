// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacThemes",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MacThemes", targets: ["MacThemes"])],
    targets: [
        .target(name: "ThemeCore"),
        .executableTarget(name: "MacThemes", dependencies: ["ThemeCore"]),
        .testTarget(name: "ThemeCoreTests", dependencies: ["ThemeCore"]),
        .testTarget(name: "IntegrationTests", dependencies: ["MacThemes", "ThemeCore"])
    ]
)
