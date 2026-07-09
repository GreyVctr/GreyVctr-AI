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
        .package(path: "Vendor/LiteRT-LM")
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
