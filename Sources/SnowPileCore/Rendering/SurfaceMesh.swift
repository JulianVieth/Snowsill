import CoreGraphics

/// Vertex of a snow surface in scene-local points with premultiplied color. Layout must match `SurfaceVertex` in the shader source.
public struct SurfaceVertex: Equatable {
    public var position: SIMD2<Float> = .zero
    public var color: SIMD4<Float> = .zero

    public init() {}

    init(_ x: Float, _ y: Float, _ color: SIMD4<Float>) {
        position = SIMD2(x, y)
        self.color = color
    }
}

/// Turns a heightmap into two triangle strips: the snow body, and a 1 pt transparent fringe on top as cheap anti-aliasing.
public enum SurfaceMesh {
    static let top = SIMD3<Float>(1, 1, 1)
    static let shadow = SIMD3<Float>(0.84, 0.89, 0.97)
    static let fringeHeight: Float = 1

    public static func vertexCount(for surface: Surface) -> Int {
        4 * (surface.heights.count + 1)
    }

    /// Body strip comes first (`vertexCount / 2` vertices), then the fringe strip. Returns the number of vertices written.
    /// `offset` (CG directions) shifts the whole mesh, used to predict where a moving window is by the time the frame shows.
    @discardableResult
    public static func build(
        _ surface: Surface, screenFrameCG: CGRect, offset: CGVector = .zero, into buffer: UnsafeMutableBufferPointer<SurfaceVertex>
    ) -> Int {
        let total = vertexCount(for: surface)
        guard buffer.count >= total else { return 0 }

        let heights = surface.heights
        let columns = heights.count
        let base = Coordinates.sceneLocal(CGPoint(x: surface.minX + offset.dx, y: surface.baseY + offset.dy), screenFrameCG: screenFrameCG)
        let baseX = Float(base.x)
        let baseY = Float(base.y)
        let width = Float(Surface.columnWidth)
        let fringeStart = total / 2

        for edge in 0...columns {
            // Averaging neighbors at column edges smooths the 2 pt steps.
            let left = heights[max(edge - 1, 0)]
            let right = heights[min(edge, columns - 1)]
            let height = Float((left + right) / 2)
            // Fade in over the first point so an empty surface draws nothing.
            let alpha = min(height, 1)
            let x = baseX + Float(edge) * width
            let topY = baseY + height

            let topColor = SIMD4(top * alpha, alpha)
            buffer[2 * edge] = SurfaceVertex(x, baseY, SIMD4(shadow * alpha, alpha))
            buffer[2 * edge + 1] = SurfaceVertex(x, topY, topColor)
            buffer[fringeStart + 2 * edge] = SurfaceVertex(x, topY, topColor)
            buffer[fringeStart + 2 * edge + 1] = SurfaceVertex(x, topY + fringeHeight, .zero)
        }
        return total
    }
}
