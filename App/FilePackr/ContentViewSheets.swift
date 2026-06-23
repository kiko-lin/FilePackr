import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveBrowser

/// Hojas modales de `ContentView` (guardar/exportar, extraer y contraseña) y la unidad
/// de tamaño de volumen que comparten. Son vistas autocontenidas: reciben sus datos por
/// `@Binding` y comunican el resultado con closures `onSave`/`onExtract`/`onConfirm`, sin
/// conocer el documento ni la cola de operaciones (eso vive en `ContentView`).

/// Unidad de tamaño de volumen.
enum VolumeUnit: String, CaseIterable, Identifiable {
    case kilobytes = "KB", megabytes = "MB", gigabytes = "GB"
    var id: String { rawValue }
    var multiplier: Int {
        switch self {
        case .kilobytes: return 1024
        case .megabytes: return 1024 * 1024
        case .gigabytes: return 1024 * 1024 * 1024
        }
    }
}

/// Vista accesoria incrustada en el **panel nativo** de Guardar/Exportar: formato, cifrado,
/// contraseña y división en volúmenes. Observa el `SaveCoordinator` (estado compartido con el
/// panel); al cambiar de formato avisa con `onFormatChange` para que el panel reajuste el
/// nombre propuesto, la extensión y los tipos permitidos. La validación de la contraseña la hace
/// el propio panel (ver `SavePanelValidator`), no un botón aquí.
struct SavePanelAccessory: View {
    @EnvironmentObject var loc: Localizer
    @ObservedObject var coord: SaveCoordinator
    /// Los formatos de un solo fichero (gz/xz) solo se ofrecen si el documento es un fichero.
    let allowSingleFileFormats: Bool
    var onFormatChange: (ArchiveFormat) -> Void

    private var formats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { $0.isWritable && (!$0.isSingleFileOnly || allowSingleFileFormats) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(loc("save.format")) {
                Picker("", selection: $coord.format) {
                    ForEach(formats, id: \.self) { Text(loc($0.nameKey)).tag($0) }
                }
                .labelsHidden().frame(width: 230)
            }
            if coord.format.supportsEncryption {
                row(loc("save.encryption")) {
                    Picker("", selection: $coord.encryption) {
                        Text(loc("save.encryption.none")).tag(ZipEncryption.none)
                        Text(loc("save.encryption.weak")).tag(ZipEncryption.zipCrypto)
                        Text(loc("save.encryption.strong")).tag(ZipEncryption.aes256)
                    }
                    .labelsHidden().frame(width: 230)
                }
                if coord.encryption != .none {
                    SecureField(loc("save.password"), text: $coord.password)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if coord.format.supportsVolumeSplit {
                Toggle(loc("save.split"), isOn: $coord.splitEnabled)
                if coord.splitEnabled {
                    row(loc("save.volumeSize")) {
                        TextField("", value: $coord.volumeSize, format: .number)
                            .frame(width: 70).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                        Picker("", selection: $coord.volumeUnit) {
                            ForEach(VolumeUnit.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 70)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 480)
        .onChange(of: coord.format) { _, format in onFormatChange(format) }
    }

    /// Fila "etiqueta … control(es)" alineada a derecha, para el formato/cifrado/tamaño.
    private func row(_ label: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer()
            control()
        }
    }
}

/// Delegado de validación del panel de Guardar: si `message()` devuelve un texto, impide
/// confirmar (el panel muestra ese error y permanece abierto). Lo usa el flujo de guardado para
/// exigir contraseña cuando se ha elegido cifrado, sin sacar un botón propio del panel nativo.
final class SavePanelValidator: NSObject, NSOpenSavePanelDelegate {
    private let message: () -> String?
    init(message: @escaping () -> String?) { self.message = message }

    func panel(_ sender: Any, validate url: URL) throws {
        if let message = message() {
            throw NSError(domain: "FilePackr", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

/// Hoja compacta de extracción: solo el destino (carpeta del archivo por defecto). El navegador
/// de carpetas aparece al pulsar "Elegir…". La contraseña, si el archivo está cifrado, se pide
/// **antes** (al desbloquear), así que aquí ya no hace falta.
struct ExtractOptionsSheet: View {
    @EnvironmentObject var loc: Localizer
    let nodeName: String
    @Binding var destination: URL
    var onChooseFolder: () -> Void
    var onExtract: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc("extract.title", nodeName)).font(.headline)
            HStack(spacing: 6) {
                Text(loc("extract.in")).foregroundStyle(.secondary)
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .resizable().frame(width: 16, height: 16)
                Text(destination.lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(loc("extract.choose"), action: onChooseFolder)
            }
            HStack {
                Spacer()
                Button(loc("button.cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(loc("button.extract"), action: onExtract).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Hoja de introducción de contraseña.
struct PasswordSheet: View {
    @EnvironmentObject var loc: Localizer
    let title: String
    let confirmLabel: String
    @Binding var password: String
    var note: String? = nil
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            SecureField(loc("password.field"), text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { if !password.isEmpty { onConfirm() } }
            if let note {
                Text(note).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(loc("button.cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
    }
}
