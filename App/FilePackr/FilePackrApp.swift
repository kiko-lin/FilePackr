import SwiftUI
import AppKit

@main
struct FilePackrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
                .environmentObject(Localizer.shared)
                .environmentObject(AppSettings.shared)
        }
        .windowStyle(.hiddenTitleBar)   // sin barra de título "FilePackr"; el contenido sube

        // Ajustes en el menú de la app (⌘,), accesible siempre (también con la app vacía).
        Settings {
            SettingsView()
                .environmentObject(Localizer.shared)
                .environmentObject(AppSettings.shared)
        }
    }
}

/// Avisa al salir de la app (⌘Q) si alguna ventana tiene cambios sin guardar, con el
/// **mismo** aviso unificado (`UnsavedChangesAlert`) que el cierre de ventana y de documento.
/// El cierre de cada ventana por separado lo gestiona `WindowGuard`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sin pestañas de ventana: cada archivo abre en su propia ventana independiente.
    /// Esto también retira los ítems de menú de pestañas (Mostrar barra/Combinar ventanas…).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
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
