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
    public var widgetCornerInset: CGFloat = 20
    /// Share of a flake's disc area that ends up as lying snow. Tuned so the ground fills in about five minutes.
    public var volumeScale: CGFloat = 0.25
    /// Extra pool slots for powder (snow falling off windows), on top of `maxFlakes`.
    /// Enough for a completely full window to turn into powder at once.
    public var powderCapacity = 2200
    public var powderRadiusRange: ClosedRange<CGFloat> = 1.0...2.0
    /// Volume each powder particle carries. Raised automatically when the pool would not suffice.
    public var powderVolume: CGFloat = 2.5
    /// Share of fallen-off snow that comes down as coarse clumps instead of powder.
    public var clumpShare: CGFloat = 0.65
    public var clumpVolumeRange: ClosedRange<CGFloat> = 14...50
    public var clumpRadiusRange: ClosedRange<CGFloat> = 2.2...6.5
    /// Horizontal window speed (pt/s) above which the snow can no longer keep up and starts sliding off.
    public var slipSpeed: CGFloat = 900
    /// Share of the movement beyond `slipSpeed` that the snow lags behind.
    public var slipFactor: CGFloat = 0.6

    /// Height (pt per second) that lying snow loses by melting. Faster after a while without new snow.
    public var meltRate: CGFloat = 0.01
    /// Scales the breeze and gusts; 0 is calm.
    public var windStrength: CGFloat = 1

    public var snowmenEnabled = true
    public var iciclesEnabled = true
    /// Mean snow height on a window that lets icicles grow.
    public var icicleSnowHeight: CGFloat = 3
    /// Seconds of lying snow before the first icicle appears.
    public var icicleDelay: Double = 25
    public var icicleSpawnInterval: ClosedRange<Double> = 6...16
    /// Growth in pt per second.
    public var icicleGrowth: CGFloat = 0.12
    /// Window speed (pt/s) that breaks icicles off.
    public var icicleBreakSpeed: CGFloat = 700
    public var plowEnabled = true
    /// Mean ground height (pt) that calls the plow.
    public var plowThreshold: CGFloat = 22
    /// Minimum seconds between two plow runs.
    public var plowInterval: Double = 240
    public var plowSpeed: CGFloat = 120

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

    public internal(set) var config: SnowConfig
    /// Area flakes fall through, in CG coordinates.
    public var bounds: CGRect
    /// Height of the menu bar at the top of the screen. Windows need some room below it to carry snow,
    /// otherwise their snow would lie inside the menu bar (a maximized window, for example).
    public var topInset: CGFloat = 0
    static let minHeadroom: CGFloat = 6
    public internal(set) var flakes: ContiguousArray<Flake>
    public internal(set) var activeCount = 0
    /// Active flakes of regular snowfall, limited to `config.maxFlakes`. Powder comes on top.
    public internal(set) var snowfallCount = 0
    /// Ground first, then window surfaces in front-to-back order.
    public internal(set) var surfaces: ContiguousArray<Surface> = []

    var freeSlots: ContiguousArray<Int>
    private var spawnAccumulator: Double = 0
    var rng: SplitMix64
    struct TrackedWindow {
        /// Bounds the surface was last laid out for. Jitter below `moveTolerance` doesn't update them,
        /// so slow drifts still add up to a move.
        var bounds: CGRect
        var timestamp: Double
        /// Sub-column part of the snow's offset that column-wise relocation couldn't apply yet.
        var columnResidual: CGFloat
        /// Smoothed velocity of the window's top-left corner (pt/s), zero while resizing or standing still.
        var velocity: CGVector = .zero
        var isWidget = false
    }

    /// Seconds of simulated time.
    public internal(set) var time: Double = 0
    public internal(set) var plow = Plow()
    public internal(set) var stacks: [SnowStack] = []
    public internal(set) var held: HeldBall?
    var nextStackID = 1

    /// Horizontal wind speed (pt/s) acting on all particles.
    public internal(set) var windX: CGFloat = 0

    var tracked: [Int: TrackedWindow] = [:]
    var icicleGroups: [Int: IcicleGroup] = [:]
    private var nextSurfaceID = 1

    /// `screenIndex` names the ground surface; each screen runs its own simulation.
    public init(config: SnowConfig = SnowConfig(), bounds: CGRect, screenIndex: Int = 0, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        var config = config
        config.maxFlakes = min(max(config.maxFlakes, 0), Self.hardFlakeLimit)
        config.powderCapacity = max(config.powderCapacity, 0)
        self.config = config
        self.bounds = bounds
        self.screenIndex = screenIndex
        self.rng = SplitMix64(seed: seed)
        let capacity = config.maxFlakes + config.powderCapacity
        flakes = ContiguousArray(repeating: Flake(), count: capacity)
        freeSlots = ContiguousArray((0..<capacity).reversed())
        if config.groundEnabled { addGround() }
    }

    public let screenIndex: Int

    private mutating func addGround() {
        surfaces.insert(makeSurface(
            kind: .ground(screen: screenIndex), minX: bounds.minX, baseY: bounds.maxY,
            width: bounds.width, maxHeight: config.groundMaxHeight, edges: .walls
        ), at: 0)
    }

    /// Applies changed settings. Grows the particle pool if needed (never shrinks it, so nothing in flight is lost),
    /// and adds or removes the ground. Removing the ground drops its snow and everything standing on it.
    public mutating func apply(_ newConfig: SnowConfig) {
        var newConfig = newConfig
        newConfig.maxFlakes = min(max(newConfig.maxFlakes, 0), Self.hardFlakeLimit)
        newConfig.powderCapacity = config.powderCapacity
        let needed = newConfig.maxFlakes + newConfig.powderCapacity
        if needed > flakes.count {
            let old = flakes.count
            flakes.append(contentsOf: repeatElement(Flake(), count: needed - old))
            freeSlots.insert(contentsOf: (old..<needed).reversed(), at: 0)
        }
        let hadGround = config.groundEnabled
        config = newConfig
        if newConfig.groundEnabled && !hadGround {
            addGround()
        } else if !newConfig.groundEnabled && hadGround {
            surfaces.removeAll { if case .ground = $0.kind { return true } else { return false } }
            stacks.removeAll { $0.support == .ground }
            plow = Plow()
        }
        if !newConfig.snowmenEnabled { held = nil }
    }

    public static func flakeVolume(radius: CGFloat, config: SnowConfig) -> CGFloat {
        .pi * radius * radius * config.volumeScale
    }

    // MARK: - Frame step

    public mutating func step(dt rawDt: Double) {
        guard rawDt > 0 else { return }
        let dt = min(rawDt, Self.maxStep)
        time += dt

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
            flake.velocity.dx += (flake.driftX + windX * windResponse(flake) - flake.velocity.dx) * relax
            flake.velocity.dy += (flake.fallSpeed - flake.velocity.dy) * relax
            flake.swayPhase += Self.swayFrequency * t
            flake.rotation += flake.spin * t
            flake.position.x += (flake.velocity.dx + sin(flake.swayPhase) * flake.swayAmplitude) * t
            flake.position.y += flake.velocity.dy * t

            var done = false
            if flake.kind == .puff {
                flake.life -= t
                done = flake.life <= 0
            } else if flake.velocity.dy > 0 {
                // Only falling particles land; thrown ones first fly up and away.
                done = land(flake, previousY: previousY)
            }
            if done
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

        stepPlow(dt: t)
        stepStacks(dt: t)
        stepIcicles(dt: t)

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
            guard let column = surfaces[s].column(at: x), !surfaces[s].isHidden(column) else { continue }
            // Was above the edge before, is at or below the snow top now. Also catches flakes that the
            // growing snow rose past since the last step.
            guard previousY <= surfaces[s].baseY, flake.position.y >= surfaces[s].topY(atColumn: column) else { continue }
            if flake.kind != .ice {
                depositSpreading(surface: s, volume: flake.snowVolume, x: x, radius: flake.radius)
            }
            if flake.kind == .clump {
                burst(at: CGPoint(x: x, y: surfaces[s].topY(atColumn: column)), radius: flake.radius)
            }
            return true
        }
        return false
    }

    /// Deposits `volume` around `x`. Where the columns are already full, the rest spreads wider, so snow isn't lost
    /// just because it landed on a full spot. Only a surface that is full everywhere nearby drops the remainder.
    mutating func depositSpreading(surface s: Int, volume: CGFloat, x: CGFloat, radius: CGFloat) {
        var remaining = volume - surfaces[s].deposit(volume: volume, minX: x - radius, maxX: x + radius)
        var reach = max(radius, Surface.columnWidth) * 2
        let fullWidth = surfaces[s].maxX - surfaces[s].minX
        var attempts = 0
        // Full columns reject their share, so repeat; widen when little fits.
        while remaining > 1e-9, attempts < 32 {
            attempts += 1
            let added = surfaces[s].deposit(volume: remaining, minX: x - reach, maxX: x + reach)
            remaining -= added
            if added < remaining {
                if reach >= fullWidth { if added <= 1e-12 { break } } else { reach *= 2 }
            }
        }
    }

    /// How strongly the wind pushes a particle: small, light ones more.
    @inline(__always)
    private func windResponse(_ flake: Flake) -> CGFloat {
        switch flake.kind {
        case .clump, .ice: return 0.25
        case .puff: return 0.6
        case .snow, .powder: return 1.4 - min(flake.radius, 4) * 0.15
        }
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

            if var previous, Self.isSame(window.bounds, previous.bounds) {
                previous.timestamp = timestamp
                previous.velocity = .zero
                newTracked[window.number] = previous
                if let surface { updated.append(surface) }
                continue
            }

            var residual: CGFloat = 0
            var velocity = CGVector.zero
            if let previous {
                velocity = Self.measureVelocity(from: previous, to: window.bounds, timestamp: timestamp)
            }
            let geometry = windowSurfaceGeometry(window.bounds, isWidget: window.isWidget)
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
            newTracked[window.number] = TrackedWindow(
                bounds: window.bounds, timestamp: timestamp, columnResidual: residual, velocity: velocity, isWidget: window.isWidget
            )
        }

        for surface in existing.values { powderize(surface) }
        surfaces = updated
        let previous = tracked
        tracked = newTracked
        updateOcclusion(windows)
        updateIcicles(previous: previous, windows: windows)
    }

    /// Hides the columns of each window edge that a window further in front covers.
    private mutating func updateOcclusion(_ windows: [WindowInfo]) {
        var order: [Int: Int] = [:]
        for (i, window) in windows.enumerated() { order[window.number] = i }
        for s in surfaces.indices {
            guard case .window(let number) = surfaces[s].kind, let index = order[number] else { continue }
            let occluders = windows[..<index].map(\.bounds)
            let surface = surfaces[s]
            let visible = Occlusion.visibleSegments(minX: surface.minX, maxX: surface.maxX, y: surface.baseY, occluders: occluders)
            surfaces[s].setVisible(visible)
        }
    }

    /// Velocity of a window's top-left corner and when it was measured, so the renderer can predict where the
    /// window is by the time a frame shows. Nil for windows that aren't tracked.
    public func motion(ofWindow number: Int) -> (velocity: CGVector, timestamp: Double)? {
        tracked[number].map { ($0.velocity, $0.timestamp) }
    }

    private static func measureVelocity(from previous: TrackedWindow, to bounds: CGRect, timestamp: Double) -> CGVector {
        let resized = abs(bounds.width - previous.bounds.width) > moveTolerance
            || abs(bounds.height - previous.bounds.height) > moveTolerance
        guard !resized else { return .zero }
        let dt = CGFloat(max(timestamp - previous.timestamp, 1.0 / 240))
        let measured = CGVector(dx: (bounds.minX - previous.bounds.minX) / dt, dy: (bounds.minY - previous.bounds.minY) / dt)
        // Polls aren't aligned to the window server's frames, so single measurements jump; average with the last one.
        guard previous.velocity != .zero else { return measured }
        return CGVector(dx: (previous.velocity.dx + measured.dx) / 2, dy: (previous.velocity.dy + measured.dy) / 2)
    }

    private static func isSame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= moveTolerance && abs(a.minY - b.minY) <= moveTolerance
            && abs(a.width - b.width) <= moveTolerance && abs(a.height - b.height) <= moveTolerance
    }

    /// Top edge of a window, inset from its rounded corners and clipped to the screen. Nil if not on screen.
    private func windowSurfaceGeometry(_ window: CGRect, isWidget: Bool = false) -> (minX: CGFloat, baseY: CGFloat, width: CGFloat)? {
        let top = window.minY
        guard top >= bounds.minY + topInset + Self.minHeadroom, top < bounds.maxY else { return nil }
        // Widgets have much rounder corners than windows.
        let inset = isWidget ? config.widgetCornerInset : config.windowCornerInset
        let minX = max(window.minX + inset, bounds.minX)
        let maxX = min(window.maxX - inset, bounds.maxX)
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
            spawnDebris(volume: lost.left, x: (geometry.minX - 4)...geometry.minX, y: y, inheritedVX: velocityX, outward: -1)
        }
        if lost.right > 0 {
            let maxX = surface.maxX
            spawnDebris(volume: lost.right, x: maxX...(maxX + 4), y: y, inheritedVX: velocityX, outward: 1)
        }
        return exact - CGFloat(offset)
    }

    private mutating func makeSurface(
        kind: Surface.Kind, minX: CGFloat, baseY: CGFloat, width: CGFloat, maxHeight: CGFloat, edges: Surface.Edges
    ) -> Surface {
        defer { nextSurfaceID += 1 }
        return Surface(kind: kind, minX: minX, baseY: baseY, width: width, maxHeight: maxHeight, edges: edges, id: nextSurfaceID)
    }

    // MARK: - Falling snow (clumps and powder)

    /// Factor applied to every debris particle's volume so that `volume` fits into the free slots.
    private func debrisScale(for volume: CGFloat) -> CGFloat {
        let meanClump = (config.clumpVolumeRange.lowerBound + config.clumpVolumeRange.upperBound) / 2
        let estimate = volume * (config.clumpShare / meanClump + (1 - config.clumpShare) / config.powderVolume)
        return max(1, estimate / CGFloat(max(freeSlots.count, 1)))
    }

    /// Picks the volume of the next debris particle and whether it is a clump.
    private mutating func nextDebris(remaining: CGFloat, scale: CGFloat) -> (volume: CGFloat, clump: Bool) {
        let clump = CGFloat.random(in: 0..<1, using: &rng) < config.clumpShare
        let base = clump ? CGFloat.random(in: config.clumpVolumeRange, using: &rng) : config.powderVolume
        return (min(base * scale, remaining), clump)
    }

    /// Turns all snow of a surface into clumps and powder, shaped like the layer it came from.
    mutating func powderize(_ surface: Surface) {
        let scale = debrisScale(for: surface.totalVolume)
        var credit: CGFloat = 0
        var lastColumn = 0
        var next = nextDebris(remaining: .infinity, scale: scale)
        // Snow behind a window in front falls down behind it, out of sight.
        for column in surface.heights.indices where surface.heights[column] > 0 && !surface.isHidden(column) {
            lastColumn = column
            credit += surface.heights[column] * Surface.columnWidth
            while credit >= next.volume {
                guard spawnDebrisParticle(from: surface, column: column, volume: next.volume, clump: next.clump) else { return }
                credit -= next.volume
                next = nextDebris(remaining: .infinity, scale: scale)
            }
        }
        if credit > 1e-9 {
            spawnDebrisParticle(from: surface, column: lastColumn, volume: credit, clump: credit >= config.clumpVolumeRange.lowerBound)
        }
    }

    @discardableResult
    private mutating func spawnDebrisParticle(from surface: Surface, column: Int, volume: CGFloat, clump: Bool) -> Bool {
        let height = surface.heights[column]
        let x = surface.minX + (CGFloat(column) + 0.5) * Surface.columnWidth + CGFloat.random(in: -1...1, using: &rng)
        let y = surface.topY(atColumn: column) + CGFloat.random(in: 0...height, using: &rng)
        return spawnDebris(at: CGPoint(x: x, y: y), volume: volume, clump: clump, inheritedVX: 0, outward: 0)
    }

    /// Spawns clumps and powder carrying exactly `volume` (as long as the pool has room), spread over the given area.
    mutating func spawnDebris(
        volume: CGFloat, x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>, inheritedVX: CGFloat, outward: CGFloat
    ) {
        let scale = debrisScale(for: volume)
        var remaining = volume
        while remaining > 1e-9 {
            let next = nextDebris(remaining: remaining, scale: scale)
            let position = CGPoint(x: CGFloat.random(in: x, using: &rng), y: CGFloat.random(in: y, using: &rng))
            let clump = next.clump && next.volume >= config.clumpVolumeRange.lowerBound * 0.5
            guard spawnDebris(at: position, volume: next.volume, clump: clump, inheritedVX: inheritedVX, outward: outward) else { return }
            remaining -= next.volume
        }
    }

    /// `outward` is -1 or 1 for snow sliding off an edge, 0 for a whole layer dropping.
    @discardableResult
    mutating func spawnDebris(at position: CGPoint, volume: CGFloat, clump: Bool, inheritedVX: CGFloat, outward: CGFloat) -> Bool {
        let velocity = CGVector(
            dx: inheritedVX * 0.15 + outward * CGFloat.random(in: 5...15, using: &rng) + CGFloat.random(in: -8...8, using: &rng),
            dy: CGFloat.random(in: -6...6, using: &rng)
        )
        if clump {
            let natural = (volume / .pi).squareRoot() * 0.95
            let radius = min(max(natural, config.clumpRadiusRange.lowerBound), config.clumpRadiusRange.upperBound)
            return spawn(
                kind: .clump, at: position, radius: radius, snowVolume: volume, velocity: velocity,
                driftX: outward * 2 + CGFloat.random(in: -2...2, using: &rng),
                swayAmplitude: CGFloat.random(in: 0.5...2.5, using: &rng),
                opacity: 1
            )
        }
        return spawn(
            kind: .powder, at: position, radius: CGFloat.random(in: config.powderRadiusRange, using: &rng),
            snowVolume: volume, velocity: velocity,
            driftX: outward * 2 + CGFloat.random(in: -3...3, using: &rng),
            // Powder is light: it sways more and falls slower than regular flakes of its size.
            swayAmplitude: outward == 0 ? CGFloat.random(in: 6...16, using: &rng) : CGFloat.random(in: 2...5, using: &rng),
            opacity: CGFloat.random(in: 0.75...1.0, using: &rng)
        )
    }

    /// A landing clump bursts into a little cloud of dust. The dust carries no volume; the clump already deposited it.
    private mutating func burst(at point: CGPoint, radius: CGFloat) {
        let count = 2 + Int(radius)
        for _ in 0..<count {
            let position = CGPoint(x: point.x + CGFloat.random(in: -radius...radius, using: &rng), y: point.y - 1)
            let velocity = CGVector(dx: CGFloat.random(in: -35...35, using: &rng), dy: CGFloat.random(in: -45 ... -12, using: &rng))
            guard spawn(
                kind: .puff, at: position, radius: CGFloat.random(in: 0.7...1.5, using: &rng), snowVolume: 0,
                velocity: velocity, driftX: 0, swayAmplitude: 0, opacity: CGFloat.random(in: 0.6...0.95, using: &rng),
                life: CGFloat.random(in: 0.25...0.6, using: &rng)
            ) else { return }
        }
    }

    /// Turns snow that slid past a window edge into powder (and the odd clump) falling outward.
    /// `side` is -1 for the left edge, 1 for the right edge.
    private mutating func releaseSpill(of index: Int, side: CGFloat) {
        var credit = side < 0 ? surfaces[index].spillCredit.left : surfaces[index].spillCredit.right
        // An end hidden behind a window in front spills out of sight.
        if surfaces[index].isHidden(side < 0 ? 0 : surfaces[index].heights.count - 1) { credit = 0 }
        while credit >= config.powderVolume {
            let surface = surfaces[index]
            let column = side < 0 ? 0 : surface.heights.count - 1
            let x = side < 0 ? surface.minX - config.powderRadiusRange.upperBound - 2 : surface.maxX + config.powderRadiusRange.upperBound + 2
            let clump = credit >= config.clumpVolumeRange.lowerBound && CGFloat.random(in: 0..<1, using: &rng) < 0.3
            let volume = clump ? config.clumpVolumeRange.lowerBound : config.powderVolume
            guard spawnDebris(at: CGPoint(x: x, y: surface.topY(atColumn: column)), volume: volume, clump: clump,
                              inheritedVX: 0, outward: side) else { break }
            credit -= volume
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
            kind: .snow, at: position, radius: radius, snowVolume: Self.flakeVolume(radius: radius, config: config),
            velocity: nil, driftX: drift,
            swayAmplitude: CGFloat.random(in: 6...18, using: &rng),
            opacity: CGFloat.random(in: 0.65...1.0, using: &rng)
        )
    }

    /// `velocity == nil` starts the particle at its drift and fall speed.
    @discardableResult
    mutating func spawn(
        kind: Flake.Kind, at position: CGPoint, radius: CGFloat, snowVolume: CGFloat, velocity: CGVector?,
        driftX: CGFloat, swayAmplitude: CGFloat, opacity: CGFloat, life: CGFloat = 0, length: CGFloat = 0
    ) -> Bool {
        guard kind == .snow || freeSlots.count > 0 else { return false }
        guard let slot = freeSlots.popLast() else { return false }
        var flake = Flake()
        flake.kind = kind
        flake.radius = radius
        flake.position = position
        switch kind {
        case .clump:
            // Heavy: starts slow and accelerates toward a high terminal speed, like a dropping lump.
            flake.fallSpeed = 180 + 30 * radius + CGFloat.random(in: -80...120, using: &rng)
            flake.spin = CGFloat.random(in: -2.5...2.5, using: &rng)
        case .powder:
            flake.fallSpeed = 30 + 14 * radius + CGFloat.random(in: -6...6, using: &rng)
        case .ice:
            flake.fallSpeed = 260 + CGFloat.random(in: -30...30, using: &rng)
            flake.spin = CGFloat.random(in: -3...3, using: &rng)
        case .snow, .puff:
            // Larger flakes fall faster; a bit of jitter keeps them from moving in lockstep.
            flake.fallSpeed = 28 + 16 * radius + CGFloat.random(in: -6...6, using: &rng)
        }
        if kind == .puff { flake.fallSpeed = 25 }
        flake.driftX = driftX
        flake.velocity = velocity ?? CGVector(dx: driftX, dy: flake.fallSpeed)
        flake.swayPhase = CGFloat.random(in: 0...(2 * .pi), using: &rng)
        flake.swayAmplitude = swayAmplitude
        flake.opacity = opacity
        flake.snowVolume = snowVolume
        flake.rotation = CGFloat.random(in: 0...(2 * .pi), using: &rng)
        flake.seed = CGFloat.random(in: 0..<1, using: &rng)
        flake.life = life
        flake.length = length
        flake.isActive = true
        flakes[slot] = flake
        activeCount += 1
        if !flake.isPowder { snowfallCount += 1 }
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
        stacks.removeAll()
        held = nil
        icicleGroups.removeAll()
    }

    /// Fills the ground with an irregular layer around `height`, for scenarios that start with deep snow.
    public mutating func fillGround(height: CGFloat) {
        guard let g = surfaces.firstIndex(where: { if case .ground = $0.kind { return true } else { return false } }) else { return }
        let surface = surfaces[g]
        for c in surface.heights.indices {
            let x = surface.minX + CGFloat(c) * Surface.columnWidth
            let h = height * (1 + 0.15 * Noise.fractal(x / 80, seed: 5))
            surfaces[g].deposit(volume: h * Surface.columnWidth, minX: x, maxX: x + Surface.columnWidth)
        }
    }

    /// Puts an even layer of snow on a window, for scenarios.
    public mutating func fillWindow(_ number: Int, height: CGFloat) {
        modifySurface(.window(number: number)) { $0.deposit(volume: CGFloat($0.heights.count) * Surface.columnWidth * height, minX: $0.minX, maxX: $0.maxX) }
    }

    mutating func addTestFlake(at position: CGPoint, volume: CGFloat) {
        spawn(kind: .snow, at: position, radius: 2, snowVolume: volume, velocity: nil, driftX: 0, swayAmplitude: 0, opacity: 1)
    }

    mutating func modifySurface(_ kind: Surface.Kind, _ body: (inout Surface) -> Void) {
        guard let index = surfaces.firstIndex(where: { $0.kind == kind }) else { return }
        body(&surfaces[index])
    }
}
