import SwiftUI
import AppKit

/// Aviso **único** de "cambios sin guardar", para que los tres caminos de cierre
/// (botón Cerrar, cerrar ventana, salir de la app) muestren exactamente el mismo
/// diálogo: mismo texto, mismos botones y mismo estilo (NSAlert como hoja).
enum UnsavedChangesAlert {
    /// Lo que elige el usuario: guardar y continuar, continuar descartando, o cancelar.
    enum Choice { case save, discard, cancel }

    /// Presenta el aviso sobre `window` (o modal si no hay ventana) con tres botones:
    /// Guardar (acción por defecto), Continuar (descarta) y Cancelar.
    @MainActor
    static func present(on window: NSWindow?, completion: @escaping (Choice) -> Void) {
        let alert = NSAlert()
        alert.messageText = Localizer.shared("unsaved.title")
        alert.informativeText = Localizer.shared("unsaved.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: Localizer.shared("button.save"))        // 1º → por defecto (Intro)
        let cancel = alert.addButton(withTitle: Localizer.shared("button.cancel"))      // 2º
        cancel.keyEquivalent = "\u{1b}"                                    //   Escape cancela
        let discard = alert.addButton(withTitle: Localizer.shared("unsaved.dontSave"))  // 3º → a la izquierda
        discard.hasDestructiveAction = true

        func choice(for response: NSApplication.ModalResponse) -> Choice {
            switch response {
            case .alertFirstButtonReturn: return .save
            case .alertThirdButtonReturn: return .discard
            default: return .cancel
            }
        }
        if let window {
            alert.beginSheetModal(for: window) { completion(choice(for: $0)) }
        } else {
            completion(choice(for: alert.runModal()))
        }
    }
}

/// Manejadores de guardado por ventana, para que el cierre de la app (⌘Q) pueda lanzar
/// el flujo de guardado (que vive en la vista SwiftUI) de la ventana con cambios.
/// Cada `WindowGuard` registra el suyo al adjuntarse a su ventana.
@MainActor
enum WindowSaveHandlers {
    /// ventana → (ejecuta el guardado; llama a la continuación al guardar con éxito).
    static var handlers: [ObjectIdentifier: (@escaping () -> Void) -> Void] = [:]
}

/// Marca la ventana como **editada** (el punto en el botón rojo) y, si se intenta cerrarla
/// con cambios sin guardar, muestra el aviso unificado antes de descartarlos.
///
/// SwiftUI no expone intercepción del cierre de ventana, así que se puentea al `NSWindow`:
/// nos ponemos como su delegado para atrapar `windowShouldClose` y reenviamos el resto de
/// mensajes al delegado original de SwiftUI para no romper su gestión de ventanas.
struct WindowGuard: NSViewRepresentable {
    var edited: Bool
    /// Ejecuta el flujo de guardado de la vista; llama a la continuación al guardar con éxito.
    var onSave: (@escaping () -> Void) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.edited = edited
        context.coordinator.onSave = onSave
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSWindowDelegate {
        var edited = false { didSet { window?.isDocumentEdited = edited } }
        var onSave: ((@escaping () -> Void) -> Void)?
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
            // Registrar el guardado de esta ventana para el flujo de salir (⌘Q).
            WindowSaveHandlers.handlers[ObjectIdentifier(window)] = { [weak self] done in
                self?.onSave?(done) ?? done()
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard edited else { return true }
            UnsavedChangesAlert.present(on: sender) { [weak self] choice in
                switch choice {
                case .cancel: break
                case .discard: self?.forceClose(sender)
                case .save: self?.onSave?({ self?.forceClose(sender) }) ?? self?.forceClose(sender)
                }
            }
            return false   // no cerrar todavía: decide la hoja
        }

        /// Cierra la ventana saltándose el aviso (ya resuelto): quita la marca de editada.
        private func forceClose(_ sender: NSWindow) {
            edited = false
            sender.isDocumentEdited = false
            sender.close()
        }

        /// Al cerrarse la ventana (por cualquier vía) retiramos su manejador de guardado
        /// para no dejar entradas huérfanas en `WindowSaveHandlers`. Reenviamos al delegado
        /// original de SwiftUI por si depende de este aviso para su propia limpieza.
        func windowWillClose(_ notification: Notification) {
            if let window { WindowSaveHandlers.handlers[ObjectIdentifier(window)] = nil }
            previousDelegate?.windowWillClose?(notification)
        }

        // Transparencia: cualquier mensaje del delegado que no manejemos va al de SwiftUI.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (previousDelegate?.responds(to: aSelector) ?? false)
        }
        override func forwardingTarget(for aSelector: Selector!) -> Any? { previousDelegate }
    }
}
