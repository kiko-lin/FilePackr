// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Los tests de la capa de modelo (`FilePackrModelTests`) están escritos contra el modelo de
// concurrencia de XCTest de Xcode 26 / Swift 6.3 (setUp/tearDown aislables al actor principal).
// Los runners de GitHub traen un Swift más antiguo donde esos métodos son `nonisolated`, así que
// no compilan allí. El CI los omite (define FILEPACKR_SKIP_MODEL_TESTS); en local, con Xcode 26,
// se compilan y corren con normalidad. Reincorporar al CI cuando exista runner de macOS 26.
let skipModelTests = ProcessInfo.processInfo.environment["FILEPACKR_SKIP_MODEL_TESTS"] != nil

var targets: [Target] = [
    // Acceso a la libbz2 del sistema (header en el SDK, dylib vía -lbz2).
    .systemLibrary(name: "Cbz2", path: "Sources/Cbz2"),
    // Acceso a la libarchive del sistema (7z/rar/iso… vía -larchive; cabeceras propias).
    .systemLibrary(name: "Carchive", path: "Sources/Carchive"),
    // Acceso a la zlib del sistema (DEFLATE con nivel para ZIP/gzip; header del SDK, dylib vía -lz).
    .systemLibrary(name: "Cz", path: "Sources/Cz"),
    // Acceso a la liblzma del sistema (xz con nivel; dylib vía -llzma, cabeceras propias).
    .systemLibrary(name: "Clzma", path: "Sources/Clzma"),
    // Lectura/escritura de archivos comprimidos (ZIP/tar/gzip/xz/bzip2 en Swift puro; 7z/rar vía libarchive).
    .target(name: "ArchiveBrowser", dependencies: ["Cbz2", "Carchive", "Cz", "Clzma"]),

    // Capa de modelo de la app (la consume el target Xcode FilePackr).
    .target(name: "FilePackrModel", dependencies: ["ArchiveBrowser"]),

    .testTarget(
        name: "ArchiveBrowserTests",
        dependencies: ["ArchiveBrowser"],
        resources: [.copy("Fixtures")]
    ),
]

if !skipModelTests {
    targets.append(
        .testTarget(
            name: "FilePackrModelTests",
            dependencies: ["FilePackrModel"]
        )
    )
}

let package = Package(
    name: "FilePackrCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ArchiveBrowser", targets: ["ArchiveBrowser"]),
        // Capa de modelo de la app (documento, coordinadores, ajustes): sin vistas, pero
        // sí AppKit/SwiftUI puntuales (paneles de carpeta, ColorScheme). Testeable por CLI.
        .library(name: "FilePackrModel", targets: ["FilePackrModel"]),
    ],
    targets: targets
)
