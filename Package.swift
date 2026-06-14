// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CifradorCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ArchiveBrowser", targets: ["ArchiveBrowser"]),
    ],
    targets: [
        // Lectura/escritura de archivos comprimidos en Swift puro (ZIP/tar/gzip, cifrado).
        .target(name: "ArchiveBrowser"),

        .testTarget(
            name: "ArchiveBrowserTests",
            dependencies: ["ArchiveBrowser"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
