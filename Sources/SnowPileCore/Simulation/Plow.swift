import CoreGraphics

/// A little snow plow that crosses the screen bottom now and then, so the ground layer doesn't turn into a
/// uniform block. The snow in front of the blade is collected into a wall (volume taken from the columns),
/// a thin, irregular layer stays behind. At the screen edge the wall is pushed out and thrown off as clumps.
public struct Plow: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Scraping with the blade down.
        case plowing
        /// Blade up, heading back out after stopping in front of something built.
        case leaving
    }

    public static let length: CGFloat = 78
    public static let bladeHeight: CGFloat = 18

    public internal(set) var phase: Phase = .idle
    /// Front edge of the blade (CG x).
    public internal(set) var x: CGFloat = 0
    /// +1 drives right, -1 drives left.
    public internal(set) var direction: CGFloat = 1
    /// Snow collected in front of the blade (pt²).
    public internal(set) var wallVolume: CGFloat = 0
    /// Simulation time of the last finished run.
    public internal(set) var lastRun: Double = 0
    var run = 0

    public init() {}

    public var isActive: Bool { phase != .idle }

    /// Half-ellipse mound in front of the blade that holds `wallVolume`: (height, half width).
    public var wallShape: (height: CGFloat, halfWidth: CGFloat) {
        guard wallVolume > 0 else { return (0, 0) }
        // Area of a half ellipse: pi * a * b / 2, with a = 1.6 b until the height hits its cap.
        let maxHeight: CGFloat = 30
        let height = min((2 * wallVolume / (.pi * 1.6)).squareRoot(), maxHeight)
        let halfWidth = 2 * wallVolume / (.pi * height)
        return (height, halfWidth)
    }

    /// Height of the thin layer the blade leaves behind at absolute `x`.
    public func residual(at x: CGFloat) -> CGFloat {
        1.2 + 1.4 * (Noise.fractal(x / 7, seed: 300 + run) + 1) / 2
    }
}

extension SnowSimulation {
    /// The widest the wall may get before snow tumbles over its top.
    static let maxWallVolume: CGFloat = 3200

    mutating func stepPlow(dt: CGFloat) {
        guard let g = groundIndex else {
            plow.phase = .idle
            return
        }
        if plow.phase == .idle {
            guard config.plowEnabled,
                  time - plow.lastRun >= config.plowInterval,
                  surfaces[g].meanHeight >= config.plowThreshold
            else { return }
            plow.run += 1
            // Alternate sides so both get cleared.
            plow.direction = plow.run % 2 == 1 ? 1 : -1
            plow.x = plow.direction > 0 ? bounds.minX - 4 : bounds.maxX + 4
            plow.wallVolume = 0
            plow.phase = .plowing
        }

        let step = config.plowSpeed * dt * plow.direction
        var target = plow.x + step

        if plow.phase == .plowing {
            // Stop in front of anything built on the ground.
            var blocked = false
            for obstacle in groundObstacles() {
                let margin: CGFloat = 4
                if plow.direction > 0, obstacle.lowerBound - margin >= plow.x, target > obstacle.lowerBound - margin {
                    target = obstacle.lowerBound - margin
                    blocked = true
                } else if plow.direction < 0, obstacle.upperBound + margin <= plow.x, target < obstacle.upperBound + margin {
                    target = obstacle.upperBound + margin
                    blocked = true
                }
            }

            scrape(ground: g, from: plow.x, to: target)
            plow.x = target
            // The blade holds back the snow in front of it.
            let column = Int(((plow.x - surfaces[g].minX) / Surface.columnWidth).rounded())
            surfaces[g].barrier = (0...surfaces[g].heights.count).contains(column) ? column : nil
            spillWallIfTooBig(ground: g)

            if blocked {
                surfaces[g].barrier = nil
                dumpWall(ground: g)
                plow.phase = .leaving
                plow.direction = -plow.direction
            } else if plow.direction > 0 ? plow.x >= bounds.maxX - 6 : plow.x <= bounds.minX + 6 {
                throwWallOffScreen()
            }
        } else {
            surfaces[g].barrier = nil
            plow.x = target
        }

        // Done once the whole vehicle has left the screen.
        let rear = plow.x - plow.direction * Plow.length
        if plow.direction > 0 ? rear > bounds.maxX + 8 : rear < bounds.minX - 8 {
            if plow.phase == .plowing { throwWallOffScreen() }
            surfaces[g].barrier = nil
            plow.phase = .idle
            plow.lastRun = time
        }
    }

    func groundTop(at x: CGFloat) -> CGFloat? {
        guard let g = groundIndex, let c = surfaces[g].column(at: min(max(x, surfaces[g].minX), surfaces[g].maxX - 0.01)) else { return nil }
        return surfaces[g].topY(atColumn: c)
    }

    var groundIndex: Int? {
        surfaces.firstIndex { if case .ground = $0.kind { return true } else { return false } }
    }

    private mutating func scrape(ground g: Int, from a: CGFloat, to b: CGFloat) {
        let lower = min(a, b), upper = max(a, b)
        guard upper > lower else { return }
        let surface = surfaces[g]
        let first = max(Int(((lower - surface.minX) / Surface.columnWidth).rounded(.down)), 0)
        let last = min(Int(((upper - surface.minX) / Surface.columnWidth).rounded(.up)), surface.heights.count - 1)
        guard first <= last else { return }
        for c in first...last {
            let x = surface.minX + (CGFloat(c) + 0.5) * Surface.columnWidth
            plow.wallVolume += surfaces[g].scrape(column: c, to: plow.residual(at: x))
        }
    }

    /// A wall that gets too big pushes the excess ahead of itself onto the ground, where the blade meets it again.
    private mutating func spillWallIfTooBig(ground g: Int) {
        let excess = plow.wallVolume - Self.maxWallVolume
        guard excess > 0 else { return }
        let front = plow.x + plow.direction * plow.wallShape.halfWidth * 2
        let far = front + plow.direction * 40
        let added = surfaces[g].deposit(volume: excess, minX: min(front, far), maxX: max(front, far))
        plow.wallVolume -= added
    }

    /// Pushes the wall over the screen edge: it is thrown off as clumps that leave the screen.
    private mutating func throwWallOffScreen() {
        let edgeX = plow.direction > 0 ? bounds.maxX : bounds.minX
        var budget = 60
        while plow.wallVolume > 1e-6, budget > 0 {
            budget -= 1
            let volume = min(CGFloat.random(in: config.clumpVolumeRange, using: &rng) * 2, plow.wallVolume)
            let x = edgeX - plow.direction * CGFloat.random(in: 0...20, using: &rng)
            let top = groundTop(at: x) ?? bounds.maxY
            let position = CGPoint(x: x, y: top - CGFloat.random(in: 4...16, using: &rng))
            let velocity = CGVector(dx: plow.direction * CGFloat.random(in: 160...320, using: &rng),
                                    dy: CGFloat.random(in: -160 ... -60, using: &rng))
            // Keeps flying outward so it really leaves the screen.
            guard spawnThrownClump(at: position, volume: volume, velocity: velocity, driftX: plow.direction * 140) else { break }
            plow.wallVolume -= volume
        }
        // Whatever didn't fit into the pool is pushed out of sight as well.
        plow.wallVolume = 0
    }

    /// Leaves the wall as a heap right where the plow stopped.
    private mutating func dumpWall(ground g: Int) {
        let shape = plow.wallShape
        let width = max(shape.halfWidth * 2, 12)
        let a = plow.x, b = plow.x + plow.direction * width
        let added = surfaces[g].deposit(volume: plow.wallVolume, minX: min(a, b), maxX: max(a, b))
        plow.wallVolume -= added
        // Columns at their maximum: the rest goes down as clumps nearby.
        var budget = 40
        while plow.wallVolume > 1e-6, budget > 0 {
            budget -= 1
            let volume = min(CGFloat.random(in: config.clumpVolumeRange, using: &rng), plow.wallVolume)
            let position = CGPoint(x: plow.x - plow.direction * CGFloat.random(in: 0...60, using: &rng), y: bounds.maxY - 60)
            guard spawnThrownClump(at: position, volume: volume, velocity: CGVector(dx: 0, dy: 0)) else { break }
            plow.wallVolume -= volume
        }
        plow.wallVolume = 0
    }

    @discardableResult
    mutating func spawnThrownClump(at position: CGPoint, volume: CGFloat, velocity: CGVector, driftX: CGFloat = 0) -> Bool {
        let natural = (volume / .pi).squareRoot() * 0.95
        let radius = min(max(natural, config.clumpRadiusRange.lowerBound), config.clumpRadiusRange.upperBound + 2)
        return spawn(kind: .clump, at: position, radius: radius, snowVolume: volume, velocity: velocity,
                     driftX: driftX, swayAmplitude: 0.5, opacity: 1)
    }
}
