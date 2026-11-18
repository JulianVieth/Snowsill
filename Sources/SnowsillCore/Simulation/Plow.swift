import CoreGraphics

/// A little snow plow that crosses the screen bottom now and then, so the ground layer doesn't turn into a
/// uniform block. It scrapes the snow down to a thin, irregular layer and pushes it ahead as a wall: part of the
/// ground's heightmap right in front of the blade, so there is one mass with a natural slope. The blade is a wall
/// for the sandpile rule, nothing slides back behind it. What doesn't fit into the wall is pushed aside, out of
/// view, like a real plow pushes snow to the roadside; at the screen edge it flies off as clumps.
public struct Plow: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Scraping with the blade down.
        case plowing
        /// Blade up, backing off after stopping in front of something built.
        case leaving
    }

    public static let length: CGFloat = 78
    public static let bladeHeight: CGFloat = 18
    /// The wall in front of the blade rises at most this much above the untouched snow ahead ...
    public static let wallRise: CGFloat = 16
    /// ... and reaches at most this far ahead of the blade.
    public static let wallLength: CGFloat = 60
    /// Pause before it comes back from the other side after something built stopped it.
    public static let returnDelay: Double = 3
    /// Once the ground is this full (share of its maximum height), the plow comes after a short pause instead
    /// of the regular interval: in a blizzard the ground fills in about a minute.
    public static let fullGround: CGFloat = 0.8
    public static let fullGroundPause: Double = 30
    /// Distance it keeps from anything built, room for the wall in front of the blade.
    static let stopMargin: CGFloat = 6 + wallLength

    public internal(set) var phase: Phase = .idle
    /// Front edge of the blade (CG x).
    public internal(set) var x: CGFloat = 0
    /// +1 drives right, -1 drives left.
    public internal(set) var direction: CGFloat = 1
    /// Simulation time of the last finished run.
    public internal(set) var lastRun: Double = 0
    /// Snow pushed aside out of view in total (pt²), so the books balance.
    public internal(set) var pushedAside: CGFloat = 0
    /// Time until the next clump tumbles over the wall's crest.
    var tumbleTimer: CGFloat = 0
    var run = 0
    /// Stopped by something built: comes back from this side right away, so the snow behind it isn't left
    /// to pile up until the next regular run (it would be full again by then).
    var returnDirection: CGFloat?
    var isReturnTrip = false

    public init() {}

    public var isActive: Bool { phase != .idle }

    /// Height of the thin layer the blade leaves behind at absolute `x`.
    public func residual(at x: CGFloat) -> CGFloat {
        1.2 + 1.4 * (Noise.fractal(x / 7, seed: 300 + run) + 1) / 2
    }
}

extension SnowSimulation {
    mutating func stepPlow(dt: CGFloat) {
        guard let g = groundIndex else {
            plow.phase = .idle
            return
        }
        if plow.phase == .idle {
            guard config.plowEnabled else {
                plow.returnDirection = nil
                return
            }
            if let back = plow.returnDirection {
                guard time - plow.lastRun >= Plow.returnDelay else { return }
                plow.returnDirection = nil
                plow.isReturnTrip = true
                plow.direction = back
            } else {
                let height = reachableMeanHeight(ground: g)
                let pause = time - plow.lastRun
                let due = height >= config.plowThreshold && pause >= config.plowInterval
                let full = height >= surfaces[g].maxHeight * Plow.fullGround && pause >= Plow.fullGroundPause
                guard due || full else { return }
                plow.run += 1
                plow.isReturnTrip = false
                // Alternate sides so both get cleared.
                plow.direction = plow.run % 2 == 1 ? 1 : -1
            }
            plow.x = plow.direction > 0 ? bounds.minX - 4 : bounds.maxX + 4
            plow.phase = .plowing
        }

        var target = plow.x + config.plowSpeed * dt * plow.direction

        if plow.phase == .plowing {
            // Stop in front of anything built, leaving room for the wall so it ends up before it, not under it.
            var blocked = false
            let margin = Plow.stopMargin
            for obstacle in groundObstacles() {
                if plow.direction > 0, obstacle.lowerBound >= plow.x, target > obstacle.lowerBound - margin {
                    target = max(plow.x, obstacle.lowerBound - margin)
                    blocked = true
                } else if plow.direction < 0, obstacle.upperBound <= plow.x, target < obstacle.upperBound + margin {
                    target = min(plow.x, obstacle.upperBound + margin)
                    blocked = true
                }
            }

            let scraped = scrape(ground: g, from: plow.x, to: target)
            plow.x = target
            // The blade holds back the snow in front of it: a wall between the last scraped and the first wall column.
            let bladeColumn = Int(((plow.x - surfaces[g].minX) / Surface.columnWidth).rounded(.down))
            let barrier = plow.direction > 0 ? bladeColumn + 1 : bladeColumn
            surfaces[g].barrier = (1..<surfaces[g].heights.count).contains(barrier) ? barrier : nil
            var aside = pushIntoWall(ground: g, volume: scraped)
            aside -= tumbleOverCrest(ground: g, budget: aside, dt: dt)
            let nearEdge = plow.direction > 0 ? plow.x >= bounds.maxX - 40 : plow.x <= bounds.minX + 40
            if nearEdge {
                throwOffScreen(volume: aside)
            } else {
                plow.pushedAside += aside
            }

            if blocked {
                surfaces[g].barrier = nil
                plow.phase = .leaving
                // Only once per visit, so two obstacles don't make it shuttle back and forth.
                if !plow.isReturnTrip { plow.returnDirection = -plow.direction }
                plow.direction = -plow.direction
            }
        } else {
            plow.x = target
        }

        // Done once the whole vehicle has left the screen.
        let rear = plow.x - plow.direction * Plow.length
        if plow.direction > 0 ? rear > bounds.maxX + 8 : rear < bounds.minX - 8 {
            surfaces[g].barrier = nil
            plow.phase = .idle
            plow.lastRun = time
        }
    }

    /// Mean ground height where the plow can get to: from either screen edge up to the first thing built.
    /// Snow between two snowmen or in the walls left in front of them never goes away, so it doesn't count.
    func reachableMeanHeight(ground g: Int) -> CGFloat {
        let surface = surfaces[g]
        let obstacles = groundObstacles()
        guard let first = obstacles.map(\.lowerBound).min(), let last = obstacles.map(\.upperBound).max() else {
            return surface.meanHeight
        }
        let leftEnd = first - Plow.stopMargin, rightStart = last + Plow.stopMargin
        var sum: CGFloat = 0
        var count = 0
        for (c, h) in surface.heights.enumerated() {
            let x = surface.minX + (CGFloat(c) + 0.5) * Surface.columnWidth
            guard x < leftEnd || x > rightStart else { continue }
            sum += h
            count += 1
        }
        return count > 0 ? sum / CGFloat(count) : 0
    }

    func groundTop(at x: CGFloat) -> CGFloat? {
        guard let g = groundIndex, let c = surfaces[g].column(at: min(max(x, surfaces[g].minX), surfaces[g].maxX - 0.01)) else { return nil }
        return surfaces[g].topY(atColumn: c)
    }

    var groundIndex: Int? {
        surfaces.firstIndex { if case .ground = $0.kind { return true } else { return false } }
    }

    /// Lowers the columns the blade passed to the residual layer. Returns the scraped volume.
    private mutating func scrape(ground g: Int, from a: CGFloat, to b: CGFloat) -> CGFloat {
        let lower = min(a, b), upper = max(a, b)
        guard upper > lower else { return 0 }
        let surface = surfaces[g]
        let first = max(Int(((lower - surface.minX) / Surface.columnWidth).rounded(.down)), 0)
        let last = min(Int(((upper - surface.minX) / Surface.columnWidth).rounded(.down)), surface.heights.count - 1)
        guard first <= last else { return 0 }
        var scraped: CGFloat = 0
        for c in first...last {
            let x = surface.minX + (CGFloat(c) + 0.5) * Surface.columnWidth
            scraped += surfaces[g].scrape(column: c, to: plow.residual(at: x))
        }
        return scraped
    }

    /// Adds scraped snow to the wall: a bulge in front of the blade, up to `wallRise` above the untouched snow
    /// beyond it and tapering into it `wallLength` ahead, nearest columns first. Returns what didn't fit.
    private mutating func pushIntoWall(ground g: Int, volume: CGFloat) -> CGFloat {
        guard volume > 0 else { return 0 }
        let count = surfaces[g].heights.count
        let blade = Int(((plow.x - surfaces[g].minX) / Surface.columnWidth).rounded(.down))
        let reach = Int(Plow.wallLength / Surface.columnWidth)
        let step = plow.direction > 0 ? 1 : -1
        // The untouched snow just beyond the wall sets the level the wall stands on.
        let beyond = min(max(blade + step * (reach + 3), 0), count - 1)
        let level = surfaces[g].heights[beyond]
        var remaining = volume
        // The column the blade stands in was just scraped; the wall starts next to it.
        var c = blade + step
        var filled = 0
        while remaining > 1e-9, filled < reach, surfaces[g].heights.indices.contains(c) {
            let t = CGFloat(filled) / CGFloat(reach)
            let cap = min(level + Plow.wallRise * (1 - t * t), surfaces[g].maxHeight)
            let room = (cap - surfaces[g].heights[c]) * Surface.columnWidth
            if room > 0 {
                let x = surfaces[g].minX + CGFloat(c) * Surface.columnWidth
                remaining -= surfaces[g].deposit(volume: min(room, remaining), minX: x, maxX: x + Surface.columnWidth)
            }
            c += step
            filled += 1
        }
        return max(remaining, 0)
    }

    /// Now and then a clump of the excess tumbles over the wall's crest and lands a little ahead,
    /// so the wall looks pushed rather than the snow vanishing. Returns the volume used.
    private mutating func tumbleOverCrest(ground g: Int, budget: CGFloat, dt: CGFloat) -> CGFloat {
        plow.tumbleTimer -= dt
        guard plow.tumbleTimer <= 0, budget >= config.clumpVolumeRange.lowerBound else { return 0 }
        // Not onto anything built ahead.
        let ahead = plow.direction > 0 ? plow.x...(plow.x + 220) : (plow.x - 220)...plow.x
        guard !groundObstacles().contains(where: { $0.overlaps(ahead) }) else { return 0 }
        plow.tumbleTimer = CGFloat.random(in: 0.08...0.25, using: &rng)
        let x = plow.x + plow.direction * CGFloat.random(in: 10...24, using: &rng)
        let top = groundTop(at: x) ?? bounds.maxY
        let volume = min(CGFloat.random(in: config.clumpVolumeRange, using: &rng), budget)
        // Faster than the plow, or it would overtake them and they'd land behind the blade.
        let speed = config.plowSpeed
        let velocity = CGVector(dx: plow.direction * (speed + CGFloat.random(in: 60...140, using: &rng)),
                                dy: CGFloat.random(in: -110 ... -50, using: &rng))
        guard spawnThrownClump(at: CGPoint(x: x, y: top - 3), volume: volume, velocity: velocity,
                               driftX: plow.direction * (speed + 40)) else { return 0 }
        return volume
    }

    /// At the screen edge the snow that goes aside flies off as clumps (it leaves the screen).
    private mutating func throwOffScreen(volume: CGFloat) {
        var remaining = volume
        var budget = 6
        while remaining > 1e-6, budget > 0 {
            budget -= 1
            let piece = min(CGFloat.random(in: config.clumpVolumeRange, using: &rng) * 2, remaining)
            let x = plow.x + plow.direction * CGFloat.random(in: 2...12, using: &rng)
            let top = groundTop(at: x) ?? bounds.maxY
            let position = CGPoint(x: x, y: top - CGFloat.random(in: 4...14, using: &rng))
            let velocity = CGVector(dx: plow.direction * CGFloat.random(in: 160...320, using: &rng),
                                    dy: CGFloat.random(in: -160 ... -60, using: &rng))
            // Keeps flying outward so it really leaves the screen.
            guard spawnThrownClump(at: position, volume: piece, velocity: velocity, driftX: plow.direction * 140) else { break }
            remaining -= piece
        }
        // Whatever didn't make it into a clump is pushed out of sight as well.
        plow.pushedAside += remaining
    }

    @discardableResult
    mutating func spawnThrownClump(at position: CGPoint, volume: CGFloat, velocity: CGVector, driftX: CGFloat = 0) -> Bool {
        let natural = (volume / .pi).squareRoot() * 0.95
        let radius = min(max(natural, config.clumpRadiusRange.lowerBound), config.clumpRadiusRange.upperBound + 2)
        return spawn(kind: .clump, at: position, radius: radius, snowVolume: volume, velocity: velocity,
                     driftX: driftX, swayAmplitude: 0.5, opacity: 1)
    }
}
