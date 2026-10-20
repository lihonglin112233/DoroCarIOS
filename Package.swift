// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DoroCarIOS",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .executable(name: "DoroCarIOS", targets: ["DoroCarIOS"])
    ],
    targets: [
        .executableTarget(
            name: "DoroCarIOS",
            sources: ["DoroCarApp.swift"],
            resources: [.copy("UI")]
        )
    ]
)
