// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CifradorCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ArchiveBrowser", targets: ["ArchiveBrowser"]),
    ],
    targets: [
        // Acceso a la libbz2 del sistema (header en el SDK, dylib vía -lbz2).
        .systemLibrary(name: "Cbz2", path: "Sources/Cbz2"),
        // Lectura/escritura de archivos comprimidos en Swift puro (ZIP/tar/gzip/xz/bzip2, cifrado).
        .target(name: "ArchiveBrowser", dependencies: ["Cbz2"]),

        .testTarget(
            name: "ArchiveBrowserTests",
            dependencies: ["ArchiveBrowser"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
