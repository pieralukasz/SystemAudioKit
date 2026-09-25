// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SystemAudioKit",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "SystemAudioKit", targets: ["SystemAudioKit"]),
        .executable(name: "sysaudio", targets: ["sysaudio"]),
    ],
    targets: [
        .target(
            name: "SystemAudioKit",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .executableTarget(
            name: "sysaudio",
            dependencies: ["SystemAudioKit"]
        ),
        .testTarget(
            name: "SystemAudioKitTests",
            dependencies: ["SystemAudioKit"]
        ),
    ]
)
