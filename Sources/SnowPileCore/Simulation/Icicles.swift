import CoreGraphics

/// An icicle hanging from a window's bottom edge, `offset` from the window's left edge.
public struct Icicle: Sendable, Equatable {
    public internal(set) var offset: CGFloat
    public internal(set) var length: CGFloat
    public internal(set) var maxLength: CGFloat
    public internal(set) var width: CGFloat
    public internal(set) var seed: CGFloat
    /// Covered by a window in front.
    public internal(set) var isHidden = false
}

/// Per-window icicle state.
struct IcicleGroup: Sendable {
    var icicles: [Icicle] = []
    /// How long snow has been lying on the window.
    var snowTime: Double = 0
    var nextSpawn: Double = 0
}

extension SnowSimulation {
    static let icicleCornerInset: CGFloat = 22
    static let icicleSpacing: CGFloat = 16

    /// Icicles of a window with the window's current bounds, for drawing.
    public func icicles(ofWindow number: Int) -> (bounds: CGRect, icicles: [Icicle])? {
        guard let group = icicleGroups[number], !group.icicles.isEmpty, let bounds = tracked[number]?.bounds else { return nil }
        return (bounds, group.icicles)
    }

    public var icicleWindows: [Int] { Array(icicleGroups.keys) }

    mutating func stepIcicles(dt: CGFloat) {
        guard config.iciclesEnabled else {
            icicleGroups.removeAll()
            return
        }
        for s in surfaces.indices {
            guard case .window(let number) = surfaces[s].kind, let window = tracked[number], !window.isWidget else { continue }
            let bounds = window.bounds
            // Needs room below the window and enough window to hang from.
            guard bounds.maxY < self.bounds.maxY - 4, bounds.width > 2 * Self.icicleCornerInset + 10 else {
                icicleGroups[number] = nil
                continue
            }
            var group = icicleGroups[number] ?? IcicleGroup()
            let snowy = surfaces[s].meanHeight >= config.icicleSnowHeight
            if snowy {
                group.snowTime += Double(dt)
            } else {
                group.snowTime = 0
            }

            for i in group.icicles.indices {
                if snowy {
                    group.icicles[i].length = min(group.icicles[i].length + config.icicleGrowth * dt, group.icicles[i].maxLength)
                } else {
                    // No snow left on top: they slowly melt away.
                    group.icicles[i].length -= config.icicleGrowth * 0.4 * dt
                }
            }
            group.icicles.removeAll { $0.length < 0.5 }

            let maxCount = min(Int((bounds.width - 2 * Self.icicleCornerInset) / 70), 9)
            if snowy, group.snowTime >= config.icicleDelay, time >= group.nextSpawn, group.icicles.count < maxCount {
                group.nextSpawn = time + Double.random(in: config.icicleSpawnInterval, using: &rng)
                let span = (Self.icicleCornerInset)...(bounds.width - Self.icicleCornerInset)
                for _ in 0..<8 {
                    let offset = CGFloat.random(in: span, using: &rng)
                    guard !group.icicles.contains(where: { abs($0.offset - offset) < Self.icicleSpacing }) else { continue }
                    group.icicles.append(Icicle(
                        offset: offset, length: 1, maxLength: CGFloat.random(in: 9...30, using: &rng),
                        width: CGFloat.random(in: 3.6...6.0, using: &rng), seed: CGFloat.random(in: 0..<1, using: &rng)
                    ))
                    break
                }
            }
            icicleGroups[number] = group
        }
        // Windows without a snow surface (gone, off screen) keep nothing.
        for number in icicleGroups.keys where tracked[number] == nil { icicleGroups[number] = nil }
    }

    /// Called after the window list changed: icicles of closed windows and of windows moved fast break off,
    /// icicles past a shrunk window's edge break off too, and hidden ones are marked.
    mutating func updateIcicles(previous: [Int: TrackedWindow], windows: [WindowInfo]) {
        guard !icicleGroups.isEmpty else { return }
        var order: [Int: Int] = [:]
        for (i, window) in windows.enumerated() { order[window.number] = i }
        for number in Array(icicleGroups.keys) {
            guard var group = icicleGroups[number] else { continue }
            guard let window = tracked[number], let index = order[number] else {
                // Closed: they fall where the window was.
                if let old = previous[number] { breakOff(group.icicles, below: old.bounds) }
                icicleGroups[number] = nil
                continue
            }
            let speed = hypot(window.velocity.dx, window.velocity.dy)
            if speed > config.icicleBreakSpeed {
                breakOff(group.icicles, below: previous[number]?.bounds ?? window.bounds)
                group.icicles.removeAll()
                group.snowTime = 0
            } else {
                let limit = window.bounds.width - Self.icicleCornerInset / 2
                breakOff(group.icicles.filter { $0.offset > limit }, below: window.bounds)
                group.icicles.removeAll { $0.offset > limit }
            }
            let occluders = windows[..<index].map(\.bounds)
            for i in group.icicles.indices {
                let p = CGPoint(x: window.bounds.minX + group.icicles[i].offset, y: window.bounds.maxY + 2)
                group.icicles[i].isHidden = occluders.contains { $0.contains(p) }
            }
            icicleGroups[number] = group
        }
    }

    private mutating func breakOff(_ icicles: [Icicle], below bounds: CGRect) {
        for icicle in icicles where !icicle.isHidden {
            let position = CGPoint(x: bounds.minX + icicle.offset, y: bounds.maxY + icicle.length / 2)
            spawn(kind: .ice, at: position, radius: icicle.width / 2, snowVolume: 0,
                  velocity: CGVector(dx: CGFloat.random(in: -20...20, using: &rng), dy: CGFloat.random(in: 0...40, using: &rng)),
                  driftX: 0, swayAmplitude: 0, opacity: 1, length: icicle.length)
        }
    }
}
