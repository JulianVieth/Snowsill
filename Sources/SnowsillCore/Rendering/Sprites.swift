import CoreGraphics

/// One instanced quad, in scene-local points. Layout must match `Sprite` in the shader source.
/// The fragment shader draws `shape` procedurally inside the quad.
public struct Sprite: Equatable {
    public enum Shape: Float {
        /// Soft round flake.
        case flake = 0
        /// Irregular lump of snow (outline from `seed`).
        case clump = 1
        /// Shaded snowball.
        case ball = 2
        /// Flat disc in `color`, anti-aliased.
        case disc = 3
        /// Rounded rectangle in `color`; `param` is the corner radius in points.
        case rect = 4
        /// Triangle pointing along local +x, base at -x.
        case triangle = 5
        /// Translucent icicle hanging down from the top of the quad.
        case icicle = 6
        /// Mound of snow: upper half of an ellipse with a bumpy top.
        case mound = 7
    }

    public var position: SIMD2<Float> = .zero
    /// Half extents.
    public var size: SIMD2<Float> = .zero
    /// Straight (not premultiplied) color; alpha is the opacity.
    public var color: SIMD4<Float> = .zero
    public var rotation: Float = 0
    public var shape: Float = 0
    public var seed: Float = 0
    public var param: Float = 0

    public init() {}

    public init(
        _ shape: Shape, at position: SIMD2<Float>, size: SIMD2<Float>, color: SIMD4<Float> = SIMD4(1, 1, 1, 1),
        rotation: Float = 0, seed: Float = 0, param: Float = 0
    ) {
        self.position = position
        self.size = size
        self.color = color
        self.rotation = rotation
        self.shape = shape.rawValue
        self.seed = seed
        self.param = param
    }
}

/// Writes sprites into a fixed buffer without allocating; extra sprites beyond capacity are dropped.
public struct SpriteWriter {
    public let buffer: UnsafeMutableBufferPointer<Sprite>
    public private(set) var count = 0
    public let screenFrameCG: CGRect

    public init(buffer: UnsafeMutableBufferPointer<Sprite>, screenFrameCG: CGRect) {
        self.buffer = buffer
        self.screenFrameCG = screenFrameCG
    }

    public var isFull: Bool { count >= buffer.count }

    /// `point` in global CG coordinates; rotation is clockwise on screen for positive angles in CG terms.
    @inline(__always)
    public mutating func add(
        _ shape: Sprite.Shape, at point: CGPoint, size: CGSize, color: SIMD4<Float> = SIMD4(1, 1, 1, 1),
        rotation: CGFloat = 0, seed: CGFloat = 0, param: CGFloat = 0
    ) {
        guard count < buffer.count else { return }
        let p = Coordinates.sceneLocal(point, screenFrameCG: screenFrameCG)
        // Discs are round: a missing height means "same as the width".
        let size = shape == .disc && size.height == 0 ? CGSize(width: size.width, height: size.width) : size
        // CG y points down, the scene's y up: a clockwise CG rotation is negative in scene space.
        buffer[count] = Sprite(
            shape, at: SIMD2(Float(p.x), Float(p.y)), size: SIMD2(Float(size.width), Float(size.height)),
            color: color, rotation: Float(-rotation), seed: Float(seed), param: Float(param)
        )
        count += 1
    }
}

public enum FlakeSprites {
    /// Writes all active particles. Returns how many sprites were written.
    @discardableResult
    public static func pack(_ flakes: ContiguousArray<Flake>, into writer: inout SpriteWriter) -> Int {
        let start = writer.count
        let iceColor = SIMD4<Float>(0.82, 0.93, 1.0, 0.9)
        flakes.withUnsafeBufferPointer { flakes in
            for flake in flakes where flake.isActive {
                guard !writer.isFull else { return }
                let r = flake.radius
                switch flake.kind {
                case .snow, .powder:
                    writer.add(.flake, at: flake.position, size: CGSize(width: r, height: r),
                               color: SIMD4(1, 1, 1, Float(flake.opacity)))
                case .puff:
                    let fade = Float(min(flake.life / 0.25, 1))
                    writer.add(.flake, at: flake.position, size: CGSize(width: r, height: r),
                               color: SIMD4(1, 1, 1, Float(flake.opacity) * fade))
                case .clump:
                    writer.add(.clump, at: flake.position, size: CGSize(width: r * 1.25, height: r * 1.25),
                               color: SIMD4(1, 1, 1, Float(flake.opacity)), rotation: flake.rotation, seed: flake.seed)
                case .ice:
                    writer.add(.icicle, at: flake.position, size: CGSize(width: max(r, 1.5), height: flake.length / 2),
                               color: iceColor, rotation: flake.rotation, seed: flake.seed)
                }
            }
        }
        return writer.count - start
    }
}
