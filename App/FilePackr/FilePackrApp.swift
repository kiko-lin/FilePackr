import SwiftUI
import FilePackrModel
import AppKit

@main
struct FilePackrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            // El tamaño mínimo lo pone `ContentView` (modo normal); en modo «Descomprimir aquí» la
            // ventana es compacta, por eso no se fija aquí.
            ContentView()
                .environmentObject(AppSettings.shared)
        }
        .windowStyle(.hiddenTitleBar)   // sin barra de título "FilePackr"; el contenido sube
        .commands { HelpCommands() }    // menú Ayuda (⌘?) → ventana de Ayuda

        // Ajustes en el menú de la app (⌘,), accesible siempre (también con la app vacía).
        Settings {
            SettingsView()
                .environmentObject(AppSettings.shared)
        }

        // Ventana de Ayuda: una sola instancia, la abre `HelpCommands` con `openWindow`.
        // `.commandsRemoved()` retira el ítem de menú que SwiftUI añade por su cuenta para
        // esta escena (saldría duplicado en el menú Ventana); la única entrada es la del menú
        // Ayuda que pone `HelpCommands`.
        Window(loc("help.title"), id: HelpCommands.windowID) {
            HelpView()
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

/// Sustituye el ítem por defecto del menú **Ayuda** («Ayuda de FilePackr», ⌘?) por uno que
/// abre nuestra ventana `HelpView` en vez de la Ayuda de macOS (que no existe para esta app).
struct HelpCommands: Commands {
    static let windowID = "help"
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(loc("help.title")) { openWindow(id: Self.windowID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}

/// Avisa al salir de la app (⌘Q) si alguna ventana tiene cambios sin guardar, con el
/// **mismo** aviso unificado (`UnsavedChangesAlert`) que el cierre de ventana y de documento.
/// El cierre de cada ventana por separado lo gestiona `WindowGuard`.
///
/// `@MainActor` explícito: un delegate de `NSApplication` corre siempre en el hilo principal y
/// sus métodos tocan AppKit (`NSApp`, `NSWindow`) y estado @MainActor (`WorkFile`). Xcode 26 lo
/// infiere; el SDK de Xcode 16 (CI) no, y sin esto la app no compila allí.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sin pestañas de ventana: cada archivo abre en su propia ventana independiente.
    /// Esto también retira los ítems de menú de pestañas (Mostrar barra/Combinar ventanas…).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }


    /// Cerrar la última ventana cierra la app (utilidad de una sola ventana): evita que el
    /// proceso quede vivo de fondo, p. ej. con una extracción aún corriendo.
    /// Cerrar la última ventana cierra la app (utilidad de una sola ventana). La ventana compacta de
    /// «Descomprimir aquí» también cuenta: al cerrarse (extracción hecha o cancelada), la app sale.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Al salir, borra los temporales de guardados que siguieran en curso (cerrar la última
    /// ventana o ⌘Q matan la tarea de fondo antes de que limpie su `.work`).
    func applicationWillTerminate(_ notification: Notification) {
        WorkFile.cleanUpActive()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let edited = sender.windows.first(where: { $0.isDocumentEdited }) else { return .terminateNow }
        UnsavedChangesAlert.present(on: sender.keyWindow ?? edited) { choice in
            switch choice {
            case .cancel:
                sender.reply(toApplicationShouldTerminate: false)
            case .discard:
                sender.reply(toApplicationShouldTerminate: true)
            case .save:
                // Lanza el flujo de guardado de la ventana con cambios; termina al guardar.
                if let save = WindowSaveHandlers.handlers[ObjectIdentifier(edited)] {
                    save { sender.reply(toApplicationShouldTerminate: true) }
                } else {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }
}
