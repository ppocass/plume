// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Plume",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Plume", targets: ["Plume"])],
    targets: [
        .executableTarget(
            name: "Plume",
            path: "Sources/Plume",
            // Mode Swift 5 : l'app mélange fil audio temps réel, tap clavier
            // CoreGraphics et MainActor ; le mode strict de Swift 6 n'apporterait
            // que du bruit ici.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
