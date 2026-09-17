// swift-tools-version: 6.0
import PackageDescription

/// Fuentes de unrar que NO forman parte de la librería: plataforma Windows, utilidades de consola,
/// o ficheros que otros incluyen textualmente (compilarlos aparte duplicaría símbolos).
let unrarExcludedSources = [
    "arccmt", "blake2s_sse", "blake2sp", "cmdfilter", "cmdmix", "coder", "crypt1", "crypt2", "crypt3",
    "crypt5", "hardlinks", "isnt", "log", "model", "motw", "rarpch", "recvol", "recvol3", "recvol5", "rs",
    "suballoc", "threadmisc", "uicommon", "uiconsole", "uisilent", "ulinks", "unpack15", "unpack20",
    "unpack30", "unpack50", "unpack50frag", "unpack50mt", "unpackinline", "uowners", "win32acl",
    "win32lnk", "win32stm",
]

let targets: [Target] = [
    // Acceso a la libbz2 del sistema (header en el SDK, dylib vía -lbz2).
    .systemLibrary(name: "Cbz2", path: "Sources/Cbz2"),
    // Acceso a la libarchive del sistema (7z/rar/iso… vía -larchive; cabeceras propias).
    .systemLibrary(name: "Carchive", path: "Sources/Carchive"),
    // Acceso a la zlib del sistema (DEFLATE con nivel para ZIP/gzip; header del SDK, dylib vía -lz).
    .systemLibrary(name: "Cz", path: "Sources/Cz"),
    // Acceso a la liblzma del sistema (xz con nivel; dylib vía -llzma, cabeceras propias).
    .systemLibrary(name: "Clzma", path: "Sources/Clzma"),
    // unrar de RARLAB (fuentes vendorizadas en Sources/CUnrar/unrar, ver su README) tras una capa C
    // propia (`fp_unrar.h`): lectura de RAR, incluido el **cifrado**, que libarchive no descifra.
    // Solo se compilan los objetos de la librería (`make lib` del makefile original); el resto de
    // .cpp o no aplican a macOS o se incluyen desde otros (`#include "unpack15.cpp"`…).
    .target(
        name: "CUnrar",
        exclude: ["unrar/README.md", "unrar/license.txt", "unrar/readme.txt", "unrar/acknow.txt", "unrar/makefile"]
            + unrarExcludedSources.map { "unrar/\($0).cpp" },
        cxxSettings: [
            .headerSearchPath("unrar"),
            .define("RARDLL"), .define("RAR_SMP"),
            .define("_FILE_OFFSET_BITS", to: "64"), .define("_LARGEFILE_SOURCE"),
            // Código de terceros: sin avisos (no los vamos a corregir aquí).
            .unsafeFlags(["-w"]),
        ]
    ),
    // Lectura/escritura de archivos comprimidos (ZIP/tar/gzip/xz/bzip2 en Swift puro; 7z vía
    // libarchive; RAR vía unrar).
    .target(name: "ArchiveBrowser", dependencies: ["Cbz2", "Carchive", "Cz", "Clzma", "CUnrar"]),

    // Capa de modelo de la app (la consume el target Xcode FilePackr).
    .target(name: "FilePackrModel", dependencies: ["ArchiveBrowser"]),

    .testTarget(
        name: "ArchiveBrowserTests",
        dependencies: ["ArchiveBrowser"],
        resources: [.copy("Fixtures")]
    ),

    // Tests de la capa de modelo. Sus clases @MainActor usan setUp/tearDown `async` (no
    // síncronos) para compilar tanto en Xcode 26 como en el XCTest del runner de CI (Xcode 16).
    .testTarget(
        name: "FilePackrModelTests",
        dependencies: ["FilePackrModel"],
        resources: [.copy("Fixtures")]
    ),
]

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
