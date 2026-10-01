// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zapas",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZapasCore", targets: ["ZapasCore"]),
        .executable(name: "zapas-probe", targets: ["ZapasProbe"]),
        .executable(name: "zapas-native-host", targets: ["ZapasNativeHost"])
    ],
    targets: [
        .target(name: "CZapas", linkerSettings: [.linkedLibrary("proc")]),
        .target(name: "ZapasCore", dependencies: ["CZapas"]),
        .executableTarget(name: "ZapasProbe", dependencies: ["ZapasCore"]),
        .executableTarget(name: "ZapasNativeHost", dependencies: ["ZapasCore"]),
        .testTarget(name: "ZapasCoreTests", dependencies: ["ZapasCore"])
    ],
    swiftLanguageModes: [.v6]
)
