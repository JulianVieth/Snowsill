import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct SurfaceMeshTests {
    // Screen 0...100 x 0...50 (CG), ground at its bottom edge -> scene-local base y = 0.
    let screen = CGRect(x: 0, y: 0, width: 100, height: 50)

    func makeGround(width: CGFloat = 8) -> Surface {
        Surface(kind: .ground(screen: 0), minX: 0, baseY: 50, width: width, maxHeight: 50, edges: .walls)
    }

    func makeWindowSurface(width: CGFloat = 8) -> Surface {
        Surface(kind: .window(number: 1), minX: 0, baseY: 30, width: width, maxHeight: 14, edges: .spill, id: 3)
    }

    func build(_ surface: Surface, offset: CGVector = .zero) -> [SurfaceVertex] {
        var out = [SurfaceVertex](repeating: SurfaceVertex(), count: SurfaceMesh.vertexCount(for: surface))
        let written = out.withUnsafeMutableBufferPointer {
            SurfaceMesh.build(surface, screenFrameCG: screen, offset: offset, into: $0)
        }
        #expect(written == out.count)
        return out
    }

    func strip(_ v: [SurfaceVertex], _ k: Int, of surface: Surface) -> ArraySlice<SurfaceVertex> {
        let n = SurfaceMesh.stripLength(for: surface)
        return v[(k * n)..<((k + 1) * n)]
    }

    @Test func layoutMatchesShaderStruct() {
        // MSL: struct { float2 position; float4 color; } -> float4 is 16-byte aligned
        #expect(MemoryLayout<SurfaceVertex>.stride == 32)
        #expect(MemoryLayout<SurfaceVertex>.offset(of: \.color) == 16)
    }

    @Test func vertexCountIsFourStripsOfColumnEdges() {
        // 4 columns -> 5 column edges, 2 vertices each, 4 strips
        #expect(SurfaceMesh.stripLength(for: makeGround()) == 10)
        #expect(SurfaceMesh.vertexCount(for: makeGround()) == 40)
    }

    @Test func stripsStackFromBaseToTop() {
        var ground = makeGround()
        ground.deposit(volume: 64, minX: 0, maxX: 8) // 8 pt everywhere
        let v = build(ground)
        let lower = strip(v, 0, of: ground), upper = strip(v, 1, of: ground), fringe = strip(v, 2, of: ground)
        for e in 0..<5 {
            let bottom = lower[lower.startIndex + 2 * e], middle = lower[lower.startIndex + 2 * e + 1]
            let middle2 = upper[upper.startIndex + 2 * e], top = upper[upper.startIndex + 2 * e + 1]
            let fringeBottom = fringe[fringe.startIndex + 2 * e], fringeTop = fringe[fringe.startIndex + 2 * e + 1]
            #expect(bottom.position.y == 0)
            #expect(middle.position == middle2.position)
            #expect(middle.position.y > 0 && middle.position.y < top.position.y)
            #expect(fringeBottom.position == top.position)
            #expect(fringeTop.position.y == top.position.y + 1)
            #expect(fringeTop.color.w == 0)
            #expect(bottom.position.x == Float(2 * e))
        }
    }

    @Test func visualHeightStaysCloseToTheHeightmap() {
        var ground = Surface(kind: .ground(screen: 0), minX: 0, baseY: 50, width: 400, maxHeight: 50, edges: .walls)
        var window = Surface(kind: .window(number: 1), minX: 0, baseY: 50, width: 400, maxHeight: 14, edges: .spill, id: 5)
        ground.deposit(volume: 400 * 20, minX: 0, maxX: 400)
        window.deposit(volume: 400 * 10, minX: 0, maxX: 400)
        var groundValues: Set<Int> = []
        for edge in 4..<196 { // away from the rounded ends
            let g = SurfaceMesh.visualHeight(ground, edge: edge, trueHeight: 20)
            let w = SurfaceMesh.visualHeight(window, edge: edge, trueHeight: 10)
            #expect(g >= 20 - 10 * 0.25 && g <= 20 + 10 * 0.25)
            #expect(w >= 10 * 0.75 && w <= 10 * 1.4)
            groundValues.insert(Int(g * 10))
        }
        // It really is irregular.
        #expect(groundValues.count > 20)
    }

    @Test func emptySnowIsInvisible() {
        for surface in [makeGround(), makeWindowSurface()] {
            for vertex in build(surface) { #expect(vertex.color.w == 0) }
        }
    }

    @Test func hiddenColumnsAreInvisible() {
        var surface = makeWindowSurface(width: 16) // 8 columns over x 0..16
        surface.deposit(volume: 16 * 10, minX: 0, maxX: 16)
        surface.setVisible([0...8])
        let v = build(surface)
        let upper = strip(v, 1, of: surface)
        // Edges 5...8 lie between hidden columns.
        for e in 5...8 {
            #expect(upper[upper.startIndex + 2 * e + 1].color.w == 0)
        }
        #expect(upper[upper.startIndex + 2 * 2 + 1].color.w == 1)
    }

    @Test func thickSnowIsOpaqueAndPremultiplied() {
        var ground = makeGround()
        ground.deposit(volume: 80, minX: 0, maxX: 8)
        for vertex in build(ground).prefix(30) where vertex.color.w > 0 {
            #expect(vertex.color.x <= vertex.color.w && vertex.color.y <= vertex.color.w && vertex.color.z <= vertex.color.w)
        }
        #expect(build(ground)[1].color.w == 1)
    }

    @Test func windowsCastAShadowAndTheGroundDoesNot() {
        var window = makeWindowSurface()
        window.deposit(volume: 80, minX: 0, maxX: 8)
        var ground = makeGround()
        ground.deposit(volume: 80, minX: 0, maxX: 8)
        let w = strip(build(window), 3, of: window)
        let g = strip(build(ground), 3, of: ground)
        #expect(w[w.startIndex + 2].color.w > 0)
        #expect(w[w.startIndex + 3].position.y < w[w.startIndex + 2].position.y)
        #expect(g.allSatisfy { $0.color.w == 0 })
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
        var window = makeWindowSurface()
        window.deposit(volume: 8, minX: 2, maxX: 4)
        let plain = build(window)
        // CG offset: 10 right, 5 down -> scene: 10 right, 5 down (negative y)
        let shifted = build(window, offset: CGVector(dx: 10, dy: 5))
        for (a, b) in zip(plain, shifted) {
            let d = b.position - a.position - SIMD2(10, -5)
            #expect(abs(d.x) < 1e-4 && abs(d.y) < 1e-4)
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
