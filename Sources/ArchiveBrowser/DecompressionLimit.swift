import Foundation

/// Cota anti «bomba de descompresión» para los códecs en streaming (gzip/xz/bzip2). A diferencia
/// de DEFLATE en ZIP —donde el tamaño descomprimido viene declarado por entrada y se valida en
/// `Deflate`—, estos flujos no traen tamaño previo y LZMA/bzip2 alcanzan ratios enormes, así que
/// una entrada minúscula podría expandirse sin límite: **OOM** en la ruta a memoria
/// (`SingleFileCodec.entryData`, Quick Look) o llenar el disco en streaming. Se limita la salida
/// total a `input × maxRatio + floor`; al superarse, el bucle de descompresión aborta.
public struct DecompressionLimit: Sendable {
    public let maxRatio: Int
    public let floor: Int

    public init(maxRatio: Int, floor: Int) {
        self.maxRatio = maxRatio
        self.floor = floor
    }

    /// Por defecto: ratio **10 000** + **64 MiB** de margen. Holgado para datos legítimos muy
    /// comprimibles (incluso 1 GB de ceros con xz ronda ~7000:1, por debajo del límite), pero
    /// corta las bombas reales, que son de 10⁵–10⁹:1 (p. ej. 42.zip ≈ 10⁹:1). El `floor` evita
    /// falsos positivos en ficheros pequeños.
    public static let standard = DecompressionLimit(maxRatio: 10_000, floor: 64 * 1024 * 1024)

    /// ¿La salida acumulada (`output`) supera lo permitido para la entrada consumida (`input`)?
    func isExceeded(output: Int, input: Int) -> Bool {
        output > input * maxRatio + floor
    }
}

public enum DecompressionLimitError: Error, Equatable {
    /// La salida descomprimida superó la cota anti-bomba (`DecompressionLimit`).
    case bombDetected
}
