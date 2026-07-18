// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EQMacRep",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "EQMacRep", targets: ["EQMacRep"]),
        .library(name: "EQMacRepWidgetShared", targets: ["EQMacRepWidgetShared"])
    ],
    targets: [
        .target(name: "EQMacRepWidgetShared"),
        .executableTarget(name: "EQMacRep", dependencies: ["EQMacRepWidgetShared"]),
        .testTarget(
            name: "EQMacRepTests",
            dependencies: ["EQMacRep", "EQMacRepWidgetShared"]
        )
    ]
)
