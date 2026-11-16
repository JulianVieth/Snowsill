import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct FlakeInstancesTests {
    @Test func layoutMatchesShaderStruct() {
        // MSL: struct { float2 position; float radius; float opacity; }
        #expect(MemoryLayout<FlakeInstance>.stride == 16)
        #expect(MemoryLayout<FlakeInstance>.offset(of: \.radius) == 8)
        #expect(MemoryLayout<FlakeInstance>.offset(of: \.opacity) == 12)
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

        let screen = CGRect(x: -1280, y: 500, width: 1280, height: 800)
        var out = [FlakeInstance](repeating: FlakeInstance(), count: 4)
        let count = out.withUnsafeMutableBufferPointer {
            FlakeInstances.pack(flakes, screenFrameCG: screen, into: $0)
        }

        #expect(count == 2)
        #expect(out[0].position == SIMD2(280, 700))
        #expect(out[0].radius == 2)
        #expect(out[0].opacity == 0.5)
        #expect(out[1].position == SIMD2(1000, 0))
        #expect(out[1].radius == 3)
    }

    @Test func neverWritesPastBuffer() {
        var flakes = ContiguousArray(repeating: Flake(), count: 10)
        for i in flakes.indices { flakes[i].isActive = true }
        var out = [FlakeInstance](repeating: FlakeInstance(), count: 3)
        let count = out.withUnsafeMutableBufferPointer {
            FlakeInstances.pack(flakes, screenFrameCG: CGRect(x: 0, y: 0, width: 100, height: 100), into: $0)
        }
        #expect(count == 3)
    }
}
