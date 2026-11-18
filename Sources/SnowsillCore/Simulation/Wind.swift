import CoreGraphics

/// Global wind: a calm breeze that slowly changes direction, gusts on top of it (smoothed noise), and now and then
/// a short flurry with many more flakes.
public struct Wind: Sendable {
    /// Breeze speed (pt/s) at strength 1.
    static let breeze: CGFloat = 9
    /// Extra speed of a full gust at strength 1.
    static let gust: CGFloat = 26

    public private(set) var speed: CGFloat = 0
    /// Factor on the snowfall rate, above 1 during a flurry.
    public private(set) var spawnFactor: CGFloat = 1
    var time: Double = 0
    let seed: Int
    var nextFlurry: Double
    var flurryStart: Double = -.infinity
    var flurryDuration: Double = 0

    init(seed: Int, firstFlurry: Double) {
        self.seed = seed
        nextFlurry = firstFlurry
    }

    public var isFlurry: Bool { time >= flurryStart && time < flurryStart + flurryDuration }

    mutating func step(dt: Double, strength: CGFloat, flurries: Bool, rng: inout SplitMix64) {
        time += dt
        // Direction drifts over minutes; mostly a breeze from one side, sometimes calm in between.
        let direction = Noise.value(CGFloat(time / 120), seed: seed)
        // Gusts: bursts a few seconds long, only the positive part of the noise.
        let g = max(Noise.fractal(CGFloat(time / 5), seed: seed &+ 17), 0)
        let gust = g * g * Self.gust * (direction >= 0 ? 1 : -1)

        var envelope: CGFloat = 0
        if flurries {
            if time >= nextFlurry {
                flurryStart = time
                flurryDuration = Double.random(in: 5...10, using: &rng)
                nextFlurry = time + flurryDuration + Double.random(in: 70...200, using: &rng)
            }
            if isFlurry {
                // Smooth in and out.
                envelope = CGFloat(sin((time - flurryStart) / flurryDuration * .pi))
            }
        }
        spawnFactor = 1 + 3 * envelope
        speed = strength * (Self.breeze * direction + gust) * (1 + 0.6 * envelope)
    }
}
