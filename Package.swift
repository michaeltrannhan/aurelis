// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EQMacRep",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "EQMacRep", targets: ["EQMacRep"])
    ],
    targets: [
        .executableTarget(name: "EQMacRep"),
        .testTarget(name: "EQMacRepTests", dependencies: ["EQMacRep"])
    ]
)
