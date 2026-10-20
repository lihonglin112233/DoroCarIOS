// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DoroCarIOS",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .iOSApplication(
            name: "DoroCarIOS",
            targets: ["DoroCarIOS"],
            bundleIdentifier: "com.dorocar.hvac",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .car),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ]
        )
    ],
    targets: [
        .target(
            name: "DoroCarIOS",
            path: "./", // 直接使用仓库根目录
            sources: ["DoroCarApp.swift"],
            resources: [.copy("UI")]
        )
    ]
)
