import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookUI
import ArchiveBrowser
import FilePackrModel

/// Lo que necesita `writePromiseTo` (hilo de fondo) para extraer y medir el progreso, capturado
/// en el hilo principal al iniciar el arrastre: el documento (`@MainActor`) no se puede tocar
/// desde allí. `contentSize` es el tamaño total del archivo abierto (no solo lo arrastrado); con
/// libarchive (RAR/7z…) hace falta para no mostrar la barra congelada al extraer un subconjunto.
private struct ExtractionPromise: Sendable {
    let plan: ExportPlan
    let usesLibArchive: Bool
    let contentSize: Int64
}

extension NSUserInterfaceItemIdentifier {
    static let nameColumn = NSUserInterfaceItemIdentifier("name")
    static let dateColumn = NSUserInterfaceItemIdentifier("date")
    static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    static let kindColumn = NSUserInterfaceItemIdentifier("kind")
    static let csizeColumn = NSUserInterfaceItemIdentifier("csize")
}


/// Vista de navegación de archivos basada en `NSOutlineView` (AppKit), que da de
/// forma nativa: selección de fila completa, arrastrar para mover/extraer/añadir,
/// Quick Look con barra espaciadora y renombrado en línea.
struct ArchiveOutlineView: NSViewRepresentable {
    @ObservedObject var doc: ArchiveDocument
    /// Lanza el flujo de extracción de SwiftUI (con su diálogo de conflictos).
    var onExtract: (FileNode) -> Void
    /// Pide la contraseña (cuando el archivo está cifrado y aún no la tenemos).
    var onNeedPassword: () -> Void
    /// Añade ficheros arrastrados del Finder dentro de la carpeta destino. Pasa por la
    /// vista para, si el archivo está bloqueado, pedir contraseña antes de añadir.
    var onAddFiles: ([URL], FileNode?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(doc: doc, onExtract: onExtract, onNeedPassword: onNeedPassword, onAddFiles: onAddFiles)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let outline = FileOutlineView()
        outline.coordinator = coordinator
        coordinator.outline = outline

        func makeColumn(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            column.minWidth = min
            column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true)
            return column
        }

        let nameColumn = makeColumn(.nameColumn, loc("column.name"), width: 240, min: 160)
        outline.addTableColumn(nameColumn)
        outline.outlineTableColumn = nameColumn
        outline.addTableColumn(makeColumn(.dateColumn, loc("column.date"), width: 150, min: 110))
        outline.addTableColumn(makeColumn(.sizeColumn, loc("column.size"), width: 90, min: 70))
        outline.addTableColumn(makeColumn(.kindColumn, loc("column.kind"), width: 130, min: 90))
        outline.addTableColumn(makeColumn(.csizeColumn, loc("column.compressed"), width: 100, min: 80))

        outline.dataSource = coordinator
        outline.delegate = coordinator
        // Doble clic en una carpeta: plegar/desplegar (como el Finder).
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        outline.headerView = NSTableHeaderView()
        outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        coordinator.currentSort = (key: "name", ascending: true)
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .plain   // .inset añade un separador inicial en la cabecera
        outline.allowsMultipleSelection = true
        outline.indentationPerLevel = 14
        outline.menu = coordinator.makeContextMenu()

        // .fileURL para añadir ficheros del Finder; los tipos de promesa para
        // reconocer el arrastre interno (mover) de nuestras propias filas.
        outline.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder            // sin borde del scroll view
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.doc = doc
        coordinator.onExtract = onExtract
        coordinator.onNeedPassword = onNeedPassword
        coordinator.onAddFiles = onAddFiles
        guard let outline = nsView.documentView as? FileOutlineView else { return }

        if coordinator.lastRevision != doc.revision {
            coordinator.lastRevision = doc.revision
            outline.reloadData()
            coordinator.reexpand(outline, nodes: doc.roots)
        }
        coordinator.syncSelection(outline)
    }
}

/// Subclase para capturar teclas (espacio = Quick Look, supr = borrar, intro =
/// renombrar) y ceder el control del panel de Quick Look.
final class FileOutlineView: NSOutlineView {
    weak var coordinator: ArchiveOutlineView.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: coordinator?.toggleQuickLook()                 // espacio
        case 51, 117: coordinator?.deleteSelected()             // supr / del
        case 36, 76: coordinator?.editSelected()                // intro
        default: super.keyDown(with: event)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = coordinator
        panel.delegate = coordinator
        panel.reloadData()
        panel.currentPreviewItemIndex = coordinator?.qlStartIndex ?? 0
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

extension ArchiveOutlineView {
    // @MainActor explícito: el coordinador es delegado de NSOutlineView (callbacks en el hilo
    // principal) y toca estado @MainActor (el documento, NSOutlineView, caches de Quick Look).
    // Xcode 26 lo infiere del SDK; Xcode 16 (CI) no, y sin esto la app no compila allí.
    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
                             NSFilePromiseProviderDelegate, QLPreviewPanelDataSource {
        var doc: ArchiveDocument
        var onExtract: (FileNode) -> Void
        var onNeedPassword: () -> Void
        var onAddFiles: ([URL], FileNode?) -> Void
        weak var outline: FileOutlineView?

        var lastRevision = -1
        var expandedNodeIDs: Set<UUID> = []
        var currentSort: (key: String, ascending: Bool)?
        private var draggedNodes: [FileNode] = []
        private var isSyncingSelection = false

        // Quick Look
        private var qlPlans: [ExportPlan] = []
        private var qlCache: [Int: URL] = [:]
        /// Índices que se están materializando en segundo plano (evita relanzar el trabajo si
        /// Quick Look vuelve a pedir el mismo elemento mientras se descomprime).
        private var qlMaterializing: Set<Int> = []
        /// Umbral para materializar en el acto (rápido, sin parpadeo) vs. en segundo plano.
        private let qlInlineLimit: Int64 = 16 * 1024 * 1024
        var qlStartIndex = 0

        /// Cola **de fondo** para cumplir las promesas de fichero del Finder (extraer al
        /// soltar). Antes era `.main`, lo que descomprimía en el hilo principal y bloqueaba la
        /// app (bola de colores) con archivos grandes. En serie para no lanzar N descompresiones
        /// a la vez al arrastrar varios elementos.
        private let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = 1
            return queue
        }()

        init(doc: ArchiveDocument, onExtract: @escaping (FileNode) -> Void,
             onNeedPassword: @escaping () -> Void,
             onAddFiles: @escaping ([URL], FileNode?) -> Void) {
            self.doc = doc
            self.onExtract = onExtract
            self.onNeedPassword = onNeedPassword
            self.onAddFiles = onAddFiles
        }

        // MARK: - DataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileNode)?.isDirectory ?? false
        }

        private func children(of item: Any?) -> [FileNode] {
            let base = (item as? FileNode)?.children ?? doc.roots
            return sortedForDisplay(base)
        }

        /// Orden solo para mostrar: no toca el modelo (evita publicar en el render). La clave de
        /// orden se calcula **una vez por nodo** (decorate-sort), no en cada comparación: la de
        /// "Clase" (`kindDescription`, con `UTType`) es costosa y, llamada O(n log n) veces con
        /// muchos ficheros, colgaba la app.
        private func sortedForDisplay(_ nodes: [FileNode]) -> [FileNode] {
            guard let sort = currentSort else { return nodes }
            switch sort.key {
            case "date":  return sortedByComparable(nodes, sort.ascending) { $0.modificationDate ?? .distantPast }
            case "size":  return sortedByComparable(nodes, sort.ascending) { $0.fileSize ?? 0 }
            case "csize": return sortedByComparable(nodes, sort.ascending) { $0.compressedSize ?? 0 }
            case "kind":  return sortedByString(nodes, sort.ascending) { kindDescription(for: $0) }
            default:      return sortedByString(nodes, sort.ascending) { $0.name }
            }
        }

        /// Decorate-sort por una clave `Comparable`. Ante empate no declara orden (orden débil
        /// estricto: si no, en descendente devolvería `true` para (a,b) y (b,a) y el sort peta).
        private func sortedByComparable<Key: Comparable>(_ nodes: [FileNode], _ ascending: Bool,
                                                         key: (FileNode) -> Key) -> [FileNode] {
            nodes.map { (node: $0, key: key($0)) }
                .sorted { ascending ? $0.key < $1.key : $0.key > $1.key }
                .map(\.node)
        }

        /// Decorate-sort por una clave de texto con comparación natural localizada.
        private func sortedByString(_ nodes: [FileNode], _ ascending: Bool,
                                    key: (FileNode) -> String) -> [FileNode] {
            nodes.map { (node: $0, key: key($0)) }
                .sorted {
                    let r = $0.key.localizedStandardCompare($1.key)
                    guard r != .orderedSame else { return false }
                    return ascending ? (r == .orderedAscending) : (r == .orderedDescending)
                }
                .map(\.node)
        }

        // MARK: - Views

        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode else { return nil }
            switch tableColumn?.identifier {
            case .nameColumn?:
                let cell = nameCell(outlineView)
                cell.imageView?.image = icon(for: node)
                cell.textField?.stringValue = node.name
                cell.textField?.isEditable = !doc.isLocked   // bloqueado si está cifrado sin contraseña
                return cell
            case .dateColumn?:
                let cell = textCell(outlineView, .dateColumn, alignment: .left, mono: false)
                cell.textField?.stringValue = node.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—"
                return cell
            case .sizeColumn?:
                let cell = textCell(outlineView, .sizeColumn, alignment: .right, mono: true)
                cell.textField?.stringValue = sizeString(node.fileSize)
                return cell
            case .kindColumn?:
                let cell = textCell(outlineView, .kindColumn, alignment: .left, mono: false)
                cell.textField?.stringValue = kindDescription(for: node)
                return cell
            case .csizeColumn?:
                let cell = textCell(outlineView, .csizeColumn, alignment: .right, mono: true)
                cell.textField?.stringValue = sizeString(node.compressedSize)
                return cell
            default:
                return nil
            }
        }

        private func sizeString(_ bytes: UInt64?) -> String {
            guard let bytes else { return "—" }
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }

        private func nameCell(_ outlineView: NSOutlineView) -> NSTableCellView {
            if let reused = outlineView.makeView(withIdentifier: .nameColumn, owner: self) as? NSTableCellView {
                return reused
            }
            let cell = NSTableCellView()
            cell.identifier = .nameColumn
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            // El icono es decorativo (carpeta o tipo de archivo): la columna «Clase» ya da el
            // tipo en texto. Lo ocultamos a VoiceOver para que la fila no anuncie «imagen».
            image.setAccessibilityElement(false)
            let text = NSTextField()
            text.translatesAutoresizingMaskIntoConstraints = false
            text.isBordered = false
            text.drawsBackground = false
            text.isEditable = true
            text.lineBreakMode = .byTruncatingMiddle
            text.focusRingType = .none
            text.target = self
            text.action = #selector(nameEdited(_:))
            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func textCell(_ outlineView: NSOutlineView, _ id: NSUserInterfaceItemIdentifier,
                              alignment: NSTextAlignment, mono: Bool) -> NSTableCellView {
            if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
                return reused
            }
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.alignment = alignment
            text.textColor = .secondaryLabelColor
            text.lineBreakMode = .byTruncatingTail
            text.font = mono
                ? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func icon(for node: FileNode) -> NSImage {
            if node.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
            return NSWorkspace.shared.icon(for: utType(for: node))
        }

        private func utType(for node: FileNode) -> UTType {
            if node.isDirectory { return .folder }
            let ext = (node.name as NSString).pathExtension
            guard !ext.isEmpty else { return .data }
            return UTType(filenameExtension: ext) ?? .data
        }

        /// Texto de la columna "Clase" ("Carpeta", "Imagen PNG"…), como en el Finder.
        /// Es formateo de presentación, así que vive en la vista, no en `FileNode`.
        /// Caché de descripción de tipo por extensión (la resolución `UTType` es costosa y se
        /// repite mucho al ordenar/renderizar). Usa el locale del sistema, estable en sesión.
        private static var utTypeKindCache: [String: String] = [:]

        private func kindDescription(for node: FileNode) -> String {
            if node.isDirectory { return loc("kind.folder") }
            let ext = (node.name as NSString).pathExtension
            guard !ext.isEmpty else { return loc("kind.document") }
            let key = ext.lowercased()
            if let cached = Self.utTypeKindCache[key] { return cached }
            if let type = UTType(filenameExtension: ext), let desc = type.localizedDescription {
                let formatted = desc.prefix(1).uppercased() + desc.dropFirst()
                Self.utTypeKindCache[key] = formatted
                return formatted
            }
            return loc("kind.documentExt", ext.uppercased())
        }

        // MARK: - Selección

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let outline else { return }
            let ids = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.id }
            doc.selectedIDs = Set(ids)
        }

        func syncSelection(_ outline: NSOutlineView) {
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            let nodes = doc.selectedNodes()
            guard !nodes.isEmpty else {
                if outline.selectedRow >= 0 { outline.deselectAll(nil) }
                return
            }
            // Revelar (desplegar carpetas ancestro) antes de calcular las filas, p. ej.
            // la carpeta recién creada o los elementos recién añadidos/arrastrados.
            for node in nodes { expandAncestors(of: node, in: outline) }
            var rows = IndexSet()
            for node in nodes {
                let row = outline.row(forItem: node)
                if row >= 0 { rows.insert(row) }
            }
            guard !rows.isEmpty, outline.selectedRowIndexes != rows else { return }
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            if let first = rows.first { outline.scrollRowToVisible(first) }
        }

        /// Despliega las carpetas ancestro de `node` (de la raíz hacia abajo) para que sea
        /// visible. En el caso normal ya están desplegadas, así que es un no-op.
        private func expandAncestors(of node: FileNode, in outline: NSOutlineView) {
            var ancestors: [FileNode] = []
            var parent = node.parent
            while let current = parent { ancestors.append(current); parent = current.parent }
            for ancestor in ancestors.reversed() {
                outline.expandItem(ancestor)
                expandedNodeIDs.insert(ancestor.id)
            }
        }

        // MARK: - Expansión

        func outlineViewItemDidExpand(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? FileNode { expandedNodeIDs.insert(node.id) }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? FileNode { expandedNodeIDs.remove(node.id) }
        }

        func reexpand(_ outline: NSOutlineView, nodes: [FileNode]) {
            for node in nodes where node.isDirectory {
                if expandedNodeIDs.contains(node.id) { outline.expandItem(node) }
                reexpand(outline, nodes: node.children)
            }
        }

        // MARK: - Ordenación por cabecera

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            if let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key {
                currentSort = (key, descriptor.ascending)
            } else {
                currentSort = nil
            }
            outlineView.reloadData()
            reexpand(outlineView, nodes: doc.roots)
            syncSelection(outlineView)
        }

        // MARK: - Renombrar

        @objc private func nameEdited(_ sender: NSTextField) {
            guard let outline else { return }
            let row = outline.row(for: sender)
            guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
            doc.rename(node, to: sender.stringValue)
            sender.stringValue = node.name   // corrige si se rechazó (vacío/duplicado)
        }

        func editSelected() {
            guard let outline, outline.selectedRow >= 0 else { return }
            if doc.isLocked { onNeedPassword(); return }
            outline.editColumn(0, row: outline.selectedRow, with: nil, select: true)
        }

        func deleteSelected() {
            guard let outline, !outline.selectedRowIndexes.isEmpty else { return }
            if doc.isLocked { onNeedPassword(); return }
            let nodes = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
            for node in nodes { doc.delete(node) }
        }

        // MARK: - Menú contextual

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: loc("menu.rename"), action: #selector(menuRename), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: loc("menu.extract"), action: #selector(menuExtract), keyEquivalent: ""))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: loc("menu.delete"), action: #selector(menuDelete), keyEquivalent: ""))
            menu.items.forEach { $0.target = self }
            return menu
        }

        private func clickedNode() -> FileNode? {
            guard let outline, outline.clickedRow >= 0 else { return nil }
            return outline.item(atRow: outline.clickedRow) as? FileNode
        }

        /// Doble clic en una fila: si es carpeta, la pliega o despliega (toggle).
        @objc func handleDoubleClick(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? FileNode, node.isDirectory else { return }
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
        }

        @objc private func menuRename() {
            guard let outline, outline.clickedRow >= 0 else { return }
            if doc.isLocked { onNeedPassword(); return }
            outline.editColumn(0, row: outline.clickedRow, with: nil, select: true)
        }
        @objc private func menuExtract() { if let node = clickedNode() { onExtract(node) } }
        @objc private func menuDelete() {
            if doc.isLocked { onNeedPassword(); return }
            if let node = clickedNode() { doc.delete(node) }
        }

        // MARK: - Arrastre

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? FileNode else { return nil }
            // Cifrado y sin contraseña: pídela y no inicies el arrastre.
            if doc.requiresEntryPassword, case .entry(let entry) = node.source, entry.isEncrypted {
                onNeedPassword()
                return nil
            }
            let provider = NSFilePromiseProvider(fileType: utType(for: node).identifier, delegate: self)
            // Construimos aquí (en el hilo principal, con acceso al documento) el plan ligero
            // y `Sendable`; así la promesa se cumple en la cola de fondo sin tocar el documento.
            provider.userInfo = ExtractionPromise(plan: doc.exportPlan(for: node),
                                                  usesLibArchive: doc.format.usesLibArchive,
                                                  contentSize: Int64(doc.contentSize))
            return provider
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
            let nodes = draggedItems.compactMap { $0 as? FileNode }
            draggedNodes = nodes
            // Imagen de arrastre = solo el icono (como el Finder), no el snapshot de la fila entera.
            let size = NSSize(width: 32, height: 32)
            session.enumerateDraggingItems(options: [], for: outlineView,
                                           classes: [NSFilePromiseProvider.self], searchOptions: [:]) { item, index, _ in
                guard index < nodes.count, let icon = self.icon(for: nodes[index]).copy() as? NSImage else { return }
                icon.size = size
                item.setDraggingFrame(NSRect(origin: item.draggingFrame.origin, size: size), contents: icon)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            draggedNodes = []
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let folder = (item as? FileNode).flatMap { $0.isDirectory ? $0 : $0.parent }

            if !draggedNodes.isEmpty, (info.draggingSource as AnyObject) === outlineView {
                for node in draggedNodes where !doc.canMove(node, into: folder) { return [] }
                outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            }
            if info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                     options: [.urlReadingFileURLsOnly: true]) {
                outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .copy
            }
            return []
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            let folder = item as? FileNode

            if !draggedNodes.isEmpty, (info.draggingSource as AnyObject) === outlineView {
                for node in draggedNodes { doc.move(node, into: folder) }
                return true
            }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            // Pasa por la vista: si el archivo está bloqueado, pide la contraseña y añade
            // tras desbloquear; en cualquier caso revela y enfoca lo añadido.
            onAddFiles(urls, folder)
            return true
        }

        // MARK: - NSFilePromiseProviderDelegate (extraer al Finder)

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? ExtractionPromise)?.plan.name ?? loc("promise.fallback")
        }

        /// AppKit invoca esto en `promiseQueue` (de fondo). Descomprime en streaming sin tocar
        /// el documento (usa el plan `Sendable` ya construido) y muestra/oculta la barra de
        /// progreso de la app saltando al hilo principal, para dar feedback sin bloquear.
        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            guard let promise = filePromiseProvider.userInfo as? ExtractionPromise else { completionHandler(nil); return }
            let plan = promise.plan
            // Con libarchive (RAR/7z…) extraer un subconjunto recorre el archivo entero (iterador
            // secuencial, sin acceso aleatorio): el coste real es al menos `contentSize`, aunque
            // el plan arrastrado sea un único fichero pequeño (ver `onSkip` más abajo).
            let total = promise.usesLibArchive ? max(plan.byteCount(), promise.contentSize) : plan.byteCount()
            // Registramos la extracción en el documento (en main) para mostrar la barra y la (X)
            // de cancelar; el token se consulta aquí, en el hilo de fondo, en cada trozo.
            let token = CancelToken()
            Task { @MainActor in doc.registerExtraction(token: token, total: total) }
            defer { Task { @MainActor in doc.endExtraction() } }
            do {
                if total > 0 {
                    var done: Int64 = 0
                    var throttle = ProgressThrottle()
                    try plan.writeContents(to: url, onProgress: { name, bytes in
                        done += bytes
                        let fraction = min(1, Double(done) / Double(total))
                        guard throttle.shouldReport(fraction) else { return }
                        Task { @MainActor in
                            self.doc.progress?.fraction = fraction
                            self.doc.progress?.detail = name
                        }
                    }, onSkip: { bytes in
                        done += bytes
                        let fraction = min(1, Double(done) / Double(total))
                        guard throttle.shouldReport(fraction) else { return }
                        Task { @MainActor in self.doc.progress?.fraction = fraction }
                    }, isCancelled: { token.isCancelled })
                } else {
                    try plan.writeContents(to: url, isCancelled: { token.isCancelled })
                }
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

        // MARK: - Quick Look

        func toggleQuickLook() {
            guard let panel = QLPreviewPanel.shared() else { return }
            if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
                panel.orderOut(nil)
                return
            }
            guard let outline, outline.selectedRow >= 0,
                  let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.isDirectory else { return }
            // Si el archivo está cifrado y aún no tenemos la contraseña, pídela.
            if doc.requiresEntryPassword { onNeedPassword(); return }
            let siblings = doc.siblingFiles(of: node)
            qlPlans = siblings.map { doc.exportPlan(for: $0) }
            qlCache = [:]
            qlStartIndex = siblings.firstIndex { $0.id == node.id } ?? 0
            // El índice se fija al tomar el control (beginPreviewPanelControl), para
            // que el panel no muestre primero otro elemento.
            panel.makeKeyAndOrderFront(nil)
        }

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { qlPlans.count }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
            if let url = qlCache[index] { return url as NSURL }
            let plan = qlPlans[index]
            // Ficheros pequeños: materializar al momento (preview instantáneo, sin parpadeo).
            // Grandes: descomprimir en segundo plano para no bloquear el hilo principal,
            // devolviendo un marcador y recargando el panel al terminar.
            if plan.byteCount() <= qlInlineLimit {
                let url = (try? plan.materialize()) ?? URL(fileURLWithPath: "/dev/null")
                qlCache[index] = url
                return url as NSURL
            }
            if !qlMaterializing.contains(index) {
                qlMaterializing.insert(index)
                promiseQueue.addOperation {
                    let url = (try? plan.materialize()) ?? URL(fileURLWithPath: "/dev/null")
                    Task { @MainActor in
                        self.qlCache[index] = url
                        self.qlMaterializing.remove(index)
                        QLPreviewPanel.shared()?.reloadData()
                    }
                }
            }
            return URL(fileURLWithPath: "/dev/null") as NSURL
        }
    }
}

