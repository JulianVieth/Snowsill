import CoreGraphics
import Testing
@testable import SnowsillCore

@Suite struct SpritesTests {
    @Test func layoutMatchesShaderStruct() {
        // MSL: struct { float2 position; float2 size; float4 color; float rotation, shape, seed, param; }
        #expect(MemoryLayout<Sprite>.stride == 48)
        #expect(MemoryLayout<Sprite>.offset(of: \.size) == 8)
        #expect(MemoryLayout<Sprite>.offset(of: \.color) == 16)
        #expect(MemoryLayout<Sprite>.offset(of: \.rotation) == 32)
        #expect(MemoryLayout<Sprite>.offset(of: \.shape) == 36)
        #expect(MemoryLayout<Sprite>.offset(of: \.seed) == 40)
        #expect(MemoryLayout<Sprite>.offset(of: \.param) == 44)
    }

    func pack(_ flakes: ContiguousArray<Flake>, screen: CGRect, capacity: Int) -> [Sprite] {
        var out = [Sprite](repeating: Sprite(), count: capacity)
        let count = out.withUnsafeMutableBufferPointer { buffer -> Int in
            var writer = SpriteWriter(buffer: buffer, screenFrameCG: screen)
            return FlakeSprites.pack(flakes, into: &writer)
        }
        return Array(out.prefix(count))
    }

    @Test func packsOnlyActiveFlakesInSceneCoordinates() {
        var flakes = ContiguousArray(repeating: Flake(), count: 4)
        flakes[1].isActive = true
        flakes[1].position = CGPoint(x: -1000, y: 600)
        flakes[1].radius = 2
        flakes[1].opacity = 0.5
        flakes[3].isActive = true
        flakes[3].position = CGPoint(x: -280, y: 1300)
        flakes[3].radius = 3
        flakes[3].opacity = 1

        let out = pack(flakes, screen: CGRect(x: -1280, y: 500, width: 1280, height: 800), capacity: 4)
        #expect(out.count == 2)
        #expect(out[0].position == SIMD2(280, 700))
        #expect(out[0].size == SIMD2(2, 2))
        #expect(out[0].color.w == 0.5)
        #expect(out[0].shape == Sprite.Shape.flake.rawValue)
        #expect(out[1].position == SIMD2(1000, 0))
    }

    @Test func clumpsUseTheClumpShapeAndRotation() {
        var flakes = ContiguousArray(repeating: Flake(), count: 1)
        flakes[0].isActive = true
        flakes[0].kind = .clump
        flakes[0].radius = 4
        flakes[0].opacity = 1
        flakes[0].rotation = 1
        flakes[0].seed = 0.25
        let out = pack(flakes, screen: CGRect(x: 0, y: 0, width: 100, height: 100), capacity: 1)
        #expect(out[0].shape == Sprite.Shape.clump.rawValue)
        #expect(out[0].rotation == -1)
        #expect(out[0].seed == 0.25)
    }

    @Test func neverWritesPastBuffer() {
        var flakes = ContiguousArray(repeating: Flake(), count: 10)
        for i in flakes.indices { flakes[i].isActive = true }
        #expect(pack(flakes, screen: CGRect(x: 0, y: 0, width: 100, height: 100), capacity: 3).count == 3)
    }
}
