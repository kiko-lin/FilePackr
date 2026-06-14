// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CifradorCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CryptoCore", targets: ["CryptoCore"]),
        .library(name: "ArchiveBrowser", targets: ["ArchiveBrowser"]),
    ],
    targets: [
        // Cifrado/descifrado. Sin dependencias externas: CryptoKit + CommonCrypto del sistema.
        .target(name: "CryptoCore"),
        // Lectura de archivos comprimidos sin descomprimir (ZIP central directory, Swift puro).
        .target(name: "ArchiveBrowser"),

        .testTarget(name: "CryptoCoreTests", dependencies: ["CryptoCore"]),
        .testTarget(
            name: "ArchiveBrowserTests",
            dependencies: ["ArchiveBrowser"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
