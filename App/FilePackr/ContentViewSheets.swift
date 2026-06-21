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

/// Hoja "Guardar archivo": formato, cifrado, contraseña y división en volúmenes.
struct SaveOptionsSheet: View {
    @EnvironmentObject var loc: Localizer
    @Binding var format: ArchiveFormat
    @Binding var encryption: ZipEncryption
    @Binding var password: String
    @Binding var splitEnabled: Bool
    @Binding var volumeSize: Double
    @Binding var volumeUnit: VolumeUnit
    /// Los formatos de un solo fichero (gz/xz) solo se ofrecen si el documento es un fichero.
    let allowSingleFileFormats: Bool
    /// Título de la hoja y etiqueta del botón de confirmar (Guardar vs Exportar).
    let title: String
    let confirmLabel: String
    var onSave: () -> Void
    var onCancel: () -> Void

    private var formats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { $0.isWritable && (!$0.isSingleFileOnly || allowSingleFileFormats) }
    }

    /// El botón Guardar se bloquea si falta la contraseña o el tamaño de volumen no es válido.
    private var canSave: Bool {
        if format.supportsEncryption && encryption != .none && password.isEmpty { return false }
        if splitEnabled && format.supportsVolumeSplit && volumeSize <= 0 { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Form {
                Picker(loc("save.format"), selection: $format) {
                    ForEach(formats, id: \.self) { fmt in
                        Text(loc(fmt.nameKey)).tag(fmt)
                    }
                }
                if format.supportsEncryption {
                    Picker(loc("save.encryption"), selection: $encryption) {
                        Text(loc("save.encryption.none")).tag(ZipEncryption.none)
                        Text(loc("save.encryption.weak")).tag(ZipEncryption.zipCrypto)
                        Text(loc("save.encryption.strong")).tag(ZipEncryption.aes256)
                    }
                    if encryption != .none {
                        SecureField(loc("save.password"), text: $password)
                            .onSubmit { if canSave { onSave() } }
                    }
                } else {
                    Text(loc("save.noEncryption"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if format.supportsVolumeSplit {
                    Toggle(loc("save.split"), isOn: $splitEnabled)
                    if splitEnabled {
                        HStack {
                            Text(loc("save.volumeSize"))
                            Spacer()
                            TextField("", value: $volumeSize, format: .number)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                            Picker("", selection: $volumeUnit) {
                                ForEach(VolumeUnit.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 70)
                        }
                        Text(loc("save.split.hint", format.fileExtension, format.fileExtension))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(loc("button.cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Hoja compacta de extracción: destino (carpeta del zip por defecto) + contraseña.
/// El navegador de carpetas solo aparece al pulsar "Elegir…".
struct ExtractOptionsSheet: View {
    @EnvironmentObject var loc: Localizer
    let nodeName: String
    let needsPassword: Bool
    @Binding var destination: URL
    @Binding var password: String
    var passwordWrong: Bool
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
            if needsPassword {
                SecureField(loc("extract.password"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !password.isEmpty { onExtract() } }
                if passwordWrong {
                    Text(loc("extract.wrongPassword")).font(.callout).foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                Button(loc("button.cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(loc("button.extract"), action: onExtract)
                    .keyboardShortcut(.defaultAction)
                    .disabled(needsPassword && password.isEmpty)
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
