// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pastemin",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Pastemin", targets: ["PasteminApp"])],
    targets: [
        .executableTarget(
            name: "PasteminApp",
            path: "Sources/PasteminApp",
            resources: [
                .copy("Resources/PRIVACY.md")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("StoreKit")
            ]
        )
    ]
)
