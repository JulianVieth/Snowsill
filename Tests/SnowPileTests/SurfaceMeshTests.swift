import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct SurfaceMeshTests {
    // Screen 0...100 x 0...50 (CG), ground at its bottom edge -> scene-local base y = 0.
    let screen = CGRect(x: 0, y: 0, width: 100, height: 50)

    func makeGround(width: CGFloat = 8) -> Surface {
        Surface(kind: .ground(screen: 0), minX: 0, baseY: 50, width: width, maxHeight: 50, edges: .walls)
    }

    func build(_ surface: Surface) -> [SurfaceVertex] {
        var out = [SurfaceVertex](repeating: SurfaceVertex(), count: SurfaceMesh.vertexCount(for: surface))
        let written = out.withUnsafeMutableBufferPointer {
            SurfaceMesh.build(surface, screenFrameCG: screen, into: $0)
        }
        #expect(written == out.count)
        return out
    }

    @Test func layoutMatchesShaderStruct() {
        // MSL: struct { float2 position; float4 color; } -> float4 is 16-byte aligned
        #expect(MemoryLayout<SurfaceVertex>.stride == 32)
        #expect(MemoryLayout<SurfaceVertex>.offset(of: \.color) == 16)
    }

    @Test func vertexCountIsTwoStripsOfColumnEdges() {
        // 4 columns -> 5 column edges, body and fringe strip with 2 vertices each
        #expect(SurfaceMesh.vertexCount(for: makeGround()) == 20)
    }

    @Test func bodyStripFollowsSmoothedHeights() {
        var ground = makeGround()
        ground.deposit(volume: 8, minX: 2, maxX: 4) // column 1 -> height 4
        let v = build(ground)
        let edges = 5
        // Body: (bottom, top) per column edge
        #expect(v[0].position == SIMD2(0, 0))
        #expect(v[1].position == SIMD2(0, 0))        // edge 0: height of column 0
        #expect(v[3].position == SIMD2(2, 2))        // edge 1: average of columns 0 and 1
        #expect(v[5].position == SIMD2(4, 2))        // edge 2: average of columns 1 and 2
        #expect(v[9].position == SIMD2(8, 0))        // edge 4: height of column 3
        // Fringe starts after the body and sits 1 pt above the top, fully transparent
        #expect(v[2 * edges + 2].position == v[3].position)
        #expect(v[2 * edges + 3].position == SIMD2(2, 3))
        #expect(v[2 * edges + 3].color.w == 0)
    }

    @Test func emptySnowIsInvisible() {
        let v = build(makeGround())
        for vertex in v { #expect(vertex.color.w == 0) }
    }

    @Test func thickSnowIsOpaqueAndPremultiplied() {
        var ground = makeGround()
        ground.deposit(volume: 80, minX: 0, maxX: 8)
        let v = build(ground)
        let top = v[3].color
        #expect(top.w == 1)
        #expect(top.x <= top.w && top.y <= top.w && top.z <= top.w)
    }

    @Test func groundOnSecondaryScreenUsesLocalCoordinates() {
        let other = CGRect(x: -200, y: -100, width: 200, height: 100)
        let ground = Surface(kind: .ground(screen: 1), minX: -200, baseY: 0, width: 4, maxHeight: 50, edges: .walls)
        var out = [SurfaceVertex](repeating: SurfaceVertex(), count: SurfaceMesh.vertexCount(for: ground))
        _ = out.withUnsafeMutableBufferPointer { SurfaceMesh.build(ground, screenFrameCG: other, into: $0) }
        #expect(out[0].position == SIMD2(0, 0))
        #expect(out[4].position == SIMD2(4, 0))
    }

    @Test func offsetShiftsTheWholeMeshInCGDirections() {
        var ground = makeGround()
        ground.deposit(volume: 8, minX: 2, maxX: 4)
        let plain = build(ground)
        var shifted = [SurfaceVertex](repeating: SurfaceVertex(), count: plain.count)
        _ = shifted.withUnsafeMutableBufferPointer {
            // CG offset: 10 right, 5 down -> scene: 10 right, 5 down (negative y)
            SurfaceMesh.build(ground, screenFrameCG: screen, offset: CGVector(dx: 10, dy: 5), into: $0)
        }
        for (a, b) in zip(plain, shifted) {
            #expect(b.position == a.position + SIMD2(10, -5))
            #expect(b.color == a.color)
        }
    }

    @Test func tooSmallBufferWritesNothing() {
        var out = [SurfaceVertex](repeating: SurfaceVertex(), count: 3)
        let written = out.withUnsafeMutableBufferPointer {
            SurfaceMesh.build(makeGround(), screenFrameCG: screen, into: $0)
        }
        #expect(written == 0)
    }
}
