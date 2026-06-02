// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GreyVctrAI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "GreyVctrAI",
            targets: ["GreyVctrAI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
        .package(url: "https://github.com/colinc86/LaTeXSwiftUI.git", from: "2.0.0"),
        .package(url: "https://github.com/google-ai-edge/LiteRT-LM.git", revision: "a0afb5a56acd106b23a2b2385b8469834dc268c0")
    ],
    targets: [
        .target(
            name: "GreyVctrAI",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "LaTeXSwiftUI", package: "LaTeXSwiftUI"),
                .product(name: "LiteRTLM", package: "LiteRT-LM")
            ],
            path: "Sources",
            resources: [
                .copy("Resources/Skills"),
                .process("Resources/inference_config.json")
            ]
        ),
        .testTarget(
            name: "GreyVctrAITests",
            dependencies: ["GreyVctrAI"],
            path: "Tests"
        )
    ]
)
