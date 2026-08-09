import Foundation
import Combine
import UniformTypeIdentifiers
import ArchiveBrowser

/// Estado de cifrado de un documento. Un único valor hace imposible representar estados
/// contradictorios (p. ej. pedir a la vez contraseña de apertura y de entrada).
public enum LockState: Equatable {
    /// Sin cifrado pendiente: el documento es editable/extraíble.
    case unlocked
    /// Un 7z con cabeceras cifradas necesita contraseña para **abrirse**; `url` es el archivo
    /// pendiente de reintentar al darla.
    case needsOpenPassword(URL)
    /// El archivo está abierto pero sus **entradas** están cifradas y aún no hay contraseña.
    case needsEntryPassword
}

/// Errores propios del documento (no del motor); la capa de vista los traduce.
public enum ArchiveDocumentError: Error {
    /// No podemos abrir/extraer un archivo **cifrado** de este formato. Hoy solo se da con **RAR**:
    /// la libarchive del sistema no descifra RAR (ni RAR4 ni RAR5), solo el `unrar` propietario de
    /// RARLAB, así que pedir contraseña no serviría (la correcta también falla). Ver `docs/fixtures/`.
    /// Lleva el formato para que el mensaje diga de qué tipo se trata.
    case encryptionUnsupported(format: ArchiveFormat)
    /// Un `.rar` suelto declara en su propia cabecera (`MHD_VOLUME`) que es parte de un conjunto
    /// multivolumen, pero no se encontraron las demás partes (ni por nombre reconocido — ver
    /// `RarVolumes` — ni ninguna) y la apertura falló del todo. Si hubiera abierto parcialmente,
    /// no se lanza esto: se marca `ArchiveDocument.incompleteVolumes` y se muestra lo que haya.
    case rarVolumeSetIncomplete
    /// Ni la extensión ni la firma (magic bytes) del fichero coinciden con ningún formato
    /// soportado. Se lanza solo si, además, la apertura como ZIP (el valor por defecto) falla —
    /// si por casualidad abre bien, se deja pasar sin avisar.
    case unrecognizedFormat
}

/// Documento de trabajo: el árbol de elementos que acabará siendo un ZIP.
/// Mantiene, si se abrió un ZIP existente, sus bytes originales para poder
/// extraer o copiar entradas sin recomprimir.
@MainActor
public final class ArchiveDocument: ObservableObject {

    public init() {}

    @Published public var roots: [FileNode] = []
    /// Selección actual (varios elementos): para arrastrar, extraer o eliminar en lote.
    @Published public var selectedIDs: Set<FileNode.ID> = []

    /// Nombre mostrado en la barra de documento (fichero abierto o "Sin título").
    @Published public private(set) var documentName: String = ""
    /// Hay modificaciones sin guardar desde la última apertura/guardado.
    @Published public private(set) var hasUnsavedChanges: Bool = false
    /// Fichero de origen, si se abrió/guardó uno (para "Guardar" sin volver a preguntar).
    @Published public private(set) var sourceURL: URL?
    /// Se incrementa con cada cambio estructural (no al seleccionar). La vista de
    /// lista lo usa para recargar solo cuando hace falta.
    @Published public private(set) var revision = 0
    /// Operación larga en curso (comprimir/extraer): muestra la barra de progreso.
    @Published public var progress: ProgressState?
    /// Cifrado elegido al guardar (se recuerda para el botón Guardar).
    @Published public private(set) var saveEncryption: ZipEncryption = .none
    private var savePassword: String?
    /// Formato del contenedor abierto (para leer las entradas de los nodos).
    @Published public private(set) var format: ArchiveFormat = .zip
    /// Formato por defecto del diálogo Guardar (se recuerda tras guardar).
    @Published public private(set) var saveFormat: ArchiveFormat = .zip
    /// Tamaño de volumen en bytes si el documento se guarda dividido (nil = un fichero).
    @Published public private(set) var saveVolumeSize: Int?
    /// Nivel de compresión elegido al guardar (se recuerda para el botón Guardar).
    @Published public private(set) var saveLevel: CompressionLevel = .default
    /// Estado de cifrado del documento (única fuente de verdad: estados imposibles de
    /// contradecir). La vista observa los derivados `requiresEntryPassword`/`requiresOpenPassword`.
    @Published public private(set) var lockState: LockState = .unlocked
    /// Necesitamos la contraseña de las **entradas** cifradas del archivo abierto (para
    /// extraer/editar). Derivado de `lockState`.
    public var requiresEntryPassword: Bool { lockState == .needsEntryPassword }
    /// Un 7z con cabeceras cifradas necesita contraseña para **abrirse** (no solo extraer).
    /// Derivado de `lockState`.
    public var requiresOpenPassword: Bool { if case .needsOpenPassword = lockState { return true }; return false }
    /// Contraseña para descifrar las entradas del archivo abierto.
    private var entryPassword: String?

    public private(set) var sourceArchive: ArchiveContainer?

    /// El documento abierto es un `.rar` cuya cabecera declara ser parte de un conjunto
    /// multivolumen, pero no se encontraron (todas) las demás partes: `roots` puede estar
    /// incompleto. La vista muestra un aviso persistente no bloqueante mientras sea `true` (a
    /// diferencia de `ArchiveDocumentError.rarVolumeSetIncomplete`, que se lanza cuando no hay
    /// NADA que mostrar). Modelo emite el token, no el texto — mismo criterio que `ProgressActivity`.
    @Published public private(set) var incompleteVolumes: Bool = false

    /// Temporal con las partes de un multivolumen (esquema propio de FilePackr) concatenadas,
    /// mapeado en `sourceArchive`. Se borra al cerrar o al abrir otro archivo. Los volúmenes RAR
    /// **nativos** (`RarVolumes`) no pasan por aquí: `sourceArchive` guarda directamente la lista
    /// de ficheros (`.rarVolumes`) y no hay temporal que limpiar.
    private var joinedVolumesTemp: URL?

    /// Hay un documento activo (abierto o nuevo empezado). Sentinela para no reiniciar
    /// el estado al añadir/crear sobre un documento ya en marcha.
    private var hasActiveDocument = false

    public var isEmpty: Bool { roots.isEmpty }

    // MARK: - Entrada de elementos (arrastre o botón Añadir)

    /// Si lo que llega es un único archivo abrible con el documento vacío, devuelve su URL
    /// (para abrirlo como base); si no, `nil` (hay que añadirlo al documento actual). La vista
    /// usa esto para decidir y, en el caso de añadir, resolver conflictos de nombre.
    public func archiveToOpen(from urls: [URL]) -> URL? {
        let cleaned = urls.filter { $0.isFileURL }
        guard isEmpty, cleaned.count == 1,
              !isDirectory(cleaned[0]), isOpenableArchive(cleaned[0]) else { return nil }
        return cleaned[0]
    }

    /// Carpeta destino para Añadir (según la selección), expuesta para que la vista detecte
    /// conflictos de nombre antes de insertar.
    public func addTargetFolder() -> FileNode? { insertionTargetFolder() }

    /// Hijo existente con ese nombre dentro de `target` (o en la raíz), si lo hay.
    public func child(named name: String, in target: FileNode?) -> FileNode? {
        (target?.children ?? roots).first { $0.name == name }
    }

    /// Nombre de fichero libre dentro de `target` («nombre 2.ext», «nombre 3.ext»…),
    /// conservando la extensión.
    public func uniqueChildName(_ name: String, in target: FileNode?) -> String {
        let taken = Set((target?.children ?? roots).map(\.name))
        return UniqueName.next(for: name) { taken.contains($0) }
    }

    /// Añade un único fichero/carpeta del disco dentro de `target` y devuelve el nodo creado.
    /// `replacing` elimina antes el elemento existente (sobrescribir); `renameTo` fuerza un
    /// nombre libre (conservar ambos). No toca la selección: la fija la vista al acabar el lote.
    /// Devuelve el nodo añadido y cuántos elementos omitió la política al expandir las carpetas.
    @discardableResult
    public func addFile(_ url: URL, into target: FileNode?, replacing existing: FileNode? = nil,
                 renameTo newName: String? = nil,
                 hiddenPolicy: AddHiddenPolicy = .excludeSystemFiles) -> (node: FileNode?, excluded: Int) {
        guard !isLocked else { return (nil, 0) }
        if !hasActiveDocument { beginNewDocument() }
        if let existing { remove(existing) }
        let imported = ArchiveTreeBuilder.importFromDisk(url, hiddenPolicy: hiddenPolicy)
        if let newName { imported.node.name = newName }
        insert(imported.node, into: target)
        markChanged()
        return (imported.node, imported.excluded)
    }

    /// Abre un ZIP existente y muestra su contenido (sin descomprimirlo). La lectura
    /// y el parseo del índice van en segundo plano para no bloquear la interfaz.
    public func openArchive(_ url: URL, passphrase: String? = nil) async throws {
        // ¿Conjunto RAR **nativo** (part1.rar/part2.rar… o .rar+.r00…)? Se abre vía la API de
        // volúmenes de libarchive: no se puede concatenar a pelo, cada volumen lleva su propia
        // cabecera intercalada (a diferencia del esquema propio de FilePackr, más abajo).
        let rarVolumes = RarVolumes.parts(for: url)
        // Si no, ¿forma parte de un juego de volúmenes del esquema propio? Reunimos las partes en
        // orden; la primera (nombre.zip) da el nombre base y el formato.
        let parts = rarVolumes == nil ? VolumeStore.parts(for: url) : []
        let baseURL = rarVolumes?.first ?? parts.first ?? url
        // Por extensión y, si no la reconoce, por la firma (magic bytes) de la cabecera. `nil`
        // si NINGUNA de las dos reconoce nada — distinto de "explícitamente .zip" para poder
        // avisar de formato no reconocido en vez de fingir que es un zip roto (más abajo).
        let explicitFormat = ArchiveFormat.detectByExtension(baseURL)
            ?? peekHeader(baseURL).flatMap(ArchiveFormat.detectByMagic)
        let detected = explicitFormat ?? .zip
        // Indeterminado siempre: leer el índice es pura CPU en memoria (imperceptible, confirmado
        // por benchmark) salvo que el disco sea lento (externo/red), en cuyo caso el tiempo real se
        // va en una única lectura del central directory *antes* de que el bucle por entrada pueda
        // reportar nada — un % ahí no reflejaría el tiempo real, solo daría la falsa impresión de
        // que se ha quedado colgada. Ver `ZipReader.listEntries`.
        progress = ProgressState(kind: .opening(baseURL.lastPathComponent), fraction: nil)
        defer { progress = nil }
        incompleteVolumes = false   // no arrastrar el aviso de una apertura anterior

        // Si venía troceado (esquema propio), limpiamos cualquier temporal de una apertura anterior.
        discardJoinedVolumesTemp()
        // Red defensiva: restos de un guardado interrumpido por un cierre forzado anterior.
        WorkFile.cleanStale(in: baseURL.deletingLastPathComponent())
        let fallbackName = baseURL.deletingPathExtension().lastPathComponent
        let result: ArchiveReadResult
        let joinedTemp: URL?
        let incompleteVolumesResult: Bool
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () -> (ArchiveReadResult, URL?, Bool) in
                if let rarVolumes {
                    // Sin fichero temporal: la lista de volúmenes ya es el "container". El nombre
                    // reconoce una secuencia contigua, pero eso no garantiza que sea el conjunto
                    // COMPLETO (podría faltar el último volumen) — de ahí que también miremos
                    // `truncated` aquí, igual que en el camino de abajo. Si encima no queda ni una
                    // entrada legible, no hay nada que mostrar: mismo trato que un `.rar` suelto sin
                    // nada rescatable.
                    let (entries, _, truncated) = try LibArchive.listEntries(volumes: rarVolumes, passphrase: passphrase)
                    if entries.isEmpty { throw ArchiveDocumentError.rarVolumeSetIncomplete }
                    let result = ArchiveReadResult(format: .rar, container: .rarVolumes(rarVolumes), entries: entries, truncated: truncated)
                    return (result, nil, truncated)
                }
                // Multivolumen (esquema propio): concatenar las partes a un temporal y **mapearlo**,
                // en vez de cargar todas las partes en RAM (Volumes.join). Mono-volumen: mapear directo.
                let temp = parts.count == 1 ? nil : try VolumeStore.joinToTemporaryFile(parts)
                let data = try Data(contentsOf: temp ?? parts[0], options: .mappedIfSafe)
                // .rar suelto cuya propia cabecera dice pertenecer a un conjunto multivolumen
                // (nombre no reconocido por `RarVolumes`, o hueco en la secuencia): distingue más
                // abajo entre "falló del todo" (nada que mostrar) y "abrió parcial" (aviso suave).
                // Aquí no usamos `r.truncated`: al leer un único volumen suelto (no vía la API de
                // volúmenes) libarchive a veces da un EOF limpio justo al quedarse sin datos, sin
                // marcar error — pero `isVolumePart` ya nos dice, con independencia de eso, que por
                // definición falta el resto del conjunto.
                let isVolumePart = detected == .rar && RarVolumes.isMultiVolumePart(data)
                do {
                    let r = try detected.codec.open(data, fallbackName: fallbackName,
                                                    passphrase: passphrase, progress: nil)
                    // Sin ni una entrada legible: nada que mostrar, tratarlo igual que si hubiera
                    // lanzado (el `catch` de abajo limpia el temporal y lo convierte en el error
                    // adecuado).
                    if isVolumePart, r.entries.isEmpty { throw ArchiveDocumentError.rarVolumeSetIncomplete }
                    return (r, temp, isVolumePart)
                } catch {
                    if let temp { try? FileManager.default.removeItem(at: temp) }
                    if isVolumePart { throw ArchiveDocumentError.rarVolumeSetIncomplete }
                    if explicitFormat == nil { throw ArchiveDocumentError.unrecognizedFormat }
                    throw error
                }
            }.value
            result = loaded.0
            joinedTemp = loaded.1
            incompleteVolumesResult = loaded.2
        } catch let error as LibArchiveError where error == .passphraseRequired {
            // RAR con cabeceras cifradas: libarchive NO descifra RAR (ni con la clave correcta),
            // así que pedir contraseña sería un bucle sin salida. Avisar de que no se soporta.
            if detected == .rar { throw ArchiveDocumentError.encryptionUnsupported(format: detected) }
            // 7z con cabeceras cifradas: sí sabemos descifrar → pedir contraseña para abrir.
            lockState = .needsOpenPassword(url)
            return
        }

        joinedVolumesTemp = joinedTemp
        format = result.format
        sourceArchive = result.container
        roots = ArchiveTreeBuilder.build(from: result.entries)
        incompleteVolumes = incompleteVolumesResult
        selectedIDs = []
        sourceURL = baseURL
        documentName = baseURL.lastPathComponent
        hasActiveDocument = true
        entryPassword = passphrase
        // ZIP y 7z pueden tener entradas cifradas; si no dimos contraseña al abrir,
        // se pedirá al extraer/previsualizar. tar/gz/xz/bz2 nunca cifran.
        let entriesLocked = passphrase == nil
            && (result.format == .zip || result.format.usesLibArchive)
            && result.entries.contains { $0.isEncrypted }
        lockState = entriesLocked ? .needsEntryPassword : .unlocked
        // Al re-guardar, conservar el cifrado original (con su contraseña, cuando se dé).
        saveEncryption = result.format == .zip ? detectedEncryption(in: result.entries) : .none
        savePassword = nil
        saveFormat = result.format
        // Si venía en volúmenes, recordar el tamaño (el de la primera parte) para re-guardar igual.
        if parts.count > 1, let size = try? parts[0].resourceValues(forKeys: [.fileSizeKey]).fileSize {
            saveVolumeSize = size
        } else {
            saveVolumeSize = nil
        }
        hasUnsavedChanges = false
        changed()
    }

    /// Tipo de cifrado de las entradas (para conservarlo al re-guardar).
    private func detectedEncryption(in entries: [ArchiveEntry]) -> ZipEncryption {
        if entries.contains(where: { $0.isAESEncrypted }) { return .aes256 }
        if entries.contains(where: { $0.isEncrypted }) { return .zipCrypto }
        return .none
    }

    /// Da la contraseña para las entradas cifradas del archivo abierto. La valida
    /// extrayendo la primera entrada cifrada; devuelve `false` si es incorrecta.
    public func provideEntryPassword(_ password: String) -> Bool {
        // Si hay una entrada cifrada, validar la contraseña extrayéndola; si no la hay,
        // aceptarla sin más. En ambos casos se aplican los mismos efectos (una sola vez).
        if let archive = sourceArchive,
           let node = firstEncryptedFile(in: roots),
           case .entry(let entry) = node.source {
            do {
                _ = try format.codec.entryData(for: entry, in: archive, password: password)
            } catch {
                return false
            }
        }
        entryPassword = password
        savePassword = password   // misma contraseña para re-guardar cifrado
        lockState = .unlocked
        changed()
        return true
    }

    /// Da la contraseña para **abrir** un 7z con cabeceras cifradas. Reintenta la
    /// apertura; devuelve `false` si es incorrecta (sigue pidiéndola).
    public func provideOpenPassword(_ password: String) async -> Bool {
        guard case .needsOpenPassword(let url) = lockState else { return false }
        do {
            try await openArchive(url, passphrase: password)
            return !requiresOpenPassword   // openArchive la limpia si funcionó
        } catch {
            return false   // contraseña incorrecta
        }
    }

    private func firstEncryptedFile(in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.isDirectory {
                if let found = firstEncryptedFile(in: node.children) { return found }
            } else if case .entry(let entry) = node.source, entry.isEncrypted {
                return node
            }
        }
        return nil
    }

    /// Empieza un documento nuevo, aún sin guardar. El nombre mostrado ("Sin título")
    /// lo resuelve la vista; el modelo deja `documentName` vacío hasta que se guarde.
    public func beginNewDocument() {
        sourceURL = nil
        documentName = ""
        hasActiveDocument = true
        hasUnsavedChanges = false
        entryPassword = nil
        lockState = .unlocked
        saveEncryption = .none
        savePassword = nil
        format = .zip
        saveFormat = .zip
        saveVolumeSize = nil
    }

    /// Añade ficheros/carpetas del disco dentro de la carpeta destino actual.
    public func addFiles(_ urls: [URL]) {
        addFiles(urls, into: insertionTargetFolder())
    }

    /// Añade ficheros/carpetas del disco dentro de `target` (o la raíz si es `nil`).
    /// Deja seleccionados los elementos añadidos para que la vista los revele
    /// (desplegando la carpeta destino) y les dé el foco, como al crear una carpeta.
    @discardableResult
    public func addFiles(_ urls: [URL], into target: FileNode?,
                  hiddenPolicy: AddHiddenPolicy = .excludeSystemFiles) -> [FileNode] {
        guard !isLocked else { return [] }
        if !hasActiveDocument { beginNewDocument() }
        var added: [FileNode] = []
        for url in urls {
            let node = ArchiveTreeBuilder.importFromDisk(url, hiddenPolicy: hiddenPolicy).node
            insert(node, into: target)
            added.append(node)
        }
        if !added.isEmpty { selectedIDs = Set(added.map(\.id)) }
        markChanged()
        return added
    }

    // MARK: - Acciones de la barra superior

    /// El archivo está cifrado y bloqueado (sin contraseña): no se puede editar.
    public var isLocked: Bool { requiresEntryPassword }

    /// Crea una carpeta. El nombre por defecto ("Nueva carpeta") lo inyecta la vista,
    /// ya localizado, para que el modelo no dependa de la i18n.
    public func createFolder(defaultName: String) {
        guard !isLocked else { return }
        if !hasActiveDocument { beginNewDocument() }
        let parent = insertionTargetFolder()
        let taken = Set((parent?.children ?? roots).map(\.name))
        let name = UniqueName.next(for: defaultName) { taken.contains($0) }
        let node = FileNode(name: name, isDirectory: true, source: .folder)
        insert(node, into: parent)
        selectedIDs = [node.id]
        markChanged()
    }

    /// Elimina todos los elementos seleccionados (borrado en lote).
    public func removeSelected() {
        guard !isLocked else { return }
        let nodes = selectedNodes()
        guard !nodes.isEmpty else { return }
        for node in nodes { remove(node) }
        selectedIDs = []
        markChanged()
    }

    /// Elimina un nodo concreto (el del menú contextual, por ejemplo).
    public func delete(_ node: FileNode) {
        guard !isLocked else { return }
        remove(node)
        selectedIDs.remove(node.id)
        markChanged()
    }

    /// Renombra un nodo. Ignora si el nombre está vacío o ya existe entre hermanos.
    public func rename(_ node: FileNode, to newName: String) {
        guard !isLocked else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != node.name else { return }
        let siblings = node.parent?.children ?? roots
        guard !siblings.contains(where: { $0.id != node.id && $0.name == trimmed }) else { return }
        node.name = trimmed
        markChanged()
    }

    /// Mueve un nodo dentro de `target` (o a la raíz si es `nil`). No permite
    /// moverlo a sí mismo, a un descendiente, ni donde ya exista ese nombre.
    public func move(_ node: FileNode, into target: FileNode?) {
        guard !isLocked, !isSelfOrDescendant(target, of: node) else { return }
        let destination = target?.children ?? roots
        guard !destination.contains(where: { $0.name == node.name }) else { return }
        remove(node)
        insert(node, into: target)
        markChanged()
    }

    /// `true` si `node` puede moverse a `target` (no a sí mismo ni a un descendiente).
    public func canMove(_ node: FileNode, into target: FileNode?) -> Bool {
        !isLocked && !isSelfOrDescendant(target, of: node)
    }

    /// Carpetas válidas como destino para mover `node` (excluye su carpeta actual,
    /// sí mismo y sus descendientes).
    public func moveDestinations(for node: FileNode) -> [FileNode] {
        allFolders().filter { folder in
            folder.id != node.parent?.id && !isSelfOrDescendant(folder, of: node)
        }
    }

    private func allFolders() -> [FileNode] {
        var result: [FileNode] = []
        func walk(_ nodes: [FileNode]) {
            for n in nodes where n.isDirectory {
                result.append(n)
                walk(n.children)
            }
        }
        walk(roots)
        return result
    }

    /// `true` si `candidate` es `node` o está dentro de `node`.
    private func isSelfOrDescendant(_ candidate: FileNode?, of node: FileNode) -> Bool {
        var current = candidate
        while let cur = current {
            if cur.id == node.id { return true }
            current = cur.parent
        }
        return false
    }

    // MARK: - Documento: cerrar y guardar

    /// Borra el temporal de volúmenes concatenados, si lo hay. En Unix es seguro
    /// aunque `sourceArchive` siga mapeado: las páginas siguen válidas hasta soltarlo.
    private func discardJoinedVolumesTemp() {
        if let temp = joinedVolumesTemp { try? FileManager.default.removeItem(at: temp) }
        joinedVolumesTemp = nil
    }

    /// Cierra el documento y vuelve al estado vacío (zona de arrastre).
    public func close() {
        discardJoinedVolumesTemp()
        roots = []
        selectedIDs = []
        sourceArchive = nil
        incompleteVolumes = false
        sourceURL = nil
        documentName = ""
        hasActiveDocument = false
        hasUnsavedChanges = false
        entryPassword = nil
        lockState = .unlocked
        saveEncryption = .none
        savePassword = nil
        format = .zip
        saveFormat = .zip
        saveVolumeSize = nil
        changed()
    }

    /// Marca el documento como guardado en `url` (actualiza nombre y origen).
    public func markSaved(as url: URL) {
        sourceURL = url
        documentName = url.lastPathComponent
        hasUnsavedChanges = false
        changed()
    }

    /// Escribe un plan en una ruta destino concreta (en segundo plano, con progreso),
    /// opcionalmente sobrescribiendo.
    /// `true` mientras hay una extracción cancelable en curso (botón Extraer **o** arrastre al
    /// Finder). La vista lo usa para mostrar la (X) del overlay.
    /// Hay una operación larga **cancelable** en curso (extracción o guardado/exportación): la
    /// vista muestra el botón Cancelar y el cierre de ventana avisa antes de abortarla.
    @Published public private(set) var cancellable = false
    /// Guardado/exportación en curso (subconjunto de `cancellable`): además de avisar al cerrar,
    /// impide lanzar un segundo guardado encima.
    @Published public private(set) var isWriting = false
    /// Token de la operación activa; lo comparte la ruta de fondo (descompresión o compresión).
    private var cancelToken: CancelToken?

    /// Registra una extracción cancelable y prepara el progreso. Lo llaman ambas rutas (el
    /// botón aquí mismo; el arrastre al Finder desde el delegado de promesas). Hilo principal.
    public func registerExtraction(token: CancelToken, total: Int64) {
        cancelToken = token
        cancellable = true
        // Determinado si conocemos el tamaño total; si no (entradas sin tamaño), indeterminado.
        progress = ProgressState(kind: .extracting, fraction: total > 0 ? 0 : nil)
    }

    /// Fin de la extracción: limpia progreso, flag y token.
    public func endExtraction() {
        progress = nil
        cancellable = false
        cancelToken = nil
    }

    /// Cancela la operación larga en curso (X del overlay, cierre de ventana o salir): la
    /// descompresión/compresión aborta en el siguiente trozo y se descarta el temporal a medias.
    public func cancelCurrentOperation() { cancelToken?.cancel() }

    /// Borra las rutas ya extraídas de un lote cancelado (cuando el usuario elige "Eliminar"),
    /// mostrando la tarjeta "Limpiando…" con barra determinada por número de elementos.
    public func cleanUpExtracted(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        progress = ProgressState(kind: .cleaningUp, fraction: 0)
        defer { progress = nil }
        let total = urls.count
        await Task.detached(priority: .userInitiated) {
            for (index, url) in urls.enumerated() {
                try? FileManager.default.removeItem(at: url)
                let fraction = Double(index + 1) / Double(total)
                await MainActor.run { self.progress?.fraction = fraction }
            }
        }.value
    }

    public func performExtraction(of plan: ExportPlan, to destination: URL, overwrite: Bool) async throws {
        if overwrite, FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let total = plan.byteCount()
        let token = CancelToken()
        registerExtraction(token: token, total: total)
        defer { endExtraction() }

        // Tarea separada (fondo): la descompresión consulta el token en cada trozo y lanza
        // `CancellationError` al cancelar. Coalescemos progreso/nombre a saltos del ~1%.
        do {
            try await Task.detached(priority: .userInitiated) {
                guard total > 0 else {
                    try plan.writeContents(to: destination, isCancelled: { token.isCancelled })
                    return
                }
                var done: Int64 = 0
                var throttle = ProgressThrottle()
                try plan.writeContents(to: destination, onProgress: { name, bytes in
                    done += bytes
                    let fraction = min(1, Double(done) / Double(total))
                    guard throttle.shouldReport(fraction) else { return }
                    Task { @MainActor in
                        self.progress?.fraction = fraction
                        self.progress?.detail = name
                    }
                }, isCancelled: { token.isCancelled })
            }.value
        } catch let e as LibArchiveError where format == .rar && (e == .wrongPassword || e == .passphraseRequired) {
            // RAR con solo los datos cifrados (cabeceras en claro): se abrió y listó sin señal de
            // cifrado, pero libarchive no descifra RAR → falla aquí. Mensaje claro en vez de
            // "contraseña incorrecta" (que confunde: el usuario nunca escribió ninguna).
            throw ArchiveDocumentError.encryptionUnsupported(format: format)
        }
    }

    /// Crea un plan de exportación ligero (sin tocar disco) para arrastrar al
    /// Finder. La extracción real ocurre luego, en segundo plano, al soltar.
    public func exportPlan(for node: FileNode) -> ExportPlan {
        if node.isDirectory {
            return ExportPlan(name: node.name, payload: .folder(node.children.map { exportPlan(for: $0) }))
        }
        switch node.source {
        case .diskFile(let url):
            return ExportPlan(name: node.name, payload: .diskFile(url))
        case .entry(let entry):
            return ExportPlan(name: node.name, payload: .archiveEntry(
                entry: entry, archive: sourceArchive ?? .data(Data()), password: entryPassword, format: format))
        case .folder:
            return ExportPlan(name: node.name, payload: .folder([]))
        }
    }

    /// Plan de exportación de **todo** el contenido, agrupado en una carpeta llamada
    /// `name` (para "Extraer todo": descomprime el archivo entero, como hace Finder).
    public func exportPlanForAll(named name: String) -> ExportPlan {
        ExportPlan(name: name, payload: .folder(roots.map { exportPlan(for: $0) }))
    }

    /// Escribe el documento en `url` con el formato/cifrado/volúmenes dados, en streaming
    /// a disco y en segundo plano con progreso. **No toca el estado del documento** — es
    /// la pieza común de `save` (que además adopta el fichero) y `export` (que no).
    private func writeArchive(to url: URL, format outputFormat: ArchiveFormat,
                              encryption: ZipEncryption, password: String?, volumeSize: Int?,
                              level: CompressionLevel) async throws {
        let volumes = (outputFormat.supportsVolumeSplit && (volumeSize ?? 0) > 0) ? volumeSize : nil
        let cipher = outputFormat.supportsEncryption ? encryption : .none
        let pwd = outputFormat.supportsEncryption ? password : nil
        // Arranca **indeterminado** (spinner): el ensamblado del payload no reporta fracción
        // (puede descomprimir entradas de origen). El escritor ZIP la fija al empezar a escribir,
        // y la barra pasa a determinada; los demás formatos siguen indeterminados.
        progress = ProgressState(kind: cipher == .none ? .compressing(documentName) : .encrypting(documentName),
                                 fraction: nil)
        // La escritura es cancelable: el usuario puede pulsar Cancelar (overlay) o cerrar la
        // ventana; el motor aborta en el siguiente trozo y abajo se descarta el `work` a medias.
        let token = CancelToken()
        cancelToken = token
        cancellable = true
        isWriting = true
        defer { progress = nil; cancellable = false; isWriting = false; cancelToken = nil }

        // 1) Producir el archivo completo en un fichero temporal. El documento decide
        // *qué* escribir y el ArchiveSaver decide *cómo* (codifica a disco). El ensamblado del
        // payload puede descomprimir/descifrar las entradas de origen (p. ej. re-guardar un
        // tar.gz/7z/zip cifrado), así que se hace en **segundo plano** sobre una instantánea
        // `Sendable` del árbol; en el hilo principal solo se toma esa instantánea (barata).
        let snapshot = roots.map(NodeSnapshot.init)
        let builder = SavePayloadBuilder(roots: snapshot, documentName: documentName,
                                         sourceFormat: format, sourceArchive: sourceArchive,
                                         entryPassword: entryPassword)
        let payload = try await Task.detached(priority: .userInitiated) {
            try builder.payload(for: outputFormat, encryption: cipher, password: pwd, level: level)
        }.value
        let work = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)\(WorkFile.suffix)")
        // Registrar el temporal en curso: si la app **termina** a mitad (cerrar la última ventana
        // o ⌘Q matan la tarea antes de que su `catch` limpie), `applicationWillTerminate` lo borra.
        WorkFile.active.insert(work)
        defer { WorkFile.active.remove(work) }
        do {
            // Progreso por bytes de entrada: total = tamaño descomprimido del contenido. La
            // fracción y el nombre del fichero en curso alimentan la barra del overlay.
            try await ArchiveSaver.encode(payload, to: work, total: Int64(contentSize),
                                          cancellation: CancellationCheck { token.isCancelled },
                                          onProgress: { fraction, file in
                Task { @MainActor in
                    self.progress?.fraction = fraction
                    self.progress?.detail = (file as NSString).lastPathComponent
                }
            })
            // 2) Colocar el resultado: un solo fichero o dividido en volúmenes.
            if let volumes {
                progress = ProgressState(kind: .splitting, fraction: nil)
                try await VolumeStore.split(file: work, base: url, volumeSize: volumes)
                try? FileManager.default.removeItem(at: work)
            } else {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.moveItem(at: work, to: url)
                VolumeStore.removeContinuations(of: url)   // limpiar restos de un split previo
            }
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Guarda en `url`, **adopta** el fichero como documento activo y recuerda los ajustes
    /// para re-guardar. (Primer guardado / botón Guardar.)
    public func save(to url: URL, format outputFormat: ArchiveFormat,
              encryption: ZipEncryption, password: String?, volumeSize: Int? = nil,
              level: CompressionLevel = .default) async throws {
        saveFormat = outputFormat
        saveLevel = level
        saveVolumeSize = (outputFormat.supportsVolumeSplit && (volumeSize ?? 0) > 0) ? volumeSize : nil
        if outputFormat == .zip {
            saveEncryption = outputFormat.supportsEncryption ? encryption : .none
            savePassword = outputFormat.supportsEncryption ? password : nil
        }
        try await writeArchive(to: url, format: outputFormat, encryption: encryption,
                               password: password, volumeSize: volumeSize, level: level)
        markSaved(as: url)
    }

    /// Re-guarda con los ajustes ya elegidos (botón Guardar de un documento existente).
    public func save(to url: URL) async throws {
        try await save(to: url, format: saveFormat, encryption: saveEncryption,
                       password: savePassword, volumeSize: saveVolumeSize, level: saveLevel)
    }

    /// Exporta el documento a `url` con el formato/cifrado/volúmenes elegidos **sin**
    /// cambiar el documento activo: el original sigue siendo el actual, con sus ajustes
    /// y su `sourceURL` intactos. Es la vía para cambiar cifrado/contraseña o convertir
    /// de formato escribiendo una copia aparte.
    public func export(to url: URL, format outputFormat: ArchiveFormat,
                encryption: ZipEncryption, password: String?, volumeSize: Int? = nil,
                level: CompressionLevel = .default) async throws {
        try await writeArchive(to: url, format: outputFormat, encryption: encryption,
                               password: password, volumeSize: volumeSize, level: level)
    }

    // MARK: - Navegación del árbol

    /// Nodo "principal" de la selección (el primero), para decidir destino de Añadir
    /// o Nueva carpeta. Con selección única equivale al elemento seleccionado.
    public func selectedNode() -> FileNode? { node(with: selectedIDs.first) }

    /// Todos los nodos seleccionados (para borrado/extracción en lote).
    public func selectedNodes() -> [FileNode] { selectedIDs.compactMap { node(with: $0) } }

    /// Ficheros (no carpetas) hermanos de `node`, en orden, para navegar en Quick Look.
    public func siblingFiles(of node: FileNode) -> [FileNode] {
        let siblings = node.parent?.children ?? roots
        return siblings.filter { !$0.isDirectory }
    }

    public func node(with id: FileNode.ID?) -> FileNode? {
        guard let id else { return nil }
        func search(_ nodes: [FileNode]) -> FileNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = search(node.children) { return found }
            }
            return nil
        }
        return search(roots)
    }

    // MARK: - Inserción / borrado / utilidades

    private func insert(_ node: FileNode, into parent: FileNode?) {
        node.parent = parent
        if let parent { parent.children.append(node) } else { roots.append(node) }
    }

    private func remove(_ node: FileNode) {
        if let parent = node.parent {
            parent.children.removeAll { $0.id == node.id }
        } else {
            roots.removeAll { $0.id == node.id }
        }
    }

    /// Carpeta destino al insertar (Añadir o Nueva carpeta): la seleccionada si es carpeta,
    /// si no el padre del seleccionado, si no la raíz.
    private func insertionTargetFolder() -> FileNode? {
        guard let node = selectedNode() else { return nil }
        return node.isDirectory ? node : node.parent
    }

    /// El documento es un único fichero (apto para guardar como `.gz`).
    public var isSingleFile: Bool { roots.count == 1 && !roots[0].isDirectory }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// `true` si el fichero es un contenedor que sabemos abrir: por extensión o, si esta
    /// no la reconoce, por la firma de su cabecera (p. ej. un `.bin` que en realidad es 7z).
    private func isOpenableArchive(_ url: URL) -> Bool {
        if ArchiveFormat.isOpenableArchive(url) { return true }
        return peekHeader(url).flatMap(ArchiveFormat.detectByMagic) != nil
    }

    /// Lee unos pocos bytes de cabecera para la detección por firma. `nil` si no se puede.
    private func peekHeader(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 512)
    }

    /// Resumen del contenido para la barra de estado (recalculado al cambiar la
    /// estructura, no en cada render): nº de ficheros y tamaño total descomprimido.
    public private(set) var contentFileCount = 0
    public private(set) var contentSize: UInt64 = 0
    /// Tamaño comprimido total. Solo lo conocen las entradas de un archivo abierto;
    /// los ficheros añadidos aún sin comprimir no tienen tamaño comprimido conocido.
    public private(set) var contentCompressedSize: UInt64 = 0
    /// `true` solo si **todas** las entradas tienen tamaño comprimido conocido. Si hay
    /// ficheros recién añadidos (aún sin comprimir), el total sería una mezcla engañosa
    /// de tamaños reales y ceros, así que la barra de estado oculta la cifra.
    public private(set) var contentCompressedKnown = false

    private func recomputeContentSummary() {
        var files = 0
        var bytes: UInt64 = 0
        var compressed: UInt64 = 0
        var compressedKnown = true
        func walk(_ nodes: [FileNode]) {
            for node in nodes {
                if node.isDirectory { walk(node.children) }
                else {
                    files += 1
                    bytes += node.fileSize ?? 0
                    if let c = node.compressedSize { compressed += c }
                    else { compressedKnown = false }
                }
            }
        }
        walk(roots)
        contentFileCount = files
        contentSize = bytes
        contentCompressedSize = compressed
        contentCompressedKnown = files > 0 && compressedKnown
    }

    /// Las mutaciones tocan nodos (clases); subir `revision` (publicado) avisa a
    /// SwiftUI y le dice a la vista de lista que debe recargar.
    private func changed() {
        recomputeContentSummary()
        revision &+= 1
    }

    /// Como `changed()`, pero además marca el documento con cambios sin guardar.
    private func markChanged() {
        hasUnsavedChanges = true
        changed()
    }
}


