import Foundation

/// Unidad de tamaño de volumen (división de un archivo en partes). La usa `SaveCoordinator`
/// (modelo) y la hoja de guardar (vista), por eso vive en el modelo y no en la vista.
public enum VolumeUnit: String, CaseIterable, Identifiable, Sendable {
    case kilobytes = "KB", megabytes = "MB", gigabytes = "GB"
    public var id: String { rawValue }
    public var multiplier: Int {
        switch self {
        case .kilobytes: return 1024
        case .megabytes: return 1024 * 1024
        case .gigabytes: return 1024 * 1024 * 1024
        }
    }
}
