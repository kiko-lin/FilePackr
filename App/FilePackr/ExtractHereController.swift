import AppKit
import SwiftUI
import Combine
import FilePackrModel

/// Sesión de **«Descomprimir aquí»** (extensión Finder Sync, `filepackr://extract`).
///
/// La muestra `ContentView` en su propia ventana pero en **modo compacto**: solo contraseña y/o
/// barra de progreso, nunca el navegador. Al terminar o cancelar, llama a `onFinish` (la ventana se
/// cierra sola). Reutiliza el motor real de extracción (`performExtraction`), con su barra de
/// progreso por fracción y su cancelación.
@MainActor
final class ExtractSession: ObservableObject {
    enum Phase: Equatable {
        case opening
        case password(wrong: Bool)
        case conflict(folder: String)
        case progress
    }
    enum ConflictChoice { case overwrite, keepBoth, cancel }

    @Published var phase: Phase = .opening
    @Published var password = ""
    @Published var progressFraction: Double?     // nil = indeterminado
    /// Nombre del archivo en curso (se muestra en la barra de título de la ventana compacta).
    @Published var currentArchive = ""

    /// Se llama al terminar/cancelar. La ventana lo usa para cerrarse.
    var onFinish: () -> Void = {}

    private let archives: [URL]
    private var cancelled = false
    private var currentDoc: ArchiveDocument?
    private var progressSub: AnyCancellable?
    private var passwordContinuation: CheckedContinuation<String?, Never>?
    private var conflictContinuation: CheckedContinuation<ConflictChoice, Never>?

    init(archives: [URL]) { self.archives = archives }

    func start() {
        Task { [weak self] in
            await self?.run()
            self?.onFinish()
        }
    }

    // MARK: - Acciones de la vista

    func confirmPassword() { if !password.isEmpty { resumePassword(password) } }
    func resolveConflict(_ choice: ConflictChoice) {
        let cont = conflictContinuation; conflictContinuation = nil; cont?.resume(returning: choice)
    }

    func cancel() {
        cancelled = true
        resumePassword(nil)                       // desbloquea una espera de contraseña
        conflictContinuation?.resume(returning: .cancel); conflictContinuation = nil
        currentDoc?.cancelCurrentOperation()      // aborta una extracción en curso
    }

    // MARK: - Flujo

    private func run() async {
        var revealed: [URL] = []
        for url in archives {
            if cancelled { break }
            phase = .opening
            do {
                if let dest = try await extractOne(url) { revealed.append(dest) }
            } catch is CancellationError {
                break
            } catch {
                presentError(error, for: url)
            }
        }
        // Revelar en el Finder solo si el usuario lo activó en Ajustes (por defecto, no).
        if !revealed.isEmpty, AppSettings.shared.revealAfterExtract {
            NSWorkspace.shared.activateFileViewerSelecting(revealed)
        }
    }

    private func extractOne(_ url: URL) async throws -> URL? {
        currentArchive = url.lastPathComponent
        let doc = ArchiveDocument()
        currentDoc = doc
        defer { currentDoc = nil }
        try await doc.openArchive(url)

        var wrong = false
        while doc.requiresOpenPassword {                       // contraseña para abrir (índice cifrado)
            guard let pw = await askPassword(wrong) else { return nil }
            wrong = !(await doc.provideOpenPassword(pw))
        }
        wrong = false
        while doc.requiresEntryPassword {                      // contraseña para extraer entradas
            guard let pw = await askPassword(wrong) else { return nil }
            wrong = !doc.provideEntryPassword(pw)
        }
        if cancelled { return nil }

        // Destino: carpeta hermana con el nombre base. Si ya existe, preguntar.
        let dir = url.deletingLastPathComponent()
        let base = archiveBaseName(url.lastPathComponent)
        let preferred = dir.appendingPathComponent(base, isDirectory: true)
        var dest = preferred
        var overwrite = false
        if FileManager.default.fileExists(atPath: preferred.path) {
            switch await askConflict(base) {
            case .cancel:    return nil
            case .overwrite: dest = preferred; overwrite = true
            case .keepBoth:  dest = freeFolder(in: dir, named: base)
            }
        }
        if cancelled { return nil }

        phase = .progress
        progressFraction = nil
        progressSub = doc.$progress.sink { [weak self] state in self?.progressFraction = state?.fraction }
        defer { progressSub = nil }

        let plan = doc.exportPlanForAll(named: dest.lastPathComponent)
        do {
            try await doc.performExtraction(of: plan, to: dest, overwrite: overwrite)
        } catch is CancellationError {
            if !overwrite { try? FileManager.default.removeItem(at: dest) }   // carpeta nueva a medias
            throw CancellationError()
        }
        return dest
    }

    private func askConflict(_ folder: String) async -> ConflictChoice {
        phase = .conflict(folder: folder)
        return await withCheckedContinuation { conflictContinuation = $0 }
    }

    private func askPassword(_ wrong: Bool) async -> String? {
        password = ""
        phase = .password(wrong: wrong)
        return await withCheckedContinuation { passwordContinuation = $0 }
    }

    private func resumePassword(_ value: String?) {
        let cont = passwordContinuation
        passwordContinuation = nil
        cont?.resume(returning: value)
    }

    private func freeFolder(in dir: URL, named base: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    private func presentError(_ error: Error, for url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localizedErrorMessage(error)
        alert.informativeText = url.lastPathComponent
        alert.addButton(withTitle: loc("button.ok"))
        alert.runModal()
    }
}

/// Decodifica las rutas que la extensión Finder Sync mete en `filepackr://…?p=<base64(ruta)>`.
enum FilePackrURL {
    static func paths(in url: URL) -> [String] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == "p" }
            .compactMap { $0.value.flatMap { Data(base64Encoded: $0) } }
            .compactMap { String(data: $0, encoding: .utf8) }
    }
}

/// Ajusta la ventana anfitriona al tamaño **exacto** del contenido (`fittingSize`), reseteando su
/// min/max —que el `WindowGroup` deja en 760×480 si `normalBody` llegó a pintarse—, no
/// redimensionable y flotante, conservando el borde superior al re-dimensionar entre fases.
private struct WindowResizer: NSViewRepresentable {
    let size: CGSize
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.styleMask.remove(.resizable)
            window.level = .floating
            window.contentMinSize = size                     // resetea el mínimo 760×480 de normalBody
            window.contentMaxSize = size
            guard window.contentView?.frame.size != size else { return }
            let top = window.frame.maxY                       // conservar el borde superior
            window.setContentSize(size)
            window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        }
    }
}

/// Contenido **compacto** de la ventana en modo «Descomprimir aquí»: solo contraseña o progreso.
/// El tamaño de la ventana es explícito por fase (lo aplica `WindowResizer`).
struct ExtractCompactView: View {
    @ObservedObject var session: ExtractSession

    private var windowSize: CGSize {                          // incluye la cabecera (~46 pt)
        switch session.phase {
        case .opening:             return CGSize(width: 340, height: 100)
        case .password(let wrong): return CGSize(width: 340, height: wrong ? 206 : 182)
        case .conflict:            return CGSize(width: 340, height: 232)
        case .progress:            return CGSize(width: 340, height: 182)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .background(WindowResizer(size: windowSize))
    }

    /// Cabecera: el nombre del archivo, **debajo** de los semáforos y a lo ancho (aprovecha el
    /// espacio en la ventana estrecha). Mismo tamaño/grosor que la cabecera estándar.
    private var titleBar: some View {
        Text(session.currentArchive)
            .font(.system(size: 15, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)                                // justo debajo de los botones de la ventana
            .padding(.horizontal, 14)
            .padding(.bottom, 10)                            // algo de aire bajo el nombre
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .opening:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(loc("finderext.extract.opening")).font(.callout)
            }

        case let .password(wrong):
            VStack(alignment: .leading, spacing: 14) {
                Text(loc("password.field")).font(.headline)     // solo «Contraseña»
                RevealableSecureField(placeholder: loc("password.field"), text: $session.password) {
                    session.confirmPassword()
                }
                if wrong { Text(loc("password.wrong")).font(.callout).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button(loc("button.cancel"), role: .cancel, action: session.cancel)
                        .keyboardShortcut(.cancelAction)
                    Button(loc("button.continue"), action: session.confirmPassword)
                        .keyboardShortcut(.defaultAction)
                        .disabled(session.password.isEmpty)
                }
            }
            .padding(20)

        case .conflict:
            VStack(alignment: .leading, spacing: 10) {
                Text(loc("finderext.conflict.exists")).font(.headline)   // el nombre ya está arriba
                VStack(spacing: 8) {
                    Button { session.resolveConflict(.keepBoth) } label: {
                        Text(loc("conflict.keepBoth")).frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) { session.resolveConflict(.overwrite) } label: {
                        Text(loc("conflict.overwrite")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .cancel) { session.resolveConflict(.cancel) } label: {
                        Text(loc("button.cancel")).frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)         // 20px de aire sobre «El archivo ya existe»
            .padding(.bottom, 16)

        case .progress:
            VStack(alignment: .leading, spacing: 14) {
                Text(loc("progress.extracting")).font(.headline)
                ProgressView(value: session.progressFraction ?? 0, total: 1)   // barra determinada siempre
                HStack {
                    Spacer()
                    Button(loc("button.cancel"), role: .cancel, action: session.cancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
        }
    }
}
