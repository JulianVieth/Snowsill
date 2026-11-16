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
    /// Extra pool slots for powder (snow falling off windows), on top of `maxFlakes`.
    /// Enough for a completely full window to turn into powder at once.
    public var powderCapacity = 1200
    public var powderRadiusRange: ClosedRange<CGFloat> = 0.6...1.3
    /// Volume each powder particle carries. Raised automatically when the pool would not suffice.
    public var powderVolume: CGFloat = 5
    /// Horizontal window speed (pt/s) above which the snow can no longer keep up and starts sliding off.
    public var slipSpeed: CGFloat = 900
    /// Share of the movement beyond `slipSpeed` that the snow lags behind.
    public var slipFactor: CGFloat = 0.6

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
    /// Active flakes of regular snowfall, limited to `config.maxFlakes`. Powder comes on top.
    public private(set) var snowfallCount = 0
    /// Ground first, then window surfaces in front-to-back order.
    public private(set) var surfaces: ContiguousArray<Surface> = []

    private var freeSlots: ContiguousArray<Int>
    private var spawnAccumulator: Double = 0
    private var rng: SplitMix64
    private struct TrackedWindow {
        /// Bounds the surface was last laid out for. Jitter below `moveTolerance` doesn't update them,
        /// so slow drifts still add up to a move.
        var bounds: CGRect
        var timestamp: Double
        /// Sub-column part of the snow's offset that column-wise relocation couldn't apply yet.
        var columnResidual: CGFloat
    }

    private var tracked: [Int: TrackedWindow] = [:]
    private var nextSurfaceID = 1

    public init(config: SnowConfig = SnowConfig(), bounds: CGRect, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        var config = config
        config.maxFlakes = min(max(config.maxFlakes, 0), Self.hardFlakeLimit)
        self.config = config
        self.bounds = bounds
        self.rng = SplitMix64(seed: seed)
        config.powderCapacity = max(config.powderCapacity, 0)
        let capacity = config.maxFlakes + config.powderCapacity
        flakes = ContiguousArray(repeating: Flake(), count: capacity)
        freeSlots = ContiguousArray((0..<capacity).reversed())
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
                if !flake.isPowder { snowfallCount -= 1 }
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

    /// Updates window surfaces from a front-to-back window list (CG coordinates) captured at `timestamp` (seconds).
    /// Snow moves along with its window. It only falls off, as powder, where it slides past an edge: when the
    /// window is dragged sideways fast, shrunk, pushed past the screen edge, or closed.
    public mutating func setWindows(_ windows: [WindowInfo], timestamp: Double) {
        var existing: [Int: Surface] = [:]
        var updated = ContiguousArray<Surface>()
        for surface in surfaces {
            if case .window(let number) = surface.kind { existing[number] = surface } else { updated.append(surface) }
        }

        var newTracked: [Int: TrackedWindow] = [:]
        for window in windows {
            let previous = tracked[window.number]
            let surface = existing.removeValue(forKey: window.number)

            if let previous, Self.isSame(window.bounds, previous.bounds) {
                newTracked[window.number] = previous
                if let surface { updated.append(surface) }
                continue
            }

            var residual: CGFloat = 0
            let geometry = windowSurfaceGeometry(window.bounds)
            if var surface, let previous, let geometry {
                residual = relocate(&surface, from: previous, to: window.bounds, geometry: geometry, timestamp: timestamp)
                updated.append(surface)
            } else {
                if let surface { powderize(surface) }
                if let geometry {
                    updated.append(makeSurface(
                        kind: .window(number: window.number), minX: geometry.minX, baseY: geometry.baseY,
                        width: geometry.width, maxHeight: config.windowMaxHeight, edges: .spill
                    ))
                }
            }
            newTracked[window.number] = TrackedWindow(bounds: window.bounds, timestamp: timestamp, columnResidual: residual)
        }

        for surface in existing.values { powderize(surface) }
        surfaces = updated
        tracked = newTracked
    }

    private static func isSame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= moveTolerance && abs(a.minY - b.minY) <= moveTolerance
            && abs(a.width - b.width) <= moveTolerance && abs(a.height - b.height) <= moveTolerance
    }

    /// Top edge of a window, inset from its rounded corners and clipped to the screen. Nil if not on screen.
    private func windowSurfaceGeometry(_ window: CGRect) -> (minX: CGFloat, baseY: CGFloat, width: CGFloat)? {
        let top = window.minY
        guard top >= bounds.minY, top < bounds.maxY else { return nil }
        let minX = max(window.minX + config.windowCornerInset, bounds.minX)
        let maxX = min(window.maxX - config.windowCornerInset, bounds.maxX)
        guard maxX - minX >= 2 * Surface.columnWidth else { return nil }
        return (minX, top, maxX - minX)
    }

    /// Moves the surface with its window and lets whatever no longer fits fall off as powder.
    /// Returns the new sub-column residual.
    private mutating func relocate(
        _ surface: inout Surface, from previous: TrackedWindow, to window: CGRect,
        geometry: (minX: CGFloat, baseY: CGFloat, width: CGFloat), timestamp: Double
    ) -> CGFloat {
        let dMinX = window.minX - previous.bounds.minX
        let dMaxX = window.maxX - previous.bounds.maxX
        let resized = abs(window.width - previous.bounds.width) > Self.moveTolerance

        // Moving carries the snow along. Dragging an edge keeps it where it lies, so it doesn't slide along the edge.
        var shift = resized && abs(dMaxX) <= Self.moveTolerance ? 0 : dMinX
        if resized && abs(dMinX) <= Self.moveTolerance { shift = 0 }

        let dt = max(timestamp - previous.timestamp, 1.0 / 240)
        let velocityX = resized ? 0 : dMinX / CGFloat(dt)
        let speed = abs(velocityX)
        if speed > config.slipSpeed {
            // Inertia: beyond the slip speed the snow lags behind and slides toward the trailing edge.
            let slip = abs(dMinX) * (speed - config.slipSpeed) / speed * config.slipFactor
            shift -= velocityX > 0 ? slip : -slip
        }

        let exact = (geometry.minX - surface.minX - shift) / Surface.columnWidth + previous.columnResidual
        let offset = Int(exact.rounded())
        let lost = surface.relocate(minX: geometry.minX, baseY: geometry.baseY, width: geometry.width, columnOffset: offset)

        let depth = config.windowMaxHeight * 0.6
        let y = (geometry.baseY - depth)...geometry.baseY
        if lost.left > 0 {
            spawnPowder(volume: lost.left, x: (geometry.minX - 4)...geometry.minX, y: y, inheritedVX: velocityX, outward: -1)
        }
        if lost.right > 0 {
            let maxX = surface.maxX
            spawnPowder(volume: lost.right, x: maxX...(maxX + 4), y: y, inheritedVX: velocityX, outward: 1)
        }
        return exact - CGFloat(offset)
    }

    private mutating func makeSurface(
        kind: Surface.Kind, minX: CGFloat, baseY: CGFloat, width: CGFloat, maxHeight: CGFloat, edges: Surface.Edges
    ) -> Surface {
        defer { nextSurfaceID += 1 }
        return Surface(kind: kind, minX: minX, baseY: baseY, width: width, maxHeight: maxHeight, edges: edges, id: nextSurfaceID)
    }

    // MARK: - Powder

    /// Volume per particle so that `volume` fits into the free slots.
    private func powderParticleVolume(for volume: CGFloat) -> CGFloat {
        max(config.powderVolume, volume / CGFloat(max(freeSlots.count, 1)))
    }

    /// Turns all snow of a surface into powder, shaped like the layer it came from.
    private mutating func powderize(_ surface: Surface) {
        let perParticle = powderParticleVolume(for: surface.totalVolume)
        var credit: CGFloat = 0
        var lastColumn = 0
        for column in surface.heights.indices where surface.heights[column] > 0 {
            lastColumn = column
            credit += surface.heights[column] * Surface.columnWidth
            while credit >= perParticle {
                guard spawnPowderParticle(from: surface, column: column, volume: perParticle) else { return }
                credit -= perParticle
            }
        }
        if credit > 1e-9 { spawnPowderParticle(from: surface, column: lastColumn, volume: credit) }
    }

    @discardableResult
    private mutating func spawnPowderParticle(from surface: Surface, column: Int, volume: CGFloat) -> Bool {
        let height = surface.heights[column]
        let x = surface.minX + (CGFloat(column) + 0.5) * Surface.columnWidth + CGFloat.random(in: -1...1, using: &rng)
        let y = surface.topY(atColumn: column) + CGFloat.random(in: 0...height, using: &rng)
        return spawnPowder(at: CGPoint(x: x, y: y), volume: volume, inheritedVX: 0, outward: 0)
    }

    /// Spawns powder carrying exactly `volume` (as long as the pool has room), spread over the given area.
    private mutating func spawnPowder(
        volume: CGFloat, x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>, inheritedVX: CGFloat, outward: CGFloat
    ) {
        let perParticle = powderParticleVolume(for: volume)
        var remaining = volume
        while remaining > 1e-9 {
            let particle = min(perParticle, remaining)
            let position = CGPoint(x: CGFloat.random(in: x, using: &rng), y: CGFloat.random(in: y, using: &rng))
            guard spawnPowder(at: position, volume: particle, inheritedVX: inheritedVX, outward: outward) else { return }
            remaining -= particle
        }
    }

    /// `outward` is -1 or 1 for powder sliding off an edge, 0 for powder from a whole layer.
    @discardableResult
    private mutating func spawnPowder(at position: CGPoint, volume: CGFloat, inheritedVX: CGFloat, outward: CGFloat) -> Bool {
        let radius = CGFloat.random(in: config.powderRadiusRange, using: &rng)
        let velocity = CGVector(
            dx: inheritedVX * 0.15 + outward * CGFloat.random(in: 5...15, using: &rng) + CGFloat.random(in: -8...8, using: &rng),
            dy: CGFloat.random(in: -6...6, using: &rng)
        )
        return spawn(
            at: position, radius: radius, snowVolume: volume, velocity: velocity,
            driftX: outward * 2 + CGFloat.random(in: -3...3, using: &rng),
            swayAmplitude: outward == 0 ? CGFloat.random(in: 4...12, using: &rng) : CGFloat.random(in: 1...2, using: &rng),
            opacity: CGFloat.random(in: 0.35...0.8, using: &rng),
            isPowder: true
        )
    }

    /// Turns snow that slid past a window edge into powder falling outward.
    /// `side` is -1 for the left edge, 1 for the right edge.
    private mutating func releaseSpill(of index: Int, side: CGFloat) {
        var credit = side < 0 ? surfaces[index].spillCredit.left : surfaces[index].spillCredit.right
        while credit >= config.powderVolume {
            let surface = surfaces[index]
            let column = side < 0 ? 0 : surface.heights.count - 1
            let x = side < 0 ? surface.minX - config.powderRadiusRange.upperBound - 2 : surface.maxX + config.powderRadiusRange.upperBound + 2
            guard spawnPowder(at: CGPoint(x: x, y: surface.topY(atColumn: column)), volume: config.powderVolume,
                              inheritedVX: 0, outward: side) else { break }
            credit -= config.powderVolume
        }
        // When the pool is full, don't let unreleased snow pile up without bound.
        credit = min(credit, 10 * config.powderVolume)
        if side < 0 { surfaces[index].spillCredit.left = credit } else { surfaces[index].spillCredit.right = credit }
    }

    // MARK: - Spawning

    private mutating func spawnSnowfall() {
        guard snowfallCount < config.maxFlakes else { return }
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
            opacity: CGFloat.random(in: 0.65...1.0, using: &rng),
            isPowder: false
        )
    }

    /// `velocity == nil` starts the flake at its drift and fall speed.
    @discardableResult
    private mutating func spawn(
        at position: CGPoint, radius: CGFloat, snowVolume: CGFloat, velocity: CGVector?,
        driftX: CGFloat, swayAmplitude: CGFloat, opacity: CGFloat, isPowder: Bool
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
        flake.isPowder = isPowder
        flake.isActive = true
        flakes[slot] = flake
        activeCount += 1
        if !isPowder { snowfallCount += 1 }
        return true
    }

    // MARK: - Reset and test hooks

    public mutating func reset() {
        for i in flakes.indices { flakes[i].isActive = false }
        freeSlots.removeAll(keepingCapacity: true)
        freeSlots.append(contentsOf: (0..<flakes.count).reversed())
        activeCount = 0
        snowfallCount = 0
        spawnAccumulator = 0
        for i in surfaces.indices { surfaces[i].clear() }
    }

    mutating func modifySurface(_ kind: Surface.Kind, _ body: (inout Surface) -> Void) {
        guard let index = surfaces.firstIndex(where: { $0.kind == kind }) else { return }
        body(&surfaces[index])
    }
}
