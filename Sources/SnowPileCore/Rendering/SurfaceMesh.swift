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

/// Turns a heightmap into four triangle strips of equal length:
/// 0. lower body (base to middle, bluish shadow to near-white),
/// 1. upper body (middle to top, lit by slope),
/// 2. a 1 pt transparent fringe on top as cheap anti-aliasing,
/// 3. a soft shadow cast below the base (windows only, transparent on the ground).
///
/// The drawn outline is irregular on purpose: bumpy, cloud-like caps on windows and a ragged top on the ground.
/// That irregularity is purely visual (deterministic noise); the heightmap stays the truth.
public enum SurfaceMesh {
    public static let stripCount = 4
    static let baseColor = SIMD3<Float>(0.74, 0.80, 0.92)
    static let middleColor = SIMD3<Float>(0.93, 0.95, 0.995)
    static let topColor = SIMD3<Float>(1, 1, 1)
    static let shadowColor = SIMD3<Float>(0.04, 0.06, 0.12)
    static let fringeHeight: Float = 1
    static let shadowDepth: Float = 5
    static let shadowAlpha: Float = 0.28

    public static func stripLength(for surface: Surface) -> Int {
        2 * (surface.heights.count + 1)
    }

    public static func vertexCount(for surface: Surface) -> Int {
        stripCount * stripLength(for: surface)
    }

    /// Height of the snow at a column edge: a triangle-weighted average of the visible columns around it.
    /// The sandpile rule leaves steep 2 pt steps; smoothing turns them into soft drifts. The ragged edge comes from noise.
    @inline(__always)
    static func edgeHeight(_ surface: Surface, edge: Int) -> CGFloat {
        let columns = surface.heights.count
        let reach: Int
        if case .ground = surface.kind { reach = 8 } else { reach = 4 }
        var sum: CGFloat = 0
        var weight: CGFloat = 0
        // Columns edge-reach ..< edge+reach; edge sits between columns edge-1 and edge.
        for c in max(edge - reach, 0)..<min(edge + reach, columns) {
            guard !surface.isHidden(c) else { continue }
            let distance = abs(CGFloat(c) + 0.5 - CGFloat(edge))
            let w = CGFloat(reach) + 0.5 - distance
            sum += surface.heights[c] * w
            weight += w
        }
        // Edges next to a hidden column must not pick up the hidden snow, but also not fade out the visible one.
        let left = max(edge - 1, 0), right = min(edge, columns - 1)
        if surface.isHidden(left) && surface.isHidden(right) { return 0 }
        return weight > 0 ? sum / weight : 0
    }

    /// Drawn height at a column edge: the true height plus visual irregularity, never negative.
    @inline(__always)
    public static func visualHeight(_ surface: Surface, edge: Int, trueHeight h: CGFloat) -> CGFloat {
        guard h > 0 else { return 0 }
        switch surface.kind {
        case .window:
            // Lumps about 20 pt wide that travel with the window (anchored to the column index).
            let u = CGFloat(edge) * Surface.columnWidth
            let bump = Noise.value(u / 20, seed: surface.id) * 0.7 + Noise.value(u / 8, seed: surface.id &+ 3) * 0.3
            // Rounded ends instead of a vertical cut where the cap stops.
            let ends = min(CGFloat(edge), CGFloat(surface.heights.count - edge)) * Surface.columnWidth
            let taper = min(ends / 7, 1)
            return max(h * (1.12 + 0.24 * bump) * (1 - (1 - taper) * (1 - taper)).squareRoot(), 0)
        case .ground:
            // Anchored to absolute x so the ragged edge stays put while snow piles up.
            let x = surface.minX + CGFloat(edge) * Surface.columnWidth
            let coarse = Noise.fractal(x / 9, seed: 7)
            let fine = Noise.value(x / 2.2, seed: 11)
            return max(h + min(h, 10) * (0.12 * coarse + 0.12 * fine), 0)
        }
    }

    /// Strips follow each other in the order listed above, `stripLength` vertices each. Returns the number written.
    /// `offset` (CG directions) shifts the whole mesh, used to predict where a moving window is by the time the frame shows.
    @discardableResult
    public static func build(
        _ surface: Surface, screenFrameCG: CGRect, offset: CGVector = .zero, into buffer: UnsafeMutableBufferPointer<SurfaceVertex>
    ) -> Int {
        let total = vertexCount(for: surface)
        guard buffer.count >= total else { return 0 }

        let columns = surface.heights.count
        let strip = stripLength(for: surface)
        let base = Coordinates.sceneLocal(CGPoint(x: surface.minX + offset.dx, y: surface.baseY + offset.dy), screenFrameCG: screenFrameCG)
        let baseX = Float(base.x)
        let baseY = Float(base.y)
        let width = Float(Surface.columnWidth)
        let castsShadow: Bool
        if case .ground = surface.kind { castsShadow = false } else { castsShadow = true }

        var previousHeight = Float(edgeHeight(surface, edge: 0))
        var height = previousHeight
        for edge in 0...columns {
            let h = CGFloat(height)
            let nextHeight = edge < columns ? Float(edgeHeight(surface, edge: edge + 1)) : height
            let visual = Float(visualHeight(surface, edge: edge, trueHeight: h))
            // Fade in over the first point so an empty surface draws nothing.
            let alpha = Float(min(h, 1))
            let x = baseX + Float(edge) * width
            let topY = baseY + visual
            let middleY = baseY + visual * 0.55

            // Light from the upper left: slopes facing left are a touch brighter, facing right a touch darker.
            // Slope of the smoothed snow, not of the visual noise, so the ragged edge doesn't turn into stripes.
            let slope = (nextHeight - previousHeight) / (2 * width)
            let light = min(max(1 + 0.1 * slope, 0.88), 1)
            // Thin snow shows little depth, so its base stays bright.
            let depth = min(visual / 6, 1)
            let bottom = SIMD3<Float>(1, 1, 1) + (baseColor - SIMD3<Float>(1, 1, 1)) * depth
            let middle = SIMD3<Float>(1, 1, 1) + (middleColor - SIMD3<Float>(1, 1, 1)) * depth
            let top = topColor * light + SIMD3<Float>(0, 0.02, 0.04) * (1 - light)

            let bottomColor = SIMD4(bottom * alpha, alpha)
            let middleColor = SIMD4(middle * alpha, alpha)
            let topColor = SIMD4(top * alpha, alpha)
            buffer[2 * edge] = SurfaceVertex(x, baseY, bottomColor)
            buffer[2 * edge + 1] = SurfaceVertex(x, middleY, middleColor)
            buffer[strip + 2 * edge] = SurfaceVertex(x, middleY, middleColor)
            buffer[strip + 2 * edge + 1] = SurfaceVertex(x, topY, topColor)
            buffer[2 * strip + 2 * edge] = SurfaceVertex(x, topY, topColor)
            buffer[2 * strip + 2 * edge + 1] = SurfaceVertex(x, topY + fringeHeight, .zero)

            let shadow = castsShadow ? shadowAlpha * min(alpha, Float(min(h / 3, 1))) : 0
            buffer[3 * strip + 2 * edge] = SurfaceVertex(x, baseY, SIMD4(shadowColor * shadow, shadow))
            buffer[3 * strip + 2 * edge + 1] = SurfaceVertex(x, baseY - shadowDepth, .zero)

            previousHeight = height
            height = nextHeight
        }
        return total
    }
}
