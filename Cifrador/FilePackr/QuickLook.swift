import SwiftUI
import AppKit
import QuickLookUI

/// Coordina el panel flotante de Quick Look (el de la barra espaciadora del Finder).
/// Recibe una lista de "planes" de exportación; materializa cada uno (extrayéndolo
/// del ZIP) de forma perezosa y con caché solo cuando el panel lo pide.
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var controllerView: QuickLookControllerView?
    private var plans: [ExportPlan] = []
    private var cache: [Int: URL] = [:]

    /// Abre el panel (o lo cierra si ya está visible) con `plans`, situándose en `startIndex`.
    func toggle(plans: [ExportPlan], startIndex: Int) {
        guard let panel = QLPreviewPanel.shared() else { return }

        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
            return
        }

        self.plans = plans
        self.cache = [:]

        // Hacemos primera respondedora a nuestra vista para que el panel, al
        // recorrer la cadena de respondedores, encuentre nuestro data source.
        if let view = controllerView, let window = view.window {
            window.makeFirstResponder(view)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        if !plans.isEmpty {
            panel.currentPreviewItemIndex = max(0, min(startIndex, plans.count - 1))
        }
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { plans.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        if let url = cache[index] { return url as NSURL }
        let url = (try? plans[index].materialize()) ?? URL(fileURLWithPath: "/dev/null")
        cache[index] = url
        return url as NSURL
    }
}

/// Vista invisible que participa en la cadena de respondedores para ceder el
/// control del panel de Quick Look a nuestro coordinador.
final class QuickLookControllerView: NSView {
    weak var coordinator: QuickLookCoordinator?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = coordinator
        panel.delegate = coordinator
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

/// Inserta la vista controladora (invisible) en la jerarquía SwiftUI.
struct QuickLookHost: NSViewRepresentable {
    let coordinator: QuickLookCoordinator

    func makeNSView(context: Context) -> QuickLookControllerView {
        let view = QuickLookControllerView()
        view.coordinator = coordinator
        coordinator.controllerView = view
        return view
    }

    func updateNSView(_ nsView: QuickLookControllerView, context: Context) {}
}
