import CoreGraphics

/// A falling flake in global CG coordinates (y grows downward).
public struct Flake: Sendable {
    public var position: CGPoint = .zero
    public var velocity: CGVector = .zero
    public var radius: CGFloat = 0
    public var swayPhase: CGFloat = 0
    public var swayAmplitude: CGFloat = 0
    public var opacity: CGFloat = 0
    public var isActive = false

    public init() {}
}
