// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiteRTLM",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "LiteRTLM", targets: ["LiteRTLM"])
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.19.0/CLiteRTLM.xcframework.zip",
            checksum: "b7b2450fc084058adc5185498f8b7810a9297e054a10cf55818b62e1d5f8d65d"
        ),
        .binaryTarget(
            name: "CLiteRTLM_mac",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.19.0/CLiteRTLM_mac.xcframework.zip",
            checksum: "1a9e283a99a119aefe21afda541a5308a7d88aa9cb12f58aa7974038e3369c7c"
        ),
        .target(
            name: "LiteRTLM",
            dependencies: [
                .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
                .target(name: "CLiteRTLM_mac", condition: .when(platforms: [.macOS]))
            ]
        )
    ]
)
