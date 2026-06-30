import SwiftUI
import FilePackrModel
import AppKit

@main
struct FilePackrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
                .environmentObject(AppSettings.shared)
        }
        .windowStyle(.hiddenTitleBar)   // sin barra de título "FilePackr"; el contenido sube

        // Ajustes en el menú de la app (⌘,), accesible siempre (también con la app vacía).
        Settings {
            SettingsView()
                .environmentObject(AppSettings.shared)
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
    /// Proveedor de los Servicios del Finder («Abrir en FilePackr» / «Descomprimir aquí»).
    /// Lo retenemos aquí porque `NSApp.servicesProvider` no lo conserva con fuerza.
    private let servicesProvider = FinderServicesProvider()

    /// Sin pestañas de ventana: cada archivo abre en su propia ventana independiente.
    /// Esto también retira los ítems de menú de pestañas (Mostrar barra/Combinar ventanas…).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Registra los Servicios de macOS (menú contextual del Finder / menú «Servicios»).
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
    }

    /// Cerrar la última ventana cierra la app (utilidad de una sola ventana): evita que el
    /// proceso quede vivo de fondo, p. ej. con una extracción aún corriendo.
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
