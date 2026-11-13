// swift-tools-version: 5.9
// Clinton Imaro was here 20/09/2026.
import PackageDescription
import Foundation

// Real windows, global hotkeys, and system integration are opt-in and belong
// on an isolated machine. Ordinary `swift test` never discovers this target.
var testTargets: [Target] = [
    .testTarget(name: "ShieldCoreTests", dependencies: ["ShieldCore"]),
    .testTarget(name: "QuietGlassTests", dependencies: ["QuietGlass"], resources: [.copy("Fixtures")])
]
if ProcessInfo.processInfo.environment["QUIETGLASS_DESKTOP_TESTS"] == "1" {
    testTargets.append(.testTarget(name: "QuietGlassDesktopTests", dependencies: ["QuietGlass"]))
}

let package = Package(
    name: "QuietGlass",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuietGlass", targets: ["QuietGlass"])],
    targets: [
        .target(name: "ShieldCore"),
        .executableTarget(name: "QuietGlass", dependencies: ["ShieldCore"], resources: [
            .copy("Resources/SFace.mlmodel"),
            .copy("Resources/NearbyAlert.mp3")
        ])
    ] + testTargets
)
