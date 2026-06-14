import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Conflicto al extraer: ya existe un fichero/carpeta con ese nombre en destino.
private struct ExtractionConflict: Identifiable {
    let id = UUID()
    let plan: ExportPlan
    let destination: URL    // ruta que ya existe
    let alternative: URL    // nombre libre propuesto (p.ej. "3d_2.svg")
}

/// Gestor de archivos comprimidos: barra superior + barra de documento + cuerpo
/// central (zona de arrastre cuando está vacío, o el navegador `NSOutlineView`).
struct ContentView: View {
    @StateObject private var doc = ArchiveDocument()
    @State private var errorMessage: String?
    @State private var conflict: ExtractionConflict?
    @State private var confirmingClose = false

    var body: some View {
        VStack(spacing: 0) {
            if !doc.isEmpty {
                documentBar
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbarContent }
        .confirmationDialog("Hay cambios sin guardar en «\(doc.documentName)»",
                            isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("Cerrar sin guardar", role: .destructive) { doc.close() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Si cierras ahora perderás los cambios no guardados.")
        }
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
                .dropDestination(for: URL.self) { urls, _ in
                    run { try doc.handleIncoming(urls) }
                    return true
                }
        } else {
            ArchiveOutlineView(doc: doc, onExtract: { extract($0) })
        }
    }

    /// Barra intermedia: icono + nombre del archivo y acciones Cerrar / Guardar.
    private var documentBar: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: .zip))
                .resizable()
                .frame(width: 16, height: 16)
            Text(doc.documentName)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            if doc.hasUnsavedChanges {
                Text("— sin guardar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cerrar") { attemptClose() }
            Button("Guardar") { saveDocument() }
                .disabled(!doc.hasUnsavedChanges)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
            conflict = ExtractionConflict(plan: plan,
                                          destination: destination,
                                          alternative: doc.conflictFreeURL(for: destination))
        } else {
            run { try doc.performExtraction(of: plan, to: destination, overwrite: false) }
        }
    }

    /// Guarda: sobre el fichero de origen si existe, o pide ubicación si es nuevo.
    private func saveDocument() {
        if let url = doc.sourceURL {
            run { try doc.save(to: url); doc.markSaved(as: url) }
        } else {
            saveAsPanel()
        }
    }

    private func saveAsPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let base = doc.documentName == ArchiveDocument.untitledName
            ? doc.documentName
            : (doc.documentName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).zip"
        panel.prompt = "Guardar"
        if panel.runModal() == .OK, let url = panel.url {
            run { try doc.save(to: url); doc.markSaved(as: url) }
        }
    }

    /// Cierra el documento; si hay cambios sin guardar, pide confirmación.
    private func attemptClose() {
        if doc.hasUnsavedChanges {
            confirmingClose = true
        } else {
            doc.close()
        }
    }

    private func run(_ op: () throws -> Void) {
        do { try op() } catch { errorMessage = "\(error)" }
    }
}

#Preview {
    ContentView()
}
