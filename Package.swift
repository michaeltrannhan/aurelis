// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Auralis",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "Auralis", targets: ["Auralis"]),
        .library(name: "AuralisWidgetShared", targets: ["AuralisWidgetShared"])
    ],
    targets: [
        .target(name: "AuralisWidgetShared"),
        .executableTarget(name: "Auralis", dependencies: ["AuralisWidgetShared"]),
        .testTarget(
            name: "AuralisTests",
            dependencies: ["Auralis", "AuralisWidgetShared"],
            exclude: ["Fixtures"]
        )
    ]
)
