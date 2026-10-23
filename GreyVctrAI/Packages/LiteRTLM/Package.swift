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
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.1/CLiteRTLM.xcframework.zip",
            checksum: "5c51905e38c77ccc611dc2f8c2af6cf5144621046f1dde6518aab83f78488937"
        ),
        .binaryTarget(
            name: "CLiteRTLM_mac",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.1/CLiteRTLM_mac.xcframework.zip",
            checksum: "91b8c968fb61486c3eb6b0e7a6a1dfa32181efd4f2e5df14fb8bb5746dd8dd9f"
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
