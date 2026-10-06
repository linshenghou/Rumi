// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFTranslate",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PDFTranslate", targets: ["PDFTranslate"])],
    targets: [
        .executableTarget(name: "PDFTranslate", resources: [.process("Resources")]),
        .testTarget(name: "PDFTranslateTests", dependencies: ["PDFTranslate"])
    ]
)
