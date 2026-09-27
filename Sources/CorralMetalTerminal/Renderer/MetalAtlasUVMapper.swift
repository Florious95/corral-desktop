import CorralContracts
import Foundation

public struct MetalAtlasUVRect: Equatable, Sendable {
    public let topLeft: SIMD2<Float>
    public let bottomRight: SIMD2<Float>
}

public enum MetalAtlasUVMapper {
    /// Atlas coordinates use Metal's top-left texture origin, matching the stage's top-down screen rows.
    public static func map(coordinates: AtlasCoordinates, textureSize: MetalStagePixelSize) -> MetalAtlasUVRect? {
        let x = Int(coordinates.x)
        let y = Int(coordinates.y)
        let width = Int(coordinates.width)
        let height = Int(coordinates.height)
        guard textureSize.width > 0, textureSize.height > 0, width > 0, height > 0,
              x >= 0, y >= 0, x + width <= textureSize.width, y + height <= textureSize.height else { return nil }

        let textureWidth = Double(textureSize.width)
        let textureHeight = Double(textureSize.height)
        return MetalAtlasUVRect(
            topLeft: SIMD2(
                Float((Double(x) + 0.5) / textureWidth),
                Float((Double(y) + 0.5) / textureHeight)
            ),
            bottomRight: SIMD2(
                Float((Double(x + width) - 0.5) / textureWidth),
                Float((Double(y + height) - 0.5) / textureHeight)
            )
        )
    }
}
