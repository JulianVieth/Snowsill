import CoreGraphics

/// A falling particle in global CG coordinates (y grows downward).
public struct Flake: Sendable {
    public enum Kind: UInt8, Sendable {
        /// Regular snowfall.
        case snow
        /// Fine snow falling off a window.
        case powder
        /// Coarse, irregular lump of fallen-off snow. Bursts into puffs when it lands.
        case clump
        /// Short-lived dust from a bursting clump. Carries no volume.
        case puff
        /// Broken-off icicle piece. Carries no volume and vanishes on landing.
        case ice
    }

    public var position: CGPoint = .zero
    /// Current velocity. Relaxes toward (`driftX` + wind, `fallSpeed`), so impulses fade out.
    public var velocity: CGVector = .zero
    public var fallSpeed: CGFloat = 0
    public var driftX: CGFloat = 0
    public var radius: CGFloat = 0
    public var swayPhase: CGFloat = 0
    public var swayAmplitude: CGFloat = 0
    public var opacity: CGFloat = 0
    /// Snow volume (pt²) the flake adds to a surface when it lands.
    public var snowVolume: CGFloat = 0
    public var kind: Kind = .snow
    public var rotation: CGFloat = 0
    public var spin: CGFloat = 0
    /// Per-particle random value for the shader (clump outline).
    public var seed: CGFloat = 0
    /// Remaining seconds for puffs; ignored otherwise.
    public var life: CGFloat = 0
    /// Length for ice pieces.
    public var length: CGFloat = 0
    public var isActive = false

    /// Everything that is not regular snowfall comes from the powder pool.
    public var isPowder: Bool { kind != .snow }

    public init() {}
}
