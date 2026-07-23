// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SenseCraftVoiceIOS",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "SenseCraftVoiceIOS",
            targets: ["SenseCraftVoiceIOS"]
        ),
        .executable(
            name: "SenseCraftVoiceVerifyCLI",
            targets: ["SenseCraftVoiceVerifyCLI"]
        ),
    ],
    targets: [
        .target(
            name: "SenseCraftVoiceIOS",
            dependencies: []
        ),
        .executableTarget(
            name: "SenseCraftVoiceVerifyCLI",
            dependencies: ["SenseCraftVoiceIOS"],
            path: "Examples/VerifyCLI/Sources"
        ),
        .testTarget(
            name: "SenseCraftVoiceIOSTests",
            dependencies: ["SenseCraftVoiceIOS"]
        ),
    ]
)
