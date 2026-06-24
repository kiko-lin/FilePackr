import Foundation
import SwiftUI
import Combine

/// Idiomas disponibles. El inglés es el idioma por defecto.
enum Language: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case spanish = "es"

    var id: String { rawValue }

    /// Nombre del idioma en su propia lengua (para mostrarlo en el selector).
    var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        }
    }
}

/// Sistema de internacionalización con cambio de idioma en caliente. Los textos se
/// resuelven contra un catálogo en memoria; al cambiar `language` se vuelven a
/// renderizar las vistas que observan este objeto. El idioma se recuerda entre sesiones.
@MainActor
final class Localizer: ObservableObject {
    static let shared = Localizer()

    private static let storageKey = "app.language"

    @Published var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey) }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let saved = Language(rawValue: raw) {
            language = saved
        } else {
            language = .english   // por defecto
        }
    }

    /// Texto localizado para `key` (cae al inglés y, en último caso, a la propia clave).
    func callAsFunction(_ key: String) -> String {
        Self.catalog[language]?[key] ?? Self.catalog[.english]?[key] ?? key
    }

    /// Texto localizado con formato (`%@`, `%d`…).
    func callAsFunction(_ key: String, _ args: CVarArg...) -> String {
        String(format: callAsFunction(key), arguments: args)
    }
}

// MARK: - Catálogo

private extension Localizer {
    static let catalog: [Language: [String: String]] = [.english: en, .spanish: es]

    static let en: [String: String] = [
        // Toolbar
        "toolbar.add": "Add",
        "toolbar.add.help": "Add files, or open an archive if it's the first one",
        "toolbar.delete": "Delete",
        "toolbar.delete.help": "Delete the selected item",
        "toolbar.newFolder": "New Folder",
        "toolbar.newFolder.help": "Create a folder",
        "toolbar.extract": "Extract",
        "toolbar.extract.help": "Extract the selected item to a location",
        "toolbar.settings": "Settings",

        // Settings window
        "settings.title": "Settings",
        "settings.tab.general": "General",
        "settings.tab.files": "Files",
        "settings.language": "Language",
        "settings.appearance": "Appearance",
        "theme.system": "Follow System",
        "theme.light": "Light",
        "theme.dark": "Dark",
        "settings.defaultFormat": "Default format",
        "settings.defaultEncryption": "Default encryption",
        "settings.extractTo": "Extract to",
        "extract.dest.archiveFolder": "The archive's folder",
        "extract.dest.fixedFolder": "A fixed folder",
        "settings.noFolder": "No folder chosen",
        "settings.addHidden": "When adding files",
        "settings.addHidden.note": "Applies when expanding dragged or added folders. The contents of an open archive are always shown in full.",
        "settings.hidden.includeAll": "Include everything",
        "settings.hidden.excludeSystemFiles": "Exclude system files",
        "settings.hidden.excludeAllHidden": "Exclude all hidden files",
        "status.excluded.one": "1 system file excluded",
        "status.excluded.many": "%d system files excluded",
        "button.done": "Done",

        // Settings · Files tab
        "settings.files.header": "Open these archives with FilePackr by default",
        "settings.files.selectAll": "Select all",
        "settings.files.deselectAll": "Deselect all",
        "settings.files.note": "Unchecking a format doesn't hand it back to another app; change “Open with → Change All” in Finder to pick a different default.",

        // First-run prompt
        "firstrun.title": "Make FilePackr your default compressor?",
        "firstrun.message": "Would you like FilePackr to open compressed files by default? You can choose which formats next.",
        "firstrun.yes": "Yes",
        "firstrun.later": "Not now",

        // Document bar
        "doc.encrypted.help": "Encrypted archive",
        "doc.volumes.help": "Saved in volumes",
        "doc.unsaved": "— unsaved",
        "status.file": "file",
        "status.files": "files",
        "status.compressed": "compressed",
        "button.close": "Close",
        "button.save": "Save",
        "button.export": "Export",
        "button.extractAll": "Extract all",
        "button.export.help": "Save a separate copy with a chosen format, encryption and password (the open document is unchanged).",
        "export.title": "Export to another format",

        // Drop prompt
        "drop.title": "Drag files here or click to choose",
        "drop.subtitle": "A .zip, .7z, .rar, .tar(.gz/.xz/.bz2), .gz, .xz or .bz2 opens for editing; other files create a new one.",

        // Save sheet
        "save.title": "Save file",
        "save.title.changes": "Save changes",
        "save.format": "Format",
        "save.encryption": "Encryption",
        "save.encryption.none": "Not encrypted",
        "save.encryption.weak": "Weak (PKZip2 compatible)",
        "save.encryption.strong": "Strong (AES-256)",
        "save.password": "Password",
        "save.name": "Name",
        "save.where": "Where",
        "save.overwrite.title": "“%@” already exists",
        "save.overwrite.message": "A file named “%@” already exists in this folder. Replace it?",
        "save.overwrite.confirm": "Replace",
        "save.noEncryption": "This format doesn't support encryption.",
        "save.split": "Split into volumes",
        "save.volumeSize": "Size of each volume",
        "save.split.hint": "«name.%@», «name_001.%@»… will be created. To open it, select any of the parts.",

        // Formats
        "format.zip": "ZIP",
        "format.tar": "TAR",
        "format.tarGzip": "TAR.GZ (compressed)",
        "format.tarXz": "TAR.XZ (compressed)",
        "format.tarBzip2": "TAR.BZ2 (compressed)",
        "format.gzip": "GZIP (single file)",
        "format.xz": "XZ (single file)",
        "format.bzip2": "BZIP2 (single file)",
        "format.sevenZip": "7z",
        "format.rar": "RAR (read only)",
        "format.iso": "ISO (disc image)",
        "format.cpio": "CPIO (read only)",
        "format.xar": "XAR",
        "format.lha": "LHA (read only)",
        "format.cab": "CAB (read only)",

        // Extract sheet
        "extract.title.all": "Extract all",
        "extract.title.one": "Extract selected file",
        "extract.title.many": "Extract selected files",
        "extract.in": "In:",
        "extract.choose": "Choose…",
        "button.extract": "Extract",

        // Passwords
        "password.field": "Password",
        "password.openTitle": "Password to open the archive",
        "password.open": "Open",
        "password.continue": "Continue",
        "password.entryTitle": "Archive password",
        "password.wrong": "Wrong password.",

        // Close confirmation
        "unsaved.title": "Do you want to save your changes?",
        "unsaved.message": "If you don't save them, your changes will be lost.",
        "unsaved.dontSave": "Close Without Saving",

        // Errors
        "error.title": "The operation could not be completed",
        "error.needsPassword": "This archive is password-protected. Enter the password to continue.",
        "error.wrongPassword": "The password is incorrect.",
        "error.unsupportedEncryption": "This archive uses an encryption method that isn’t supported.",
        "error.unsupportedMethod": "This archive uses a compression method that isn’t supported.",
        "error.corrupt": "The file is damaged or isn’t a valid archive.",
        "error.writeFailed": "The archive could not be written.",
        "error.readFailed": "The archive could not be read.",
        "button.ok": "OK",
        "button.cancel": "Cancel",
        "button.saveEllipsis": "Save…",

        // Extraction conflict
        "conflict.title": "“%@” already exists in the destination",
        "conflict.message": "An item named “%@” already exists in the destination. Do you want to overwrite it or keep both?",
        "conflict.overwrite": "Overwrite",
        "conflict.keepBoth": "Keep both",

        // Add conflict (same name already in the archive)
        "add.conflict.title": "“%@” already exists",
        "add.conflict.message": "An item named “%@” already exists in this location. Do you want to overwrite it or keep both?",
        "add.conflict.overwrite": "Overwrite",
        "add.conflict.keepBoth": "Keep both",

        // System panels
        "panel.add": "Add",
        "panel.choose": "Choose",

        // Outline columns
        "column.name": "Name",
        "column.date": "Date",
        "column.size": "Size",
        "column.kind": "Kind",
        "column.compressed": "Compressed",

        // Context menu
        "menu.rename": "Rename",
        "menu.extract": "Extract…",
        "menu.delete": "Delete",

        // Model
        "doc.untitled": "Untitled",
        "doc.newFolder": "New folder",
        "progress.opening": "Opening %@…",
        "progress.compressing": "Compressing %@…",
        "progress.encrypting": "Encrypting %@…",
        "progress.splitting": "Splitting into volumes…",
        "progress.extracting": "Extracting…",
        "kind.folder": "Folder",
        "kind.document": "Document",
        "kind.documentExt": "%@ Document",
        "promise.fallback": "file",
    ]

    static let es: [String: String] = [
        // Toolbar
        "toolbar.add": "Añadir",
        "toolbar.add.help": "Añadir archivos, o abrir un archivo si es el primero",
        "toolbar.delete": "Eliminar",
        "toolbar.delete.help": "Eliminar el elemento seleccionado",
        "toolbar.newFolder": "Crear carpeta",
        "toolbar.newFolder.help": "Crear una carpeta",
        "toolbar.extract": "Extraer",
        "toolbar.extract.help": "Extraer el elemento seleccionado a una ubicación",
        "toolbar.settings": "Ajustes",

        // Settings window
        "settings.title": "Ajustes",
        "settings.tab.general": "General",
        "settings.tab.files": "Archivos",
        "settings.language": "Idioma",
        "settings.appearance": "Apariencia",
        "theme.system": "Según el sistema",
        "theme.light": "Claro",
        "theme.dark": "Oscuro",
        "settings.defaultFormat": "Formato por defecto",
        "settings.defaultEncryption": "Cifrado por defecto",
        "settings.extractTo": "Extraer en",
        "extract.dest.archiveFolder": "La carpeta del archivo",
        "extract.dest.fixedFolder": "Una carpeta fija",
        "settings.noFolder": "Ninguna carpeta elegida",
        "settings.addHidden": "Al añadir archivos",
        "settings.addHidden.note": "Se aplica al expandir las carpetas que arrastres o añadas. El contenido de un archivo ya abierto se muestra siempre íntegro.",
        "settings.hidden.includeAll": "Incluir todo",
        "settings.hidden.excludeSystemFiles": "Excluir archivos de sistema",
        "settings.hidden.excludeAllHidden": "Excluir todos los ocultos",
        "status.excluded.one": "Se excluyó 1 archivo de sistema",
        "status.excluded.many": "Se excluyeron %d archivos de sistema",
        "button.done": "Hecho",

        // Pestaña Archivos de Ajustes
        "settings.files.header": "Abrir estos archivos con FilePackr por defecto",
        "settings.files.selectAll": "Marcar todos",
        "settings.files.deselectAll": "Desmarcar todos",
        "settings.files.note": "Desmarcar un formato no se lo devuelve a otra app; usa «Abrir con → Cambiar todos» en el Finder para elegir otra app por defecto.",

        // Diálogo de primer arranque
        "firstrun.title": "¿Hacer de FilePackr tu compresor por defecto?",
        "firstrun.message": "¿Quieres que FilePackr abra los archivos comprimidos por defecto? Después podrás elegir qué formatos.",
        "firstrun.yes": "Sí",
        "firstrun.later": "Ahora no",

        // Document bar
        "doc.encrypted.help": "Archivo cifrado",
        "doc.volumes.help": "Guardado en volúmenes",
        "doc.unsaved": "— sin guardar",
        "status.file": "archivo",
        "status.files": "archivos",
        "status.compressed": "comprimido",
        "button.close": "Cerrar",
        "button.save": "Guardar",
        "button.export": "Exportar",
        "button.extractAll": "Extraer todo",
        "button.export.help": "Guarda una copia aparte con el formato, cifrado y contraseña que elijas (el documento abierto no cambia).",
        "export.title": "Exportar a otro formato",

        // Drop prompt
        "drop.title": "Arrastra archivos aquí o haz clic para elegir",
        "drop.subtitle": "Un .zip, .7z, .rar, .tar(.gz/.xz/.bz2), .gz, .xz o .bz2 se abrirá para editarlo; otros archivos crearán uno nuevo.",

        // Save sheet
        "save.title": "Guardar archivo",
        "save.title.changes": "Guardar cambios",
        "save.format": "Formato",
        "save.encryption": "Cifrado",
        "save.encryption.none": "No cifrado",
        "save.encryption.weak": "Débil (PKZip2 compatible)",
        "save.encryption.strong": "Fuerte (AES-256)",
        "save.password": "Contraseña",
        "save.name": "Nombre",
        "save.where": "Lugar",
        "save.overwrite.title": "Ya existe «%@»",
        "save.overwrite.message": "Ya hay un archivo llamado «%@» en esta carpeta. ¿Reemplazarlo?",
        "save.overwrite.confirm": "Reemplazar",
        "save.noEncryption": "Este formato no admite cifrado.",
        "save.split": "Dividir en volúmenes",
        "save.volumeSize": "Tamaño de cada volumen",
        "save.split.hint": "Se generarán «nombre.%@», «nombre_001.%@»… Para abrirlo, selecciona cualquiera de las partes.",

        // Formats
        "format.zip": "ZIP",
        "format.tar": "TAR",
        "format.tarGzip": "TAR.GZ (comprimido)",
        "format.tarXz": "TAR.XZ (comprimido)",
        "format.tarBzip2": "TAR.BZ2 (comprimido)",
        "format.gzip": "GZIP (un fichero)",
        "format.xz": "XZ (un fichero)",
        "format.bzip2": "BZIP2 (un fichero)",
        "format.sevenZip": "7z",
        "format.rar": "RAR (solo lectura)",
        "format.iso": "ISO (imagen de disco)",
        "format.cpio": "CPIO (solo lectura)",
        "format.xar": "XAR",
        "format.lha": "LHA (solo lectura)",
        "format.cab": "CAB (solo lectura)",

        // Extract sheet
        "extract.title.all": "Extraer todo",
        "extract.title.one": "Extraer archivo seleccionado",
        "extract.title.many": "Extraer archivos seleccionados",
        "extract.in": "En:",
        "extract.choose": "Elegir…",
        "button.extract": "Extraer",

        // Passwords
        "password.field": "Contraseña",
        "password.openTitle": "Contraseña para abrir el archivo",
        "password.open": "Abrir",
        "password.continue": "Continuar",
        "password.entryTitle": "Contraseña del archivo",
        "password.wrong": "Contraseña incorrecta.",

        // Close confirmation
        "unsaved.title": "¿Quieres guardar los cambios?",
        "unsaved.message": "Si no los guardas, se perderán.",
        "unsaved.dontSave": "Cerrar sin guardar",

        // Errors
        "error.title": "No se pudo completar la operación",
        "error.needsPassword": "Este archivo está protegido con contraseña. Introdúcela para continuar.",
        "error.wrongPassword": "La contraseña no es correcta.",
        "error.unsupportedEncryption": "Este archivo usa un cifrado que no se admite.",
        "error.unsupportedMethod": "Este archivo usa un método de compresión que no se admite.",
        "error.corrupt": "El fichero está dañado o no es un archivo válido.",
        "error.writeFailed": "No se pudo escribir el archivo.",
        "error.readFailed": "No se pudo leer el archivo.",
        "button.ok": "Aceptar",
        "button.cancel": "Cancelar",
        "button.saveEllipsis": "Guardar…",

        // Extraction conflict
        "conflict.title": "Ya existe «%@» en el destino",
        "conflict.message": "Ya hay un elemento llamado «%@» en el destino. ¿Quieres sobrescribirlo o conservar ambos?",
        "conflict.overwrite": "Sobrescribir",
        "conflict.keepBoth": "Conservar ambos",

        // Add conflict (mismo nombre ya en el archivo)
        "add.conflict.title": "Ya existe «%@»",
        "add.conflict.message": "Ya hay un elemento llamado «%@» en esta ubicación. ¿Quieres sobrescribirlo o conservar ambos?",
        "add.conflict.overwrite": "Sobrescribir",
        "add.conflict.keepBoth": "Conservar ambos",

        // System panels
        "panel.add": "Añadir",
        "panel.choose": "Elegir",

        // Outline columns
        "column.name": "Nombre",
        "column.date": "Fecha",
        "column.size": "Tamaño",
        "column.kind": "Clase",
        "column.compressed": "Comprimido",

        // Context menu
        "menu.rename": "Renombrar",
        "menu.extract": "Extraer…",
        "menu.delete": "Eliminar",

        // Model
        "doc.untitled": "Sin título",
        "doc.newFolder": "Nueva carpeta",
        "progress.opening": "Abriendo %@…",
        "progress.compressing": "Comprimiendo %@…",
        "progress.encrypting": "Cifrando %@…",
        "progress.splitting": "Dividiendo en volúmenes…",
        "progress.extracting": "Extrayendo…",
        "kind.folder": "Carpeta",
        "kind.document": "Documento",
        "kind.documentExt": "Documento %@",
        "promise.fallback": "archivo",
    ]
}
