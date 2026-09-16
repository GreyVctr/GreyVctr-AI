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
        // v0.17.1 republishes the v0.17.0 Apple binaries with identical checksums.
        // See the README's SPM dependency note for the native tool-call fix limitation.
        .binaryTarget(
            name: "CLiteRTLM",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.17.1/CLiteRTLM.xcframework.zip",
            checksum: "c94fc12aa0403cb47208e419cc3bfe258214ea17035f7a63c16de536869f2186"
        ),
        .binaryTarget(
            name: "CLiteRTLM_mac",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.17.1/CLiteRTLM_mac.xcframework.zip",
            checksum: "83efd536485c9d58fcd7fb7d4556ddb16ca46bb775b0449d08d9825c6836c1a4"
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
