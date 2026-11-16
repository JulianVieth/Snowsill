import CoreGraphics
import Foundation

public struct SnowConfig: Sendable {
    public var maxFlakes = 800
    /// Flakes spawned per second per 1000 pt of screen width.
    public var spawnRate: Double = 40
    public var radiusRange: ClosedRange<CGFloat> = 1.2...3.6

    public init() {}
}

/// Seedable PRNG so tests are deterministic.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct SnowSimulation {
    public static let hardFlakeLimit = 2500
    /// Large gaps (e.g. after sleep) would teleport flakes through surfaces.
    static let maxStep: Double = 0.1
    static let swayFrequency: CGFloat = 1.4

    public let config: SnowConfig
    /// Area flakes fall through, in CG coordinates.
    public var bounds: CGRect
    public private(set) var flakes: ContiguousArray<Flake>
    public private(set) var activeCount = 0

    private var freeSlots: ContiguousArray<Int>
    private var spawnAccumulator: Double = 0
    private var rng: SplitMix64

    public init(config: SnowConfig = SnowConfig(), bounds: CGRect, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        var config = config
        config.maxFlakes = min(max(config.maxFlakes, 0), Self.hardFlakeLimit)
        self.config = config
        self.bounds = bounds
        self.rng = SplitMix64(seed: seed)
        flakes = ContiguousArray(repeating: Flake(), count: config.maxFlakes)
        freeSlots = ContiguousArray((0..<config.maxFlakes).reversed())
    }

    public mutating func step(dt rawDt: Double) {
        guard rawDt > 0 else { return }
        let dt = min(rawDt, Self.maxStep)

        spawnAccumulator += config.spawnRate * Double(bounds.width / 1000) * dt
        while spawnAccumulator >= 1 {
            spawnAccumulator -= 1
            spawn()
        }

        let t = CGFloat(dt)
        let margin: CGFloat = 40
        for i in flakes.indices where flakes[i].isActive {
            var flake = flakes[i]
            flake.swayPhase += Self.swayFrequency * t
            flake.position.x += (flake.velocity.dx + sin(flake.swayPhase) * flake.swayAmplitude) * t
            flake.position.y += flake.velocity.dy * t

            if flake.position.y - flake.radius > bounds.maxY
                || flake.position.x < bounds.minX - margin
                || flake.position.x > bounds.maxX + margin {
                flake.isActive = false
                freeSlots.append(i)
                activeCount -= 1
            }
            flakes[i] = flake
        }
    }

    public mutating func reset() {
        for i in flakes.indices { flakes[i].isActive = false }
        freeSlots.removeAll(keepingCapacity: true)
        freeSlots.append(contentsOf: (0..<flakes.count).reversed())
        activeCount = 0
        spawnAccumulator = 0
    }

    private mutating func spawn() {
        guard let slot = freeSlots.popLast() else { return }
        let radius = CGFloat.random(in: config.radiusRange, using: &rng)
        var flake = Flake()
        flake.radius = radius
        flake.position = CGPoint(
            x: CGFloat.random(in: bounds.minX...bounds.maxX, using: &rng),
            y: bounds.minY - radius - CGFloat.random(in: 0...30, using: &rng)
        )
        // Larger flakes fall faster; a bit of jitter keeps them from moving in lockstep.
        let fallSpeed = 28 + 16 * radius + CGFloat.random(in: -6...6, using: &rng)
        flake.velocity = CGVector(dx: CGFloat.random(in: -4...4, using: &rng), dy: fallSpeed)
        flake.swayPhase = CGFloat.random(in: 0...(2 * .pi), using: &rng)
        flake.swayAmplitude = CGFloat.random(in: 6...18, using: &rng)
        flake.opacity = CGFloat.random(in: 0.65...1.0, using: &rng)
        flake.isActive = true
        flakes[slot] = flake
        activeCount += 1
    }
}
