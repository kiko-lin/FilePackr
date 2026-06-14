import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Gestor de archivos comprimidos: barra superior con acciones y cuerpo central
/// con el contenido (o la zona de arrastre cuando está vacío).
/// Conflicto al extraer: ya existe un fichero/carpeta con ese nombre en destino.
private struct ExtractionConflict: Identifiable {
    let id = UUID()
    let plan: ExportPlan
    let destination: URL    // ruta que ya existe
    let alternative: URL    // nombre libre propuesto (p.ej. "3d_2.svg")
}

struct ContentView: View {
    @StateObject private var doc = ArchiveDocument()
    @State private var errorMessage: String?
    @State private var conflict: ExtractionConflict?

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in
                    run { try doc.handleIncoming(urls) }
                    return true
                }
        }
        .toolbar { toolbarContent }
        .alert("No se pudo completar la operación",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               presenting: errorMessage) { _ in
            Button("Aceptar") {}
        } message: { Text($0) }
        .confirmationDialog(
            conflict.map { "Ya existe «\($0.destination.lastPathComponent)» en el destino" } ?? "",
            isPresented: Binding(get: { conflict != nil },
                                 set: { if !$0 { conflict = nil } }),
            presenting: conflict
        ) { item in
            Button("Sobrescribir", role: .destructive) {
                run { try doc.performExtraction(of: item.plan, to: item.destination, overwrite: true) }
                conflict = nil
            }
            Button("Guardar como \(item.alternative.lastPathComponent)") {
                run { try doc.performExtraction(of: item.plan, to: item.alternative, overwrite: false) }
                conflict = nil
            }
            Button("Cancelar", role: .cancel) { conflict = nil }
        }
    }

    // MARK: - Cuerpo central

    @ViewBuilder
    private var content: some View {
        if doc.isEmpty {
            dropPrompt
        } else {
            fileList
        }
    }

    private var dropPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Arrastra archivos aquí")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Un .zip se abrirá para editarlo; otros archivos crearán uno nuevo.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var fileList: some View {
        List(doc.roots, children: \.childrenOrNil, selection: $doc.selection) { node in
            HStack {
                Image(systemName: node.isDirectory ? "folder" : "doc")
                    .foregroundStyle(node.isDirectory ? .blue : .secondary)
                Text(node.name)
                Spacer()
                if let size = node.displaySize {
                    Text(byteString(size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(node.id)
            .onDrag { dragProvider(for: node) }
            .contextMenu {
                Button("Extraer…") { extract(node) }
                Button("Eliminar", role: .destructive) { doc.delete(node) }
            }
        }
        .onDeleteCommand { doc.removeSelected() }
    }

    // MARK: - Barra superior

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: addAction) {
                Label("Añadir", systemImage: "plus")
            }
            .help("Añadir archivos, o abrir un .zip si es el primero")

            Button(action: doc.removeSelected) {
                Label("Eliminar", systemImage: "trash")
            }
            .disabled(doc.selection == nil)
            .help("Eliminar el elemento seleccionado")

            Button(action: doc.createFolder) {
                Label("Crear carpeta", systemImage: "folder.badge.plus")
            }
            .help("Crear una carpeta")

            Button(action: extractAction) {
                Label("Extraer", systemImage: "square.and.arrow.up")
            }
            .disabled(doc.selection == nil)
            .help("Extraer el elemento seleccionado a una ubicación")

            Spacer()

            Button(action: saveAction) {
                Label("Guardar", systemImage: "square.and.arrow.down")
            }
            .disabled(doc.isEmpty)
            .help("Guardar como .zip")
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    // MARK: - Acciones con paneles del sistema

    private func addAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Añadir"
        if panel.runModal() == .OK {
            run { try doc.handleIncoming(panel.urls) }
        }
    }

    private func extractAction() {
        guard let node = doc.selectedNode() else { return }
        extract(node)
    }

    /// Extrae un nodo concreto: pide carpeta destino y gestiona conflictos de nombre.
    private func extract(_ node: FileNode) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extraer aquí"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let plan = doc.exportPlan(for: node)
        let destination = dir.appendingPathComponent(node.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            // Conflicto: preguntamos sobrescribir / guardar como / cancelar.
            conflict = ExtractionConflict(plan: plan,
                                          destination: destination,
                                          alternative: doc.conflictFreeURL(for: destination))
        } else {
            run { try doc.performExtraction(of: plan, to: destination, overwrite: false) }
        }
    }

    private func saveAction() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Archivo.zip"
        panel.prompt = "Guardar"
        if panel.runModal() == .OK, let url = panel.url {
            run { try doc.save(to: url) }
        }
    }

    /// Entrega el nodo para arrastrarlo al Finder. La extracción es perezosa:
    /// solo se prepara un plan ligero; el archivo se materializa al soltar.
    private func dragProvider(for node: FileNode) -> NSItemProvider {
        let plan = doc.exportPlan(for: node)
        let (type, suggestedName) = dragType(for: node)

        let provider = NSItemProvider()
        // El sistema reañade la extensión del tipo al nombre sugerido, así que el
        // nombre va sin extensión (si no, "3d.svg" acabaría como "3d.svg.svg").
        provider.suggestedName = suggestedName
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                                             fileOptions: [],
                                             visibility: .all) { completion in
            do {
                completion(try plan.materialize(), false, nil)
            } catch {
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }

    /// Decide el tipo uniforme y el nombre sugerido (sin extensión) para el arrastre.
    private func dragType(for node: FileNode) -> (UTType, String) {
        if node.isDirectory {
            return (.folder, node.name) // las carpetas no llevan extensión que reañadir
        }
        let ext = (node.name as NSString).pathExtension
        guard !ext.isEmpty else { return (.data, node.name) }
        let base = (node.name as NSString).deletingPathExtension
        let type = UTType(filenameExtension: ext)
            ?? UTType(tag: ext, tagClass: .filenameExtension, conformingTo: .data)
            ?? .data
        return (type, base)
    }

    private func run(_ op: () throws -> Void) {
        do { try op() } catch { errorMessage = "\(error)" }
    }

    private func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

#Preview {
    ContentView()
}
