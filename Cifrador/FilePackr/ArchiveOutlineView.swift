import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookUI
import ArchiveBrowser

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

    func makeCoordinator() -> Coordinator {
        Coordinator(doc: doc, onExtract: onExtract, onNeedPassword: onNeedPassword)
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

        let nameColumn = makeColumn(.nameColumn, "Nombre", width: 240, min: 160)
        outline.addTableColumn(nameColumn)
        outline.outlineTableColumn = nameColumn
        outline.addTableColumn(makeColumn(.dateColumn, "Fecha", width: 150, min: 110))
        outline.addTableColumn(makeColumn(.sizeColumn, "Tamaño", width: 90, min: 70))
        outline.addTableColumn(makeColumn(.kindColumn, "Clase", width: 130, min: 90))
        outline.addTableColumn(makeColumn(.csizeColumn, "Comprimido", width: 100, min: 80))

        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.headerView = NSTableHeaderView()
        outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        coordinator.currentSort = (key: "name", ascending: true)
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .inset
        outline.allowsMultipleSelection = false
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
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.doc = doc
        coordinator.onExtract = onExtract
        coordinator.onNeedPassword = onNeedPassword
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
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
                             NSFilePromiseProviderDelegate, QLPreviewPanelDataSource {
        var doc: ArchiveDocument
        var onExtract: (FileNode) -> Void
        var onNeedPassword: () -> Void
        weak var outline: FileOutlineView?

        var lastRevision = -1
        var expandedNodeIDs: Set<UUID> = []
        var currentSort: (key: String, ascending: Bool)?
        private var draggedNodes: [FileNode] = []
        private var isSyncingSelection = false

        // Quick Look
        private var qlPlans: [ExportPlan] = []
        private var qlCache: [Int: URL] = [:]
        var qlStartIndex = 0

        private let promiseQueue = OperationQueue.main

        init(doc: ArchiveDocument, onExtract: @escaping (FileNode) -> Void,
             onNeedPassword: @escaping () -> Void) {
            self.doc = doc
            self.onExtract = onExtract
            self.onNeedPassword = onNeedPassword
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

        /// Orden solo para mostrar: no toca el modelo (evita publicar en el render).
        private func sortedForDisplay(_ nodes: [FileNode]) -> [FileNode] {
            guard let sort = currentSort else { return nodes }
            return nodes.sorted { a, b in
                let ascending: Bool
                switch sort.key {
                case "date":
                    ascending = (a.modificationDate ?? .distantPast) < (b.modificationDate ?? .distantPast)
                case "size":
                    ascending = (a.fileSize ?? 0) < (b.fileSize ?? 0)
                case "csize":
                    ascending = (a.compressedSize ?? 0) < (b.compressedSize ?? 0)
                case "kind":
                    ascending = a.kindDescription.localizedStandardCompare(b.kindDescription) == .orderedAscending
                default:
                    ascending = a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                return sort.ascending ? ascending : !ascending
            }
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
                cell.textField?.stringValue = node.kindDescription
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

        // MARK: - Selección

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let outline else { return }
            if outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? FileNode {
                doc.selection = node.id
            } else {
                doc.selection = nil
            }
        }

        func syncSelection(_ outline: NSOutlineView) {
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            if let id = doc.selection, let node = doc.node(with: id) {
                let row = outline.row(forItem: node)
                if row >= 0, outline.selectedRow != row {
                    outline.selectRowIndexes([row], byExtendingSelection: false)
                }
            } else if outline.selectedRow >= 0 {
                outline.deselectAll(nil)
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
            outline.editColumn(0, row: outline.selectedRow, with: nil, select: true)
        }

        func deleteSelected() {
            guard let outline, outline.selectedRow >= 0,
                  let node = outline.item(atRow: outline.selectedRow) as? FileNode else { return }
            doc.delete(node)
        }

        // MARK: - Menú contextual

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Renombrar", action: #selector(menuRename), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Extraer…", action: #selector(menuExtract), keyEquivalent: ""))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Eliminar", action: #selector(menuDelete), keyEquivalent: ""))
            menu.items.forEach { $0.target = self }
            return menu
        }

        private func clickedNode() -> FileNode? {
            guard let outline, outline.clickedRow >= 0 else { return nil }
            return outline.item(atRow: outline.clickedRow) as? FileNode
        }

        @objc private func menuRename() {
            guard let outline, outline.clickedRow >= 0 else { return }
            outline.editColumn(0, row: outline.clickedRow, with: nil, select: true)
        }
        @objc private func menuExtract() { if let node = clickedNode() { onExtract(node) } }
        @objc private func menuDelete() { if let node = clickedNode() { doc.delete(node) } }

        // MARK: - Arrastre

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? FileNode else { return nil }
            // Cifrado y sin contraseña: pídela y no inicies el arrastre.
            if doc.requiresEntryPassword, case .zipEntry(let entry) = node.source, entry.isEncrypted {
                onNeedPassword()
                return nil
            }
            let provider = NSFilePromiseProvider(fileType: utType(for: node).identifier, delegate: self)
            provider.userInfo = node
            return provider
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
            draggedNodes = draggedItems.compactMap { $0 as? FileNode }
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
            doc.addFiles(urls, into: folder)
            return true
        }

        // MARK: - NSFilePromiseProviderDelegate (extraer al Finder)

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? FileNode)?.name ?? "archivo"
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            guard let node = filePromiseProvider.userInfo as? FileNode else { completionHandler(nil); return }
            do {
                try doc.exportPlan(for: node).writeContents(to: url)
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
            let url = (try? qlPlans[index].materialize()) ?? URL(fileURLWithPath: "/dev/null")
            qlCache[index] = url
            return url as NSURL
        }
    }
}

