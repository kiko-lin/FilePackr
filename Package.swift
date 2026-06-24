// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FilePackrCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ArchiveBrowser", targets: ["ArchiveBrowser"]),
    ],
    targets: [
        // Acceso a la libbz2 del sistema (header en el SDK, dylib vía -lbz2).
        .systemLibrary(name: "Cbz2", path: "Sources/Cbz2"),
        // Acceso a la libarchive del sistema (7z/rar/iso… vía -larchive; cabeceras propias).
        .systemLibrary(name: "Carchive", path: "Sources/Carchive"),
        // Acceso a la zlib del sistema (DEFLATE con nivel para ZIP/gzip; header del SDK, dylib vía -lz).
        .systemLibrary(name: "Cz", path: "Sources/Cz"),
        // Lectura/escritura de archivos comprimidos (ZIP/tar/gzip/xz/bzip2 en Swift puro; 7z/rar vía libarchive).
        .target(name: "ArchiveBrowser", dependencies: ["Cbz2", "Carchive", "Cz"]),

        .testTarget(
            name: "ArchiveBrowserTests",
            dependencies: ["ArchiveBrowser"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
