import SwiftUI
import AppKit

/// Aviso **único** de "cambios sin guardar", para que los tres caminos de cierre
/// (botón Cerrar, cerrar ventana, salir de la app) muestren exactamente el mismo
/// diálogo: mismo texto, mismos botones y mismo estilo (NSAlert como hoja).
enum UnsavedChangesAlert {
    /// Presenta el aviso sobre `window` (o modal si no hay ventana). Llama a `completion`
    /// con `true` si el usuario elige descartar, `false` si cancela.
    @MainActor
    static func present(on window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = Localizer.shared("unsaved.title")
        alert.informativeText = Localizer.shared("unsaved.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: Localizer.shared("unsaved.discard")).hasDestructiveAction = true
        alert.addButton(withTitle: Localizer.shared("button.cancel"))
        if let window {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

/// Marca la ventana como **editada** (el punto en el botón rojo) y, si se intenta cerrarla
/// con cambios sin guardar, muestra el aviso unificado antes de descartarlos.
///
/// SwiftUI no expone intercepción del cierre de ventana, así que se puentea al `NSWindow`:
/// nos ponemos como su delegado para atrapar `windowShouldClose` y reenviamos el resto de
/// mensajes al delegado original de SwiftUI para no romper su gestión de ventanas.
struct WindowGuard: NSViewRepresentable {
    var edited: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.edited = edited
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSWindowDelegate {
        var edited = false { didSet { window?.isDocumentEdited = edited } }
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                self.window = window
                if window.delegate !== self {
                    previousDelegate = window.delegate
                    window.delegate = self
                }
            }
            window.isDocumentEdited = edited
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard edited else { return true }
            UnsavedChangesAlert.present(on: sender) { [weak self] discard in
                guard discard else { return }
                self?.edited = false
                sender.isDocumentEdited = false
                sender.close()
            }
            return false   // no cerrar todavía: decide la hoja
        }

        // Transparencia: cualquier mensaje del delegado que no manejemos va al de SwiftUI.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (previousDelegate?.responds(to: aSelector) ?? false)
        }
        override func forwardingTarget(for aSelector: Selector!) -> Any? { previousDelegate }
    }
}
