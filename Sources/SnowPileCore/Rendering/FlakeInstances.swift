import CoreGraphics

/// Per-flake GPU instance data in scene-local points. Layout must match `FlakeInstance` in the shader source.
public struct FlakeInstance: Equatable {
    public var position: SIMD2<Float> = .zero
    public var radius: Float = 0
    public var opacity: Float = 0

    public init() {}
}

public enum FlakeInstances {
    /// Writes all active flakes contiguously into `buffer` and returns how many were written.
    @discardableResult
    public static func pack(
        _ flakes: ContiguousArray<Flake>,
        screenFrameCG: CGRect,
        into buffer: UnsafeMutableBufferPointer<FlakeInstance>
    ) -> Int {
        var count = 0
        flakes.withUnsafeBufferPointer { flakes in
            for flake in flakes where flake.isActive {
                guard count < buffer.count else { return }
                let p = Coordinates.sceneLocal(flake.position, screenFrameCG: screenFrameCG)
                buffer[count] = FlakeInstance(
                    position: SIMD2(Float(p.x), Float(p.y)),
                    radius: Float(flake.radius),
                    opacity: Float(flake.opacity)
                )
                count += 1
            }
        }
        return count
    }
}

extension FlakeInstance {
    init(position: SIMD2<Float>, radius: Float, opacity: Float) {
        self.position = position
        self.radius = radius
        self.opacity = opacity
    }
}
