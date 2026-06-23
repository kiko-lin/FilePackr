import Foundation
import Combine
import AppKit
import ArchiveBrowser

// Máquinas de estado de las dos operaciones por lotes de la interfaz —añadir y
// extraer— extraídas de ContentView. Cada coordinador posee su cola y su diálogo de
// conflicto (propiedades @Published que dirigen las hojas/diálogos de SwiftUI) y expone
// las transiciones. Las dependencias que no son estado de cola (el documento y la
// ejecución async con su manejo de error) se pasan por llamada, para no acoplar un
// @StateObject dentro de otro ni sacar el manejo de error de la vista.

/// Conflicto al extraer: ya existe un fichero/carpeta con ese nombre en destino. El nombre
/// libre alternativo ("conservar ambos") se calcula al resolver, no aquí, para que tenga en
/// cuenta lo que se haya extraído antes en el mismo lote.
struct ExtractionConflict: Identifiable {
    let id = UUID()
    let plan: ExportPlan
    let destination: URL    // ruta que ya existe
}

/// Conflicto al añadir: ya existe un elemento con ese nombre en la carpeta destino.
struct AddConflict: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let target: FileNode?
}

/// Lo que se va a extraer: uno o varios nodos, o **todo** el archivo. Los planes se
/// construyen al confirmar (cuando ya tenemos la contraseña, si hacía falta). Con varios
/// elementos, cada uno se extrae al destino y resuelve sus conflictos por separado.
struct ExtractRequest: Identifiable {
    let id = UUID()
    let name: String
    let makePlans: () -> [ExportPlan]
}

/// Cola de "Añadir" (arrastre o botón): procesa las URLs una a una, abriendo el diálogo
/// de conflicto cuando un nombre ya existe y reanudando al resolverlo. Al terminar el lote
/// selecciona lo añadido. Es lógica síncrona pura sobre el árbol del documento.
@MainActor
final class AddCoordinator: ObservableObject {
    /// Conflicto de nombre actual (dirige el `confirmationDialog`). `nil` = sin conflicto.
    @Published var conflict: AddConflict?
    private var queue: [URL] = []
    private var target: FileNode?
    private var addedIDs: [FileNode.ID] = []

    /// Arranca un lote: filtra URLs de fichero, fija el destino y procesa la primera.
    func start(_ urls: [URL], into target: FileNode?, doc: ArchiveDocument) {
        let cleaned = urls.filter { $0.isFileURL }
        guard !cleaned.isEmpty else { return }
        self.target = target
        queue = cleaned
        addedIDs = []
        processNext(doc: doc)
    }

    /// Procesa la siguiente URL: si su nombre ya existe en el destino, abre el diálogo de
    /// conflicto (que reanuda al resolverlo); si no, la añade y sigue.
    func processNext(doc: ArchiveDocument) {
        guard !queue.isEmpty else { finish(doc: doc); return }
        let url = queue.removeFirst()
        let name = url.lastPathComponent
        if doc.child(named: name, in: target) != nil {
            conflict = AddConflict(url: url, name: name, target: target)
        } else {
            if let node = doc.addFile(url, into: target) { addedIDs.append(node.id) }
            processNext(doc: doc)
        }
    }

    /// Resolución "Sobrescribir": reemplaza el elemento existente y sigue.
    func overwrite(_ item: AddConflict, doc: ArchiveDocument) {
        conflict = nil
        let existing = doc.child(named: item.name, in: item.target)
        if let node = doc.addFile(item.url, into: item.target, replacing: existing) { addedIDs.append(node.id) }
        processNext(doc: doc)
    }

    /// Resolución "Conservar ambos": añade con un nombre único y sigue.
    func keepBoth(_ item: AddConflict, doc: ArchiveDocument) {
        conflict = nil
        let unique = doc.uniqueChildName(item.name, in: item.target)
        if let node = doc.addFile(item.url, into: item.target, renameTo: unique) { addedIDs.append(node.id) }
        processNext(doc: doc)
    }

    /// Resolución "Cancelar": aborta el lote.
    func cancel(doc: ArchiveDocument) {
        conflict = nil
        queue = []
        finish(doc: doc)
    }

    /// Cierra el lote: fija la selección sobre lo añadido.
    private func finish(doc: ArchiveDocument) {
        if !addedIDs.isEmpty { doc.selectedIDs = Set(addedIDs) }
        addedIDs = []
        target = nil
    }
}

/// Cola de "Extraer" (un nodo, varios o todo): pide destino/contraseña en una hoja y, al
/// confirmar, extrae los planes uno a uno resolviendo conflictos de nombre. La ejecución
/// real (async + manejo de error) la inyecta la vista con la closure `perform`.
@MainActor
final class ExtractCoordinator: ObservableObject {
    /// Petición activa (dirige la hoja de opciones de extracción). `nil` = sin hoja.
    @Published var request: ExtractRequest?
    /// Conflicto de nombre actual (dirige el `confirmationDialog`). `nil` = sin conflicto.
    @Published var conflict: ExtractionConflict?
    /// Carpeta destino mostrada y editable en la hoja.
    @Published var destination = FileManager.default.homeDirectoryForCurrentUser
    @Published var password = ""
    @Published var passwordWrong = false
    private var queue: [ExportPlan] = []
    /// Carpeta destino fijada al confirmar (común a todo el lote).
    private var destinationFolder = FileManager.default.homeDirectoryForCurrentUser
    /// Rutas ya comprometidas en este lote (extraídas o decididas), para que dos elementos
    /// del mismo lote no acaben en el mismo fichero aunque su nombre aún no esté en disco.
    private var claimed: Set<String> = []

    /// Ejecuta la extracción de un plan; la implementa la vista (envuelve el manejo de error).
    typealias Perform = (ExportPlan, URL, Bool) async -> Void

    /// Fija el destino por defecto (carpeta del archivo o fija, según ajustes) y resetea la
    /// contraseña, antes de abrir la hoja.
    func prepareDestination(doc: ArchiveDocument, settings: AppSettings) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let archiveFolder = doc.sourceURL?.deletingLastPathComponent()
        switch settings.extractMode {
        case .archiveFolder:
            destination = archiveFolder ?? settings.fixedExtractFolder ?? home
        case .fixedFolder:
            destination = settings.fixedExtractFolder ?? archiveFolder ?? home
        }
        password = ""
        passwordWrong = false
    }

    /// Abre la hoja de extracción para `name`, con la fábrica de planes a usar al confirmar.
    func begin(name: String, makePlans: @escaping () -> [ExportPlan]) {
        request = ExtractRequest(name: name, makePlans: makePlans)
    }

    /// Confirma la hoja: valida la contraseña (si hace falta), captura el destino, encola
    /// los planes y arranca el procesado en lote.
    func confirm(doc: ArchiveDocument, perform: @escaping Perform) {
        guard let req = request else { return }
        if doc.requiresEntryPassword {
            guard doc.provideEntryPassword(password) else {
                passwordWrong = true
                password = ""
                return
            }
        }
        destinationFolder = destination
        request = nil
        queue = req.makePlans()
        claimed = []
        processNext(doc: doc, perform: perform)
    }

    /// Extrae el siguiente plan en la carpeta destino. Si su nombre ya está ocupado (en disco
    /// o por otro elemento ya resuelto del lote), abre el diálogo; si no, lo reserva, lo extrae
    /// y sigue con el resto.
    func processNext(doc: ArchiveDocument, perform: @escaping Perform) {
        guard !queue.isEmpty else { return }
        let plan = queue.removeFirst()
        let dest = destinationFolder.appendingPathComponent(plan.name)
        if isTaken(dest) {
            conflict = ExtractionConflict(plan: plan, destination: dest)
        } else {
            extract(plan, to: dest, overwrite: false, doc: doc, perform: perform)
        }
    }

    /// Resuelve el conflicto: sobrescribe el destino existente, o conserva ambos extrayendo
    /// a un nombre libre calculado **ahora** (evita disco, lo ya reservado en el lote y los
    /// nombres literales de los elementos del lote aún pendientes, para no robarles el suyo).
    func resolveConflict(_ item: ExtractionConflict, overwrite: Bool,
                         doc: ArchiveDocument, perform: @escaping Perform) {
        let dest = overwrite ? item.destination : freeDestination(for: item.destination)
        conflict = nil
        extract(item.plan, to: dest, overwrite: overwrite, doc: doc, perform: perform)
    }

    /// Reserva el destino, lo extrae en segundo plano y, al terminar, procesa el siguiente.
    private func extract(_ plan: ExportPlan, to dest: URL, overwrite: Bool,
                         doc: ArchiveDocument, perform: @escaping Perform) {
        claimed.insert(dest.path)
        Task {
            await perform(plan, dest, overwrite)
            processNext(doc: doc, perform: perform)
        }
    }

    /// `true` si la ruta ya existe en disco o ya está reservada por otro elemento del lote.
    private func isTaken(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || claimed.contains(url.path)
    }

    /// Primer nombre libre «<base> N.<ext>» (separador de espacio, como al añadir) que no
    /// choque con disco, lo ya reservado, ni el nombre literal de otro plan aún en la cola.
    private func freeDestination(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let pending = Set(queue.map { destinationFolder.appendingPathComponent($0.name).path })
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !isTaken(candidate), !pending.contains(candidate.path) { return candidate }
            n += 1
        }
    }

    /// Cancela el lote desde el diálogo de conflicto.
    func cancelConflict() {
        conflict = nil
        queue = []
    }

    /// "Elegir…": abre el navegador de carpetas para cambiar el destino.
    func chooseFolder(prompt: String) {
        if let url = chooseFolderPanel(prompt: prompt, startingAt: destination) {
            destination = url
        }
    }
}

/// Estado de las opciones de "Guardar"/"Exportar" (formato/cifrado/contraseña/volúmenes), que
/// el panel nativo incrusta como **vista accesoria** (`SavePanelAccessory`). No orquesta la hoja
/// ni la escritura: solo guarda el estado editable, lo prerrellena y lo resuelve al confirmar.
@MainActor
final class SaveCoordinator: ObservableObject {
    @Published var format: ArchiveFormat = .zip
    @Published var encryption: ZipEncryption = .none
    @Published var password = ""
    @Published var splitEnabled = false
    @Published var volumeSize: Double = 100
    @Published var volumeUnit: VolumeUnit = .megabytes

    /// Prerrellena con el formato/cifrado/volúmenes actuales (documento nuevo: defaults de
    /// Ajustes; abierto: lo que traía el archivo).
    func prefill(doc: ArchiveDocument, settings: AppSettings) {
        let isNew = doc.sourceURL == nil
        var fmt = isNew ? settings.defaultFormat : doc.saveFormat
        if !fmt.isWritable { fmt = .zip }                            // rar → zip
        if fmt.isSingleFileOnly && !doc.isSingleFile { fmt = .zip }  // gz/xz/bz2 solo si es un fichero
        format = fmt
        encryption = isNew ? settings.defaultEncryption : doc.saveEncryption
        password = ""
        if let size = doc.saveVolumeSize {
            splitEnabled = true
            volumeUnit = .megabytes
            volumeSize = max(1, (Double(size) / Double(VolumeUnit.megabytes.multiplier)).rounded())
        } else {
            splitEnabled = false
        }
    }

    /// Opciones derivadas del estado actual, listas para escribir (cifrado/contraseña solo si el
    /// formato los admite; volúmenes solo si se activó y el tamaño es válido).
    var resolved: (format: ArchiveFormat, encryption: ZipEncryption, password: String?, volumeSize: Int?) {
        let cipher = format.supportsEncryption ? encryption : .none
        let pwd = cipher == .none ? nil : password
        let volumes = (splitEnabled && format.supportsVolumeSplit && volumeSize > 0)
            ? Int(volumeSize * Double(volumeUnit.multiplier)) : nil
        return (format, cipher, pwd, volumes)
    }

    /// Falta la contraseña del cifrado elegido (para que el panel no deje confirmar).
    var needsPassword: Bool { format.supportsEncryption && encryption != .none && password.isEmpty }
}
