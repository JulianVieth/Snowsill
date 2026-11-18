import CoreGraphics

/// Deterministic value noise, used for purely visual irregularity (bumpy caps, ragged ground edge, gusts).
public enum Noise {
    @inline(__always)
    static func hash(_ i: Int, _ seed: Int) -> CGFloat {
        var x = UInt64(bitPattern: Int64(i &* 374_761_393 &+ seed &* 668_265_263))
        x = (x ^ (x >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        x = (x ^ (x >> 33)) &* 0xC4CE_B9FE_1A85_EC53
        x ^= x >> 33
        return CGFloat(x >> 11) / CGFloat(1 << 53) * 2 - 1
    }

    /// Smooth noise in -1...1 with features about one unit apart.
    @inline(__always)
    public static func value(_ x: CGFloat, seed: Int = 0) -> CGFloat {
        let floorX = x.rounded(.down)
        let i = Int(floorX)
        let t = x - floorX
        let s = t * t * (3 - 2 * t)
        return hash(i, seed) * (1 - s) + hash(i + 1, seed) * s
    }

    /// Two octaves of value noise, roughly -1...1.
    @inline(__always)
    public static func fractal(_ x: CGFloat, seed: Int = 0) -> CGFloat {
        (value(x, seed: seed) * 2 + value(x * 2.7 + 13.1, seed: seed &+ 1)) / 3
    }
}
