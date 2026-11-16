import CoreGraphics
import Foundation

public struct SnowConfig: Sendable {
    public var maxFlakes = 800
    /// Flakes spawned per second per 1000 pt of screen width.
    public var spawnRate: Double = 40
    public var radiusRange: ClosedRange<CGFloat> = 1.2...3.6
    public var groundEnabled = true
    public var groundMaxHeight: CGFloat = 50
    public var windowMaxHeight: CGFloat = 14
    /// Keeps snow off the rounded window corners.
    public var windowCornerInset: CGFloat = 12
    /// Share of a flake's disc area that ends up as lying snow. Tuned so the ground fills in about five minutes.
    public var volumeScale: CGFloat = 0.25
    /// Share of the pool regular snowfall must leave free, so snow shaken off a window can always fall.
    public var reservedFlakeShare: Double = 0.25
    /// Shaken-off snow falls as clumps: bigger, and carrying more volume than their disc suggests,
    /// otherwise a full window would need thousands of flakes.
    public var clumpRadiusRange: ClosedRange<CGFloat> = 2.5...5
    public var clumpVolumeFactor: CGFloat = 4

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
    /// How fast impulses fade toward drift and fall speed, per second.
    static let velocityRelaxation: CGFloat = 3
    /// Window bounds changes below this count as jitter, not as a move.
    static let moveTolerance: CGFloat = 0.5

    public let config: SnowConfig
    /// Area flakes fall through, in CG coordinates.
    public var bounds: CGRect
    public private(set) var flakes: ContiguousArray<Flake>
    public private(set) var activeCount = 0
    /// Ground first, then window surfaces in front-to-back order.
    public private(set) var surfaces: ContiguousArray<Surface> = []

    private var freeSlots: ContiguousArray<Int>
    private var spawnAccumulator: Double = 0
    private var rng: SplitMix64
    private var windowBounds: [Int: CGRect] = [:]
    private var nextSurfaceID = 1
    private let regularFlakeLimit: Int

    public init(config: SnowConfig = SnowConfig(), bounds: CGRect, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        var config = config
        config.maxFlakes = min(max(config.maxFlakes, 0), Self.hardFlakeLimit)
        self.config = config
        self.bounds = bounds
        self.rng = SplitMix64(seed: seed)
        flakes = ContiguousArray(repeating: Flake(), count: config.maxFlakes)
        freeSlots = ContiguousArray((0..<config.maxFlakes).reversed())
        regularFlakeLimit = config.maxFlakes - Int(Double(config.maxFlakes) * config.reservedFlakeShare)
        if config.groundEnabled {
            surfaces.append(makeSurface(
                kind: .ground(screen: 0), minX: bounds.minX, baseY: bounds.maxY,
                width: bounds.width, maxHeight: config.groundMaxHeight, edges: .walls
            ))
        }
    }

    public static func flakeVolume(radius: CGFloat, config: SnowConfig) -> CGFloat {
        .pi * radius * radius * config.volumeScale
    }

    // MARK: - Frame step

    public mutating func step(dt rawDt: Double) {
        guard rawDt > 0 else { return }
        let dt = min(rawDt, Self.maxStep)

        spawnAccumulator += config.spawnRate * Double(bounds.width / 1000) * dt
        while spawnAccumulator >= 1 {
            spawnAccumulator -= 1
            spawnSnowfall()
        }

        let t = CGFloat(dt)
        let relax = min(Self.velocityRelaxation * t, 1)
        let margin: CGFloat = 40
        for i in flakes.indices where flakes[i].isActive {
            var flake = flakes[i]
            let previousY = flake.position.y
            flake.velocity.dx += (flake.driftX - flake.velocity.dx) * relax
            flake.velocity.dy += (flake.fallSpeed - flake.velocity.dy) * relax
            flake.swayPhase += Self.swayFrequency * t
            flake.position.x += (flake.velocity.dx + sin(flake.swayPhase) * flake.swayAmplitude) * t
            flake.position.y += flake.velocity.dy * t

            if land(flake, previousY: previousY)
                || flake.position.y - flake.radius > bounds.maxY
                || flake.position.x < bounds.minX - margin
                || flake.position.x > bounds.maxX + margin {
                flake.isActive = false
                freeSlots.append(i)
                activeCount -= 1
            }
            flakes[i] = flake
        }

        for i in surfaces.indices {
            let spilled = surfaces[i].relax()
            surfaces[i].spillCredit.left += spilled.left
            surfaces[i].spillCredit.right += spilled.right
            if surfaces[i].edges == .spill {
                releaseSpill(of: i, side: -1)
                releaseSpill(of: i, side: 1)
            }
        }
    }

    /// Deposits the flake if it reached the snow top of a surface below it this step.
    private mutating func land(_ flake: Flake, previousY: CGFloat) -> Bool {
        let x = flake.position.x
        for s in surfaces.indices {
            guard let column = surfaces[s].column(at: x) else { continue }
            // Was above the edge before, is at or below the snow top now. Also catches flakes that the
            // growing snow rose past since the last step.
            guard previousY <= surfaces[s].baseY, flake.position.y >= surfaces[s].topY(atColumn: column) else { continue }
            surfaces[s].deposit(volume: flake.snowVolume, minX: x - flake.radius, maxX: x + flake.radius)
            return true
        }
        return false
    }

    // MARK: - Windows

    /// Updates window surfaces from a front-to-back window list (CG coordinates).
    /// Snow on windows that moved, resized or disappeared falls off as flakes.
    public mutating func setWindows(_ windows: [WindowInfo]) {
        var newBounds: [Int: CGRect] = [:]
        for window in windows { newBounds[window.number] = window.bounds }

        var kept: [Int: Surface] = [:]
        for surface in surfaces {
            guard case .window(let number) = surface.kind else { continue }
            if let bounds = newBounds[number], let old = windowBounds[number], Self.isSame(bounds, old) {
                kept[number] = surface
            } else {
                shakeOff(surface)
            }
        }

        var updated = ContiguousArray(surfaces.filter { if case .ground = $0.kind { true } else { false } })
        var updatedBounds: [Int: CGRect] = [:]
        for window in windows {
            if let surface = kept[window.number] {
                updated.append(surface)
                // Keep the original bounds so slow drifts below the tolerance still add up to a move.
                updatedBounds[window.number] = windowBounds[window.number]
            } else {
                updatedBounds[window.number] = window.bounds
                if let surface = makeWindowSurface(window) { updated.append(surface) }
            }
        }
        surfaces = updated
        windowBounds = updatedBounds
    }

    private static func isSame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= moveTolerance && abs(a.minY - b.minY) <= moveTolerance
            && abs(a.width - b.width) <= moveTolerance && abs(a.height - b.height) <= moveTolerance
    }

    private mutating func makeWindowSurface(_ window: WindowInfo) -> Surface? {
        let top = window.bounds.minY
        guard top >= bounds.minY, top < bounds.maxY else { return nil }
        let minX = max(window.bounds.minX + config.windowCornerInset, bounds.minX)
        let maxX = min(window.bounds.maxX - config.windowCornerInset, bounds.maxX)
        guard maxX - minX >= 2 * Surface.columnWidth else { return nil }
        return makeSurface(
            kind: .window(number: window.number), minX: minX, baseY: top,
            width: maxX - minX, maxHeight: config.windowMaxHeight, edges: .spill
        )
    }

    private mutating func makeSurface(
        kind: Surface.Kind, minX: CGFloat, baseY: CGFloat, width: CGFloat, maxHeight: CGFloat, edges: Surface.Edges
    ) -> Surface {
        defer { nextSurfaceID += 1 }
        return Surface(kind: kind, minX: minX, baseY: baseY, width: width, maxHeight: maxHeight, edges: edges, id: nextSurfaceID)
    }

    /// Turns all snow of a surface into falling clumps with a small random impulse.
    private mutating func shakeOff(_ surface: Surface) {
        var credit: CGFloat = 0
        var target = clumpVolume(radius: randomClumpRadius())
        var lastColumn = 0
        for column in surface.heights.indices where surface.heights[column] > 0 {
            lastColumn = column
            credit += surface.heights[column] * Surface.columnWidth
            while credit >= target {
                guard spawnClump(from: surface, column: column, volume: target) else { return }
                credit -= target
                target = clumpVolume(radius: randomClumpRadius())
            }
        }
        if credit > 0 { spawnClump(from: surface, column: lastColumn, volume: credit) }
    }

    private func clumpVolume(radius: CGFloat) -> CGFloat {
        Self.flakeVolume(radius: radius, config: config) * config.clumpVolumeFactor
    }

    private mutating func randomClumpRadius() -> CGFloat {
        CGFloat.random(in: config.clumpRadiusRange, using: &rng)
    }

    @discardableResult
    private mutating func spawnClump(from surface: Surface, column: Int, volume: CGFloat) -> Bool {
        let height = surface.heights[column]
        let radius = max(sqrt(volume / (.pi * config.volumeScale * config.clumpVolumeFactor)), config.radiusRange.lowerBound)
        let x = surface.minX + (CGFloat(column) + 0.5) * Surface.columnWidth + CGFloat.random(in: -1...1, using: &rng)
        let y = surface.topY(atColumn: column) + CGFloat.random(in: 0...height, using: &rng)
        return spawn(
            at: CGPoint(x: x, y: y), radius: radius, snowVolume: volume,
            velocity: CGVector(dx: CGFloat.random(in: -25...25, using: &rng), dy: CGFloat.random(in: -15...25, using: &rng)),
            driftX: CGFloat.random(in: -4...4, using: &rng),
            swayAmplitude: CGFloat.random(in: 2...6, using: &rng), opacity: 1
        )
    }

    /// Turns snow that slid past a window edge into flakes falling outward.
    /// `side` is -1 for the left edge, 1 for the right edge.
    private mutating func releaseSpill(of index: Int, side: CGFloat) {
        let maxCredit = 10 * Self.flakeVolume(radius: config.radiusRange.upperBound, config: config)
        var credit = side < 0 ? surfaces[index].spillCredit.left : surfaces[index].spillCredit.right
        while credit > 0 {
            let radius = CGFloat.random(in: config.radiusRange, using: &rng)
            let volume = Self.flakeVolume(radius: radius, config: config)
            guard credit >= volume else { break }
            let surface = surfaces[index]
            let column = side < 0 ? 0 : surface.heights.count - 1
            let x = side < 0 ? surface.minX - radius - 2 : surface.maxX + radius + 2
            let spawned = spawn(
                at: CGPoint(x: x, y: surface.topY(atColumn: column)), radius: radius, snowVolume: volume,
                velocity: CGVector(dx: side * CGFloat.random(in: 8...15, using: &rng), dy: 10),
                driftX: side * CGFloat.random(in: 3...8, using: &rng),
                swayAmplitude: CGFloat.random(in: 1...2, using: &rng), opacity: 1
            )
            guard spawned else { break }
            credit -= volume
        }
        // When the pool is full, don't let unreleased snow pile up without bound.
        credit = min(credit, maxCredit)
        if side < 0 { surfaces[index].spillCredit.left = credit } else { surfaces[index].spillCredit.right = credit }
    }

    // MARK: - Spawning

    private mutating func spawnSnowfall() {
        guard activeCount < regularFlakeLimit else { return }
        let radius = CGFloat.random(in: config.radiusRange, using: &rng)
        let position = CGPoint(
            x: CGFloat.random(in: bounds.minX...bounds.maxX, using: &rng),
            y: bounds.minY - radius - CGFloat.random(in: 0...30, using: &rng)
        )
        let drift = CGFloat.random(in: -4...4, using: &rng)
        spawn(
            at: position, radius: radius, snowVolume: Self.flakeVolume(radius: radius, config: config),
            velocity: nil, driftX: drift,
            swayAmplitude: CGFloat.random(in: 6...18, using: &rng),
            opacity: CGFloat.random(in: 0.65...1.0, using: &rng)
        )
    }

    /// `velocity == nil` starts the flake at its drift and fall speed.
    @discardableResult
    private mutating func spawn(
        at position: CGPoint, radius: CGFloat, snowVolume: CGFloat, velocity: CGVector?,
        driftX: CGFloat, swayAmplitude: CGFloat, opacity: CGFloat
    ) -> Bool {
        guard let slot = freeSlots.popLast() else { return false }
        var flake = Flake()
        flake.radius = radius
        flake.position = position
        // Larger flakes fall faster; a bit of jitter keeps them from moving in lockstep.
        flake.fallSpeed = 28 + 16 * radius + CGFloat.random(in: -6...6, using: &rng)
        flake.driftX = driftX
        flake.velocity = velocity ?? CGVector(dx: driftX, dy: flake.fallSpeed)
        flake.swayPhase = CGFloat.random(in: 0...(2 * .pi), using: &rng)
        flake.swayAmplitude = swayAmplitude
        flake.opacity = opacity
        flake.snowVolume = snowVolume
        flake.isActive = true
        flakes[slot] = flake
        activeCount += 1
        return true
    }

    // MARK: - Reset and test hooks

    public mutating func reset() {
        for i in flakes.indices { flakes[i].isActive = false }
        freeSlots.removeAll(keepingCapacity: true)
        freeSlots.append(contentsOf: (0..<flakes.count).reversed())
        activeCount = 0
        spawnAccumulator = 0
        for i in surfaces.indices { surfaces[i].clear() }
    }

    mutating func modifySurface(_ kind: Surface.Kind, _ body: (inout Surface) -> Void) {
        guard let index = surfaces.firstIndex(where: { $0.kind == kind }) else { return }
        body(&surfaces[index])
    }
}
