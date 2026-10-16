// swift-tools-version: 6.0
import PackageDescription

/// `parakeet-server` : NVIDIA Parakeet (Ultra, Redux ou v3, 25 langues
/// européennes) sur le Neural Engine, servi avec la MÊME API HTTP que
/// `whisper-server` de whisper.cpp (`GET /` pour sonder, `POST /inference`
/// multipart → `{"text": …}`) : on passe d'un moteur à l'autre en changeant
/// seulement de port.
let package = Package(
    name: "ParakeetServer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "parakeet-server", targets: ["ParakeetServer"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "ParakeetServer",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/ParakeetServer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
