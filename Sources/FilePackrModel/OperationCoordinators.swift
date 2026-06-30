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
public struct ExtractionConflict: Identifiable {
    public let id = UUID()
    public let plan: ExportPlan
    public let destination: URL // ruta que ya existe
}

/// Conflicto al añadir: ya existe un elemento con ese nombre en la carpeta destino.
public struct AddConflict: Identifiable {
    public let id = UUID()
    public let url: URL
    public let name: String
    public let target: FileNode?
}

/// Lo que se va a extraer: uno o varios nodos, o **todo** el archivo. Los planes se
/// construyen al confirmar (cuando ya tenemos la contraseña, si hacía falta). Con varios
/// elementos, cada uno se extrae al destino y resuelve sus conflictos por separado.
public struct ExtractRequest: Identifiable {
    public let id = UUID()
    /// Título de la hoja, según la acción ("Extraer todo" / "…archivo seleccionado" / "…archivos…").
    public let title: String
    public let makePlans: () -> [ExportPlan]
}

/// Cola de "Añadir" (arrastre o botón): procesa las URLs una a una, abriendo el diálogo
/// de conflicto cuando un nombre ya existe y reanudando al resolverlo. Al terminar el lote
/// selecciona lo añadido. Es lógica síncrona pura sobre el árbol del documento.
@MainActor
public final class AddCoordinator: ObservableObject {
    public init() {}
    /// Conflicto de nombre actual (dirige el `confirmationDialog`). `nil` = sin conflicto.
    @Published public var conflict: AddConflict?
    private var queue: [URL] = []
    private var target: FileNode?
    private var addedIDs: [FileNode.ID] = []
    /// Política de ocultos/sistema del lote en curso (fijada al arrancar).
    private var hiddenPolicy: AddHiddenPolicy = .excludeSystemFiles
    /// Total de elementos omitidos por la política en el lote en curso.
    private var excludedCount = 0
    /// Se llama al cerrar el lote con el total omitido (>0) para que la vista lo avise.
    private var onFinish: ((Int) -> Void)?

    /// Arranca un lote: filtra URLs de fichero, fija el destino y procesa la primera. `onFinish`
    /// recibe, al cerrar el lote, cuántos elementos omitió la política (para avisar al usuario).
    public func start(_ urls: [URL], into target: FileNode?, doc: ArchiveDocument,
               hiddenPolicy: AddHiddenPolicy = .excludeSystemFiles,
               onFinish: ((Int) -> Void)? = nil) {
        let cleaned = urls.filter { $0.isFileURL }
        guard !cleaned.isEmpty else { return }
        self.target = target
        self.hiddenPolicy = hiddenPolicy
        self.onFinish = onFinish
        excludedCount = 0
        queue = cleaned
        addedIDs = []
        processNext(doc: doc)
    }

    /// Procesa la siguiente URL: si su nombre ya existe en el destino, abre el diálogo de
    /// conflicto (que reanuda al resolverlo); si no, la añade y sigue.
    public func processNext(doc: ArchiveDocument) {
        guard !queue.isEmpty else { finish(doc: doc); return }
        let url = queue.removeFirst()
        let name = url.lastPathComponent
        if doc.child(named: name, in: target) != nil {
            conflict = AddConflict(url: url, name: name, target: target)
        } else {
            let result = doc.addFile(url, into: target, hiddenPolicy: hiddenPolicy)
            if let node = result.node { addedIDs.append(node.id) }
            excludedCount += result.excluded
            processNext(doc: doc)
        }
    }

    /// Resolución "Sobrescribir": reemplaza el elemento existente y sigue.
    public func overwrite(_ item: AddConflict, doc: ArchiveDocument) {
        conflict = nil
        let existing = doc.child(named: item.name, in: item.target)
        let result = doc.addFile(item.url, into: item.target, replacing: existing, hiddenPolicy: hiddenPolicy)
        if let node = result.node { addedIDs.append(node.id) }
        excludedCount += result.excluded
        processNext(doc: doc)
    }

    /// Resolución "Conservar ambos": añade con un nombre único y sigue.
    public func keepBoth(_ item: AddConflict, doc: ArchiveDocument) {
        conflict = nil
        let unique = doc.uniqueChildName(item.name, in: item.target)
        let result = doc.addFile(item.url, into: item.target, renameTo: unique, hiddenPolicy: hiddenPolicy)
        if let node = result.node { addedIDs.append(node.id) }
        excludedCount += result.excluded
        processNext(doc: doc)
    }

    /// Resolución "Cancelar": aborta el lote.
    public func cancel(doc: ArchiveDocument) {
        conflict = nil
        queue = []
        finish(doc: doc)
    }

    /// Cierra el lote: fija la selección sobre lo añadido y avisa de lo omitido (si lo hubo).
    private func finish(doc: ArchiveDocument) {
        if !addedIDs.isEmpty { doc.selectedIDs = Set(addedIDs) }
        addedIDs = []
        target = nil
        if excludedCount > 0 { onFinish?(excludedCount) }
        excludedCount = 0
        onFinish = nil
    }
}

/// Cola de "Extraer" (un nodo, varios o todo): pide destino/contraseña en una hoja y, al
/// confirmar, extrae los planes uno a uno resolviendo conflictos de nombre. La ejecución
/// real (async + manejo de error) la inyecta la vista con la closure `perform`.
@MainActor
public final class ExtractCoordinator: ObservableObject {
    public init() {}
    /// Petición activa (dirige la hoja de opciones de extracción). `nil` = sin hoja.
    @Published public var request: ExtractRequest?
    /// Conflicto de nombre actual (dirige el `confirmationDialog`). `nil` = sin conflicto.
    @Published public var conflict: ExtractionConflict?
    /// Carpeta destino mostrada y editable en la hoja.
    @Published public var destination = FileManager.default.homeDirectoryForCurrentUser
    private var queue: [ExportPlan] = []
    /// Carpeta destino fijada al confirmar (común a todo el lote).
    private var destinationFolder = FileManager.default.homeDirectoryForCurrentUser
    /// Rutas ya comprometidas en este lote (extraídas o decididas), para que dos elementos
    /// del mismo lote no acaben en el mismo fichero aunque su nombre aún no esté en disco.
    private var claimed: Set<String> = []
    /// Rutas **realmente escritas** en este lote (cada ítem completado con éxito). Si se cancela
    /// a media tanda, son las que quedan en disco y sobre las que se ofrece conservar/eliminar.
    private var extractedURLs: [URL] = []

    /// Ejecuta la extracción de un plan; la implementa la vista (envuelve el manejo de error).
    /// Devuelve `true` si el ítem se escribió con éxito (no cancelado/erróneo).
    public typealias Perform = (ExportPlan, URL, Bool) async -> Bool

    /// Fija el destino por defecto (carpeta del archivo o fija, según ajustes) antes de abrir
    /// la hoja. La contraseña, si el archivo está cifrado, se pide antes (al desbloquear).
    public func prepareDestination(doc: ArchiveDocument, settings: AppSettings) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let archiveFolder = doc.sourceURL?.deletingLastPathComponent()
        switch settings.extractMode {
        case .archiveFolder:
            destination = archiveFolder ?? settings.fixedExtractFolder ?? home
        case .fixedFolder:
            destination = settings.fixedExtractFolder ?? archiveFolder ?? home
        case .lastUsedFolder:
            destination = settings.lastUsedExtractFolder ?? archiveFolder ?? home
        }
    }

    /// Abre la hoja de extracción con `title`, y la fábrica de planes a usar al confirmar.
    public func begin(title: String, makePlans: @escaping () -> [ExportPlan]) {
        request = ExtractRequest(title: title, makePlans: makePlans)
    }

    /// Confirma la hoja: captura el destino, encola los planes y arranca el procesado en lote
    /// (el archivo ya está desbloqueado en este punto).
    public func confirm(doc: ArchiveDocument, settings: AppSettings, perform: @escaping Perform) {
        guard let req = request else { return }
        destinationFolder = destination
        settings.lastUsedExtractFolder = destination   // alimenta el modo "última carpeta usada"
        request = nil
        queue = req.makePlans()
        claimed = []
        extractedURLs = []
        processNext(doc: doc, perform: perform)
    }

    /// Extrae el siguiente plan en la carpeta destino. Si su nombre ya está ocupado (en disco
    /// o por otro elemento ya resuelto del lote), abre el diálogo; si no, lo reserva, lo extrae
    /// y sigue con el resto.
    public func processNext(doc: ArchiveDocument, perform: @escaping Perform) {
        guard !queue.isEmpty else {
            // Lote terminado (sin conflicto pendiente): limpiar el estado para no dejar rutas
            // residuales. Si no, una cancelación posterior de otra operación que comparte el
            // overlay (arrastre al Finder, guardado) las leería como una extracción parcial y
            // ofrecería "Conservar/Eliminar" sobre ficheros de un lote anterior ya completado.
            if conflict == nil { claimed.removeAll(); extractedURLs.removeAll() }
            return
        }
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
    public func resolveConflict(_ item: ExtractionConflict, overwrite: Bool,
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
            if await perform(plan, dest, overwrite) { extractedURLs.append(dest) }
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
        let pending = Set(queue.map { destinationFolder.appendingPathComponent($0.name).path })
        let name = UniqueName.next(for: url.lastPathComponent) { candidate in
            let c = dir.appendingPathComponent(candidate)
            return isTaken(c) || pending.contains(c.path)
        }
        return dir.appendingPathComponent(name)
    }

    /// Cancela el lote desde el diálogo de conflicto y devuelve las rutas ya extraídas (igual
    /// que `cancelBatch`, para ofrecer conservar/eliminar).
    @discardableResult
    public func cancelConflict() -> [URL] {
        conflict = nil
        queue = []
        defer { extractedURLs = [] }
        return extractedURLs
    }

    /// Vacía la cola pendiente y **devuelve las rutas ya extraídas** del lote (para ofrecer
    /// conservar/eliminar). Tras cancelar la extracción en curso, el lote no sigue con los
    /// elementos restantes (el `processNext` de la tarea actual encontrará la cola vacía); el
    /// ítem en vuelo, al cancelarse, no se cuenta como extraído (su temporal se descarta).
    @discardableResult
    public func cancelBatch() -> [URL] {
        queue = []
        defer { extractedURLs = [] }
        return extractedURLs
    }

    /// "Elegir…": abre el navegador de carpetas para cambiar el destino.
    public func chooseFolder(prompt: String) {
        if let url = chooseFolderPanel(prompt: prompt, startingAt: destination) {
            destination = url
        }
    }
}

/// Flujo de "Guardar"/"Exportar" con un **diálogo propio** (compacto, localizado): posee el
/// estado editable (nombre, carpeta destino, formato/cifrado/contraseña/volúmenes) y su
/// orquestación. El navegador de carpetas nativo solo aparece, transitorio, al pulsar "Elegir…".
/// La escritura real (async + manejo de error) la inyecta la vista con la closure `perform`.
@MainActor
public final class SaveCoordinator: ObservableObject {
    public init() {}
    /// Hoja de opciones abierta. `false` = cerrada.
    @Published public var showingOptions = false
    /// La hoja está abierta para **Exportar** (copia aparte) en vez de **Guardar**.
    @Published public private(set) var isExport = false
    /// Nombre base del archivo (sin extensión, que la añade el formato).
    @Published public var name = ""
    /// Carpeta destino (se cambia con "Elegir…").
    @Published public var destination = FileManager.default.homeDirectoryForCurrentUser
    @Published public var format: ArchiveFormat = .zip
    @Published public var encryption: ZipEncryption = .none
    @Published public var level: CompressionLevel = .default
    @Published public var password = ""
    @Published public var splitEnabled = false
    @Published public var volumeSize: Double = 100
    @Published public var volumeUnit: VolumeUnit = .megabytes
    /// Acción a ejecutar tras un guardado con éxito (p. ej. cerrar). Se descarta si se cancela
    /// o si el guardado falla.
    private var pendingAfterSave: (() -> Void)?

    /// Ejecuta el guardado/exportación a `url`. Devuelve `true` si el documento quedó guardado
    /// (para encadenar la acción pendiente). La implementa la vista.
    public typealias Perform = (_ isExport: Bool, _ url: URL, _ format: ArchiveFormat,
                         _ encryption: ZipEncryption, _ password: String?, _ volumeSize: Int?,
                         _ level: CompressionLevel) async -> Bool

    /// Prerrellena con nombre/carpeta y el formato/cifrado/volúmenes actuales (documento nuevo:
    /// defaults de Ajustes; abierto: lo que traía el archivo).
    public func prefill(doc: ArchiveDocument, settings: AppSettings, baseName: String) {
        let isNew = doc.sourceURL == nil
        var fmt = isNew ? settings.resolvedFormat : doc.saveFormat
        if !fmt.isWritable { fmt = .zip }                            // rar → zip
        if fmt.isSingleFileOnly && !doc.isSingleFile { fmt = .zip }  // gz/xz/bz2 solo si es un fichero
        format = fmt
        encryption = isNew ? settings.resolvedEncryption : doc.saveEncryption
        level = isNew ? settings.resolvedLevel : doc.saveLevel
        password = ""
        name = baseName
        destination = doc.sourceURL?.deletingLastPathComponent()
            ?? settings.fixedExtractFolder
            ?? FileManager.default.homeDirectoryForCurrentUser
        if let size = doc.saveVolumeSize {
            splitEnabled = true
            volumeUnit = .megabytes
            volumeSize = max(1, (Double(size) / Double(VolumeUnit.megabytes.multiplier)).rounded())
        } else {
            splitEnabled = false
        }
    }

    /// Abre la hoja para **Guardar**, recordando la acción a ejecutar al terminar con éxito.
    public func beginSave(then completion: (() -> Void)?) {
        isExport = false
        pendingAfterSave = completion
        showingOptions = true
    }

    /// Abre la hoja para **Exportar** una copia aparte (no encadena acción).
    public func beginExport() {
        isExport = true
        pendingAfterSave = nil
        showingOptions = true
    }

    /// URL destino resultante (carpeta + nombre + extensión del formato, sin duplicarla).
    public var resolvedURL: URL {
        let ext = format.fileExtension
        let fileName = name.hasSuffix("." + ext) ? name : "\(name).\(ext)"
        return destination.appendingPathComponent(fileName)
    }

    /// Falta la contraseña del cifrado elegido.
    public var needsPassword: Bool { format.supportsEncryption && encryption != .none && password.isEmpty }

    /// El botón de confirmar está disponible (nombre no vacío, contraseña si procede, tamaño válido).
    public var canConfirm: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !needsPassword
            && !(splitEnabled && format.supportsVolumeSplit && volumeSize <= 0)
    }

    /// Confirma: cierra la hoja y escribe en `resolvedURL`. Tras guardar (no exportar) ejecuta la
    /// acción pendiente solo si tuvo éxito, pero la limpia siempre.
    public func confirm(settings: AppSettings, perform: @escaping Perform) {
        guard canConfirm else { return }
        // Recuerda la selección para la opción "Último usado" (la contraseña no se guarda).
        settings.lastUsedFormat = format
        settings.lastUsedEncryption = encryption
        settings.lastUsedLevel = level
        showingOptions = false
        let exporting = isExport
        let url = resolvedURL
        let cipher = format.supportsEncryption ? encryption : .none
        let pwd = cipher == .none ? nil : password
        let volumes = (splitEnabled && format.supportsVolumeSplit && volumeSize > 0)
            ? Int(volumeSize * Double(volumeUnit.multiplier)) : nil
        let fmt = format
        let lvl = format.honorsCompressionLevel ? level : .default
        Task {
            let saved = await perform(exporting, url, fmt, cipher, pwd, volumes, lvl)
            if !exporting {
                let after = pendingAfterSave
                pendingAfterSave = nil
                if saved { after?() }
            }
        }
    }

    /// Cierra la hoja sin guardar (botón Cancelar): descarta la acción pendiente.
    public func cancel() {
        showingOptions = false
        pendingAfterSave = nil
    }

    /// "Elegir…": abre el navegador de carpetas (nativo, transitorio) para cambiar el destino.
    public func chooseFolder(prompt: String) {
        if let url = chooseFolderPanel(prompt: prompt, startingAt: destination) { destination = url }
    }
}
