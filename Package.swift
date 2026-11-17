// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "simpilot", targets: ["simpilot"]),
        .executable(name: "SimPilotMenuBar", targets: ["SimPilotMenuBar"]),
    ],
    targets: [
        .target(name: "SimPilotCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "simpilot", dependencies: ["SimPilotCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "SimPilotMenuBar", dependencies: ["SimPilotCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SimPilotCoreTests", dependencies: ["SimPilotCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
