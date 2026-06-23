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

/// Hoja **propia** (compacta y localizada) de Guardar/Exportar: nombre, carpeta destino,
/// formato, cifrado, contraseña y división en volúmenes. El navegador de carpetas nativo solo
/// aparece, transitorio, al pulsar "Elegir…" (`onChooseFolder`), así esta hoja nunca se deforma.
/// Si el destino ya existe, pide confirmación antes de sobrescribir.
struct SaveOptionsSheet: View {
    @EnvironmentObject var loc: Localizer
    @ObservedObject var coord: SaveCoordinator
    /// Los formatos de un solo fichero (gz/xz) solo se ofrecen si el documento es un fichero.
    let allowSingleFileFormats: Bool
    /// Título de la hoja y etiqueta del botón de confirmar (Guardar vs Exportar).
    let title: String
    let confirmLabel: String
    var onChooseFolder: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @State private var confirmingOverwrite = false

    private var formats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { $0.isWritable && (!$0.isSingleFileOnly || allowSingleFileFormats) }
    }

    /// Pulsa confirmar: si el destino ya existe, pide confirmación; si no, sigue.
    private func attemptConfirm() {
        if FileManager.default.fileExists(atPath: coord.resolvedURL.path) { confirmingOverwrite = true }
        else { onConfirm() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Form {
                HStack {
                    Text(loc("save.name"))
                    Spacer()
                    TextField("", text: $coord.name)
                        .frame(width: 200).textFieldStyle(.roundedBorder)
                        .onSubmit { if coord.canConfirm { attemptConfirm() } }
                    Text("." + coord.format.fileExtension).foregroundStyle(.secondary)
                }
                HStack {
                    Text(loc("save.where"))
                    Spacer()
                    Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 16, height: 16)
                    Text(coord.destination.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Button(loc("extract.choose"), action: onChooseFolder)
                }
                Picker(loc("save.format"), selection: $coord.format) {
                    ForEach(formats, id: \.self) { Text(loc($0.nameKey)).tag($0) }
                }
                if coord.format.supportsEncryption {
                    Picker(loc("save.encryption"), selection: $coord.encryption) {
                        Text(loc("save.encryption.none")).tag(ZipEncryption.none)
                        Text(loc("save.encryption.weak")).tag(ZipEncryption.zipCrypto)
                        Text(loc("save.encryption.strong")).tag(ZipEncryption.aes256)
                    }
                    if coord.encryption != .none {
                        SecureField(loc("save.password"), text: $coord.password)
                            .onSubmit { if coord.canConfirm { attemptConfirm() } }
                    }
                } else {
                    Text(loc("save.noEncryption")).font(.callout).foregroundStyle(.secondary)
                }
                if coord.format.supportsVolumeSplit {
                    Toggle(loc("save.split"), isOn: $coord.splitEnabled)
                    if coord.splitEnabled {
                        HStack {
                            Text(loc("save.volumeSize"))
                            Spacer()
                            TextField("", value: $coord.volumeSize, format: .number)
                                .frame(width: 70).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                            Picker("", selection: $coord.volumeUnit) {
                                ForEach(VolumeUnit.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden().frame(width: 70)
                        }
                        Text(loc("save.split.hint", coord.format.fileExtension, coord.format.fileExtension))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(loc("button.cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: attemptConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coord.canConfirm)
            }
        }
        .padding(20)
        .frame(width: 460)
        .confirmationDialog(loc("save.overwrite.title", coord.resolvedURL.lastPathComponent),
                            isPresented: $confirmingOverwrite, titleVisibility: .visible) {
            Button(loc("save.overwrite.confirm"), role: .destructive, action: onConfirm)
            Button(loc("button.cancel"), role: .cancel) {}
        } message: {
            Text(loc("save.overwrite.message", coord.resolvedURL.lastPathComponent))
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
