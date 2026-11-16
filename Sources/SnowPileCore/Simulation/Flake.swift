import CoreGraphics

/// A falling flake in global CG coordinates (y grows downward).
public struct Flake: Sendable {
    public var position: CGPoint = .zero
    /// Current velocity. Relaxes toward (`driftX`, `fallSpeed`), so impulses from shaken-off snow fade out.
    public var velocity: CGVector = .zero
    public var fallSpeed: CGFloat = 0
    public var driftX: CGFloat = 0
    public var radius: CGFloat = 0
    public var swayPhase: CGFloat = 0
    public var swayAmplitude: CGFloat = 0
    public var opacity: CGFloat = 0
    /// Snow volume (pt²) the flake adds to a surface when it lands.
    public var snowVolume: CGFloat = 0
    public var isActive = false

    public init() {}
}
