import CoreGraphics

/// One or more snowballs stacked on each other. Three make a snowman.
public struct SnowStack: Sendable, Equatable {
    public enum Support: Sendable, Equatable {
        case ground
        /// On a window's top edge, `offset` from the window's left edge, so it travels with the window.
        case window(number: Int, offset: CGFloat)
        /// In the air. `shatters` when it lost its support (window closed): it bursts on impact.
        case falling(velocity: CGFloat, shatters: Bool)
    }

    public let id: Int
    /// Snow volume of each ball (pt²), bottom to top.
    public internal(set) var volumes: [CGFloat]
    /// Center x and the y where the bottom ball touches its support (CG).
    public internal(set) var x: CGFloat
    public internal(set) var bottomY: CGFloat
    public internal(set) var support: Support
    /// Behind a window in front (its spot on the window's edge is covered). Kept, but not drawn.
    public internal(set) var isHidden = false

    public static func radius(volume: CGFloat) -> CGFloat { (volume / .pi).squareRoot() }

    public var radii: [CGFloat] { volumes.map(Self.radius(volume:)) }
    public var isSnowman: Bool { volumes.count >= 3 }
    public var totalVolume: CGFloat { volumes.reduce(0, +) }

    /// Ball centers, bottom to top. Balls overlap a little where they are pressed onto each other,
    /// and the bottom ball sinks a little into the snow.
    public var centers: [CGPoint] {
        var result: [CGPoint] = []
        let rs = radii
        for (i, r) in rs.enumerated() {
            let y = i == 0 ? bottomY - r * Self.sink : result[i - 1].y - (rs[i - 1] + r) * Self.overlap
            result.append(CGPoint(x: x, y: y))
        }
        return result
    }

    static let sink: CGFloat = 0.92
    static let overlap: CGFloat = 0.86

    /// Topmost point of the stack (CG y).
    public var topY: CGFloat {
        guard let top = centers.last, let r = radii.last else { return bottomY }
        return top.y - r
    }

    public func contains(_ p: CGPoint, padding: CGFloat = 0) -> Bool {
        for (c, r) in zip(centers, radii) where hypot(p.x - c.x, p.y - c.y) <= r + padding { return true }
        return false
    }
}

/// The ball being rolled or carried with the mouse.
public struct HeldBall: Sendable, Equatable {
    public internal(set) var volume: CGFloat
    public internal(set) var center: CGPoint
    public var radius: CGFloat { SnowStack.radius(volume: volume) }
    /// Whether it touches the ground snow and is rolling (as opposed to being carried in the air).
    public internal(set) var isRolling: Bool
}

extension SnowSimulation {
    static let minGrabHeight: CGFloat = 5
    static let startVolume: CGFloat = 40
    static let maxBallVolume: CGFloat = .pi * 46 * 46
    static let ballGravity: CGFloat = 1600

    // MARK: - Hit testing

    /// What a mouse press at `p` would grab: a ball or snowman, or enough ground snow to start a ball.
    /// Never anything inside a window (`windows` are all window rects), so clicks on windows always go through.
    public func canGrab(at p: CGPoint, windows: [CGRect]) -> Bool {
        guard config.snowmenEnabled, held == nil else { return held != nil }
        if windows.contains(where: { $0.contains(p) }) { return false }
        if stacks.contains(where: { !$0.isHidden && $0.contains(p, padding: 2) }) { return true }
        guard let g = groundIndex, let column = surfaces[g].column(at: p.x) else { return false }
        let height = surfaces[g].heights[column]
        return height >= Self.minGrabHeight && p.y >= surfaces[g].topY(atColumn: column) - 4 && p.y <= surfaces[g].baseY
    }

    // MARK: - Grabbing

    /// Starts rolling or carrying. Grabbing a stack takes its top ball.
    @discardableResult
    public mutating func beginGrab(at p: CGPoint, windows: [CGRect]) -> Bool {
        guard held == nil, canGrab(at: p, windows: windows) else { return false }
        // Topmost stack first (a stack in front of the ground snow).
        if let index = stacks.lastIndex(where: { !$0.isHidden && $0.contains(p, padding: 2) }) {
            var stack = stacks[index]
            let center = stack.centers.last ?? p
            let volume = stack.volumes.removeLast()
            held = HeldBall(volume: volume, center: center, isRolling: false)
            if stack.volumes.isEmpty { stacks.remove(at: index) } else { stacks[index] = stack }
            return true
        }
        guard let g = groundIndex else { return false }
        // Scoop a small starting ball out of the ground snow around the cursor.
        var taken: CGFloat = 0
        let reach = 6
        if let center = surfaces[g].column(at: p.x) {
            for c in max(center - reach, 0)...min(center + reach, surfaces[g].heights.count - 1) where taken < Self.startVolume {
                taken += surfaces[g].take(column: c, depth: min(3, (Self.startVolume - taken) / Surface.columnWidth))
            }
        }
        guard taken > 0 else { return false }
        let r = SnowStack.radius(volume: taken)
        let top = groundTop(at: p.x) ?? surfaces[g].baseY
        held = HeldBall(volume: taken, center: CGPoint(x: p.x, y: min(p.y, top - r)), isRolling: true)
        return true
    }

    /// Moves the held ball. Touching the ground snow it rolls and picks up the snow along its path.
    public mutating func moveGrab(to p: CGPoint) {
        guard var ball = held else { return }
        let x = min(max(p.x, bounds.minX), bounds.maxX)
        var y = min(max(p.y, bounds.minY), bounds.maxY)
        var rolling = false
        if let g = groundIndex, let top = groundTop(at: x) {
            let r = ball.radius
            // Can't push the ball into the snow; close to it, it rolls on it.
            if y >= top - r - 6 {
                y = top - r
                rolling = true
                let from = ball.center.x
                if abs(x - from) > 0, ball.volume < Self.maxBallVolume {
                    ball.volume += pickUp(ground: g, from: from, to: x, radius: r, limit: Self.maxBallVolume - ball.volume)
                    let newR = ball.radius
                    // Stays on top of the (now lower) snow as it grows.
                    y = (groundTop(at: x) ?? top) - newR
                }
            }
        }
        ball.center = CGPoint(x: x, y: y)
        ball.isRolling = rolling
        held = ball
    }

    /// Lets go: the ball drops onto whatever is below it.
    public mutating func endGrab() {
        guard let ball = held else { return }
        held = nil
        let r = ball.radius
        let stack = SnowStack(
            id: nextStackID, volumes: [ball.volume], x: ball.center.x, bottomY: ball.center.y + r * SnowStack.sink,
            support: .falling(velocity: 0, shatters: false)
        )
        nextStackID += 1
        stacks.append(stack)
    }

    /// Snow along the rolled path sticks to the ball: a layer per column, deeper for bigger balls.
    private mutating func pickUp(ground g: Int, from a: CGFloat, to b: CGFloat, radius: CGFloat, limit: CGFloat) -> CGFloat {
        let surface = surfaces[g]
        guard let ca = surface.column(at: min(max(a, surface.minX), surface.maxX - 0.01)),
              let cb = surface.column(at: min(max(b, surface.minX), surface.maxX - 0.01)), ca != cb else { return 0 }
        let depth = 2.2 + radius * 0.07
        var gained: CGFloat = 0
        for c in min(ca, cb)...max(ca, cb) where gained < limit {
            gained += surfaces[g].take(column: c, depth: min(depth, (limit - gained) / Surface.columnWidth))
        }
        return gained
    }

    // MARK: - Physics

    mutating func stepStacks(dt: CGFloat) {
        guard !stacks.isEmpty else { return }
        var i = 0
        while i < stacks.count {
            var stack = stacks[i]
            var remove = false
            switch stack.support {
            case .ground:
                if let top = groundTop(at: stack.x) { stack.bottomY = top } else { stack.support = .falling(velocity: 0, shatters: true) }
            case .window(let number, let offset):
                if let left = tracked[number]?.bounds.minX,
                   let s = surfaces.firstIndex(where: { $0.kind == .window(number: number) }),
                   let column = surfaces[s].column(at: left + offset) {
                    stack.x = left + offset
                    stack.bottomY = surfaces[s].topY(atColumn: column)
                    stack.isHidden = surfaces[s].isHidden(column)
                } else {
                    // The window closed or the ground under the stack is gone: it falls and bursts.
                    stack.support = .falling(velocity: 0, shatters: true)
                }
            case .falling(let velocity, let shatters):
                let v = velocity + Self.ballGravity * dt
                let previous = stack.bottomY
                stack.bottomY += v * dt
                if let landing = landingSupport(for: stack, excluding: i, from: previous) {
                    if shatters {
                        shatter(stack, at: landing.y)
                        remove = true
                    } else {
                        switch landing.target {
                        case .stack(let index):
                            stacks[index].volumes.append(contentsOf: stack.volumes)
                            remove = true
                        case .support(let support):
                            stack.support = support
                            stack.bottomY = landing.y
                        }
                    }
                } else if stack.bottomY - (stack.radii.first ?? 0) * 2 > bounds.maxY + 40 {
                    // Fell off the screen (no ground snow): gone.
                    remove = true
                } else {
                    stack.support = .falling(velocity: v, shatters: shatters)
                }
            }
            if remove {
                stacks.remove(at: i)
            } else {
                stacks[i] = stack
                i += 1
            }
        }
    }

    private enum LandingTarget {
        case stack(Int)
        case support(SnowStack.Support)
    }

    /// Where a falling stack lands this step: on a bigger ball of an unfinished stack, a window's snow or the ground.
    private func landingSupport(for stack: SnowStack, excluding self_: Int, from previousY: CGFloat) -> (y: CGFloat, target: LandingTarget)? {
        let x = stack.x
        let r = stack.radii.first ?? 0
        var best: (y: CGFloat, target: LandingTarget)?
        func consider(_ y: CGFloat, _ target: LandingTarget) {
            // Crossed `y` this step, and it's the highest such support.
            guard previousY <= y + 0.5, stack.bottomY >= y else { return }
            if best == nil || y < best!.y { best = (y, target) }
        }
        // Stacking: only a smaller (or equal) ball onto an unfinished stack, and only if it sits on the ball.
        if stack.volumes.count == 1 {
            for (j, other) in stacks.enumerated() where j != self_ && other.volumes.count < 3 && !other.isHidden {
                if case .falling = other.support { continue }
                guard let topR = other.radii.last, r <= topR * 1.02, abs(other.x - x) < topR * 0.7 else { continue }
                guard let topCenter = other.centers.last else { continue }
                consider(topCenter.y - (topR + r) * SnowStack.overlap + r * SnowStack.sink, .stack(j))
            }
        }
        for s in surfaces.indices {
            guard let column = surfaces[s].column(at: x), !surfaces[s].isHidden(column) else { continue }
            let top = surfaces[s].topY(atColumn: column)
            switch surfaces[s].kind {
            case .ground: consider(top, .support(.ground))
            case .window(let number):
                guard let left = tracked[number]?.bounds.minX else { continue }
                consider(top, .support(.window(number: number, offset: x - left)))
            }
        }
        return best
    }

    /// A stack that lost its support bursts into clumps and powder where it hits.
    private mutating func shatter(_ stack: SnowStack, at y: CGFloat) {
        let r = stack.radii.max() ?? 4
        spawnDebris(volume: stack.totalVolume, x: (stack.x - r)...(stack.x + r), y: (y - 2 * r)...(y - 2),
                    inheritedVX: 0, outward: 0)
    }

    /// X ranges on the ground that the plow must not drive into: balls and snowmen.
    func groundObstacles() -> [ClosedRange<CGFloat>] {
        stacks.compactMap { stack in
            guard case .ground = stack.support, let r = stack.radii.max() else { return nil }
            return (stack.x - r)...(stack.x + r)
        }
    }
}
