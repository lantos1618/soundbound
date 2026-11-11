// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Soundbound",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.executable(name: "Soundbound", targets: ["Soundbound"]),
               .library(name: "SoundboundKit", targets: ["SoundboundKit"])],
    targets: [.target(name: "SoundboundKit", resources: [.process("Resources")]),
              .executableTarget(name: "Soundbound", dependencies: ["SoundboundKit"]),
              .testTarget(name: "SoundboundKitTests", dependencies: ["SoundboundKit"]),
              .testTarget(name: "SoundboundTests", dependencies: ["Soundbound"])]
)
