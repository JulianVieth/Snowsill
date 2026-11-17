import AppKit
import MetalKit
import QuartzCore
import SnowPileCore

/// Drives the frame loop of one overlay: steps the simulation, draws the snow surfaces and then all flakes
/// in one instanced draw call.
@MainActor
final class SnowRenderer: NSObject, MTKViewDelegate {
    private static let maxFramesInFlight = 3
    private static let meshRebuildInterval: CFTimeInterval = 1.0 / 20
    /// Time from rendering a frame until it is on screen (two drawables at 60 Hz).
    private static let displayLatency: CFTimeInterval = 1.0 / 60
    /// Never extrapolate further than this, in case updates stop arriving.
    private static let maxPrediction: CFTimeInterval = 0.1

    /// Sprites beyond the particle pool: snowballs, snowmen, plow, icicles.
    static let extraSprites = 4096

    private struct SurfaceRange {
        var start: Int
        var stripLength: Int
        var debugStart: Int
    }

    private let screenFrameCG: CGRect
    private let debug: Bool
    private var simulation: SnowSimulation
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let spritePipeline: MTLRenderPipelineState
    private let surfacePipeline: MTLRenderPipelineState
    private let instanceBuffers: [MTLBuffer]
    private let inFlight = DispatchSemaphore(value: SnowRenderer.maxFramesInFlight)
    private var frameIndex = 0
    private var lastFrameTime: CFTimeInterval?

    // Surface mesh is built on the CPU at most at 20 Hz and copied into a frame's buffer only when that buffer is stale.
    private var mesh = ContiguousArray<SurfaceVertex>()
    private var meshRanges: [SurfaceRange] = []
    private var meshGeneration = 0
    /// (surface id, geometry version, version) the current mesh was built from.
    private var meshSources: [SIMD3<Int>] = []
    private var lastMeshBuild: CFTimeInterval = -.infinity
    /// Whether the last mesh was built with a predicted offset; then the next frame must rebuild as well.
    private var meshWasPredicted = false
    private var surfaceBuffers: [MTLBuffer] = []
    private var surfaceBufferGenerations: [Int]

    private var debugLabel: NSTextField?
    private var debugFrames = 0
    private var debugElapsed: CFTimeInterval = 0

    convenience init?(view: MTKView, screenFrameCG: CGRect, debug: Bool) {
        guard let device = view.device else { return nil }
        self.init(device: device, pixelFormat: view.colorPixelFormat, screenFrameCG: screenFrameCG, debug: debug)
        if debug {
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.textColor = .systemRed
            label.frame = NSRect(x: 12, y: 60, width: 760, height: 20)
            view.addSubview(label)
            debugLabel = label
        }
    }

    /// Without a view, for offscreen rendering (snapshot mode). A fixed `seed` makes runs repeatable.
    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, screenFrameCG: CGRect, debug: Bool, seed: UInt64? = nil) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.screenFrameCG = screenFrameCG
        self.debug = debug
        self.device = device
        simulation = SnowSimulation(bounds: screenFrameCG, seed: seed ?? UInt64.random(in: .min ... .max))
        commandQueue = queue
        surfaceBufferGenerations = Array(repeating: -1, count: Self.maxFramesInFlight)

        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            spritePipeline = try Self.makePipeline(device, library, pixelFormat, vertex: "spriteVertex", fragment: "spriteFragment")
            surfacePipeline = try Self.makePipeline(device, library, pixelFormat, vertex: "surfaceVertex", fragment: "surfaceFragment")
        } catch {
            NSLog("SnowPile: Metal pipeline failed: \(error)")
            return nil
        }

        let length = MemoryLayout<Sprite>.stride * (simulation.flakes.count + Self.extraSprites)
        var buffers: [MTLBuffer] = []
        for _ in 0..<Self.maxFramesInFlight {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            buffers.append(buffer)
        }
        instanceBuffers = buffers
        debugLabel = nil
        super.init()
    }

    private static func makePipeline(
        _ device: MTLDevice, _ library: MTLLibrary, _ pixelFormat: MTLPixelFormat, vertex: String, fragment: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        // Premultiplied alpha, matching the transparent window.
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        advance(to: CACurrentMediaTime())

        inFlight.wait()
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else {
            inFlight.signal()
            return
        }
        encode(encoder, viewSize: SIMD2(Float(view.bounds.width), Float(view.bounds.height)))
        encoder.endEncoding()

        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Steps the simulation to `now` (seconds on any monotonic clock) and refreshes the surface mesh.
    func advance(to now: CFTimeInterval) {
        let dt = lastFrameTime.map { now - $0 } ?? 0
        lastFrameTime = now
        simulation.step(dt: dt)
        rebuildMeshIfNeeded(now: now)
        updateDebugLabel(dt: dt)
    }

    /// Renders the current state into `texture` and waits for the GPU. Only for snapshot mode.
    func renderOffscreen(into texture: MTLTexture, viewSize: CGSize) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encode(encoder, viewSize: SIMD2(Float(viewSize.width), Float(viewSize.height)))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func encode(_ encoder: MTLRenderCommandEncoder, viewSize: SIMD2<Float>) {
        let index = frameIndex
        frameIndex = (frameIndex + 1) % Self.maxFramesInFlight
        var viewSize = viewSize
        let viewSizeLength = MemoryLayout<SIMD2<Float>>.stride

        if let surfaceBuffer = surfaceBuffer(for: index) {
            encoder.setRenderPipelineState(surfacePipeline)
            encoder.setVertexBuffer(surfaceBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewSize, length: viewSizeLength, index: 1)
            for range in meshRanges {
                for strip in 0..<SurfaceMesh.stripCount {
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: range.start + strip * range.stripLength, vertexCount: range.stripLength)
                }
                if debug {
                    encoder.drawPrimitives(type: .line, vertexStart: range.debugStart, vertexCount: 2)
                }
            }
        }

        let buffer = instanceBuffers[index]
        let capacity = buffer.length / MemoryLayout<Sprite>.stride
        let pointer = buffer.contents().bindMemory(to: Sprite.self, capacity: capacity)
        var writer = SpriteWriter(buffer: UnsafeMutableBufferPointer(start: pointer, count: capacity), screenFrameCG: screenFrameCG)
        SceneSprites.write(simulation, into: &writer)
        FlakeSprites.pack(simulation.flakes, into: &writer)
        if writer.count > 0 {
            encoder.setRenderPipelineState(spritePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewSize, length: viewSizeLength, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: writer.count)
        }
    }

    private func rebuildMeshIfNeeded(now: CFTimeInterval) {
        let surfaces = simulation.surfaces
        // Moved or new surfaces are rebuilt right away so the snow sticks to a dragged window;
        // snow piling up only needs the 20 Hz rate.
        let isMoving = surfaces.contains { predictedOffset(for: $0, now: now) != .zero }
        let layoutChanged = isMoving || meshWasPredicted || meshSources.count != surfaces.count || surfaces.indices.contains {
            surfaces[$0].id != meshSources[$0].x || surfaces[$0].geometryVersion != meshSources[$0].y
        }
        guard layoutChanged || now - lastMeshBuild >= Self.meshRebuildInterval else { return }
        guard layoutChanged || surfaces.indices.contains(where: { surfaces[$0].version != meshSources[$0].z }) else { return }
        lastMeshBuild = now
        meshWasPredicted = isMoving

        let debugVertices = debug ? 2 : 0
        let needed = surfaces.reduce(0) { $0 + SurfaceMesh.vertexCount(for: $1) + debugVertices }
        if mesh.count < needed {
            mesh = ContiguousArray(repeating: SurfaceVertex(), count: needed)
        }

        meshRanges.removeAll(keepingCapacity: true)
        meshSources.removeAll(keepingCapacity: true)
        var offset = 0
        mesh.withUnsafeMutableBufferPointer { out in
            for surface in surfaces {
                let count = SurfaceMesh.vertexCount(for: surface)
                let predicted = predictedOffset(for: surface, now: now)
                SurfaceMesh.build(
                    surface, screenFrameCG: screenFrameCG, offset: predicted,
                    into: UnsafeMutableBufferPointer(rebasing: out[offset..<(offset + count)])
                )
                var range = SurfaceRange(start: offset, stripLength: SurfaceMesh.stripLength(for: surface), debugStart: -1)
                offset += count
                if debug {
                    let red = SIMD4<Float>(1, 0, 0, 1)
                    let y = surface.baseY + predicted.dy
                    let start = Coordinates.sceneLocal(CGPoint(x: surface.minX + predicted.dx, y: y), screenFrameCG: screenFrameCG)
                    let end = Coordinates.sceneLocal(CGPoint(x: surface.maxX + predicted.dx, y: y), screenFrameCG: screenFrameCG)
                    // Half a point above the edge so the line at the screen bottom stays visible.
                    out[offset].position = SIMD2(Float(start.x), Float(start.y) + 0.5)
                    out[offset].color = red
                    out[offset + 1].position = SIMD2(Float(end.x), Float(end.y) + 0.5)
                    out[offset + 1].color = red
                    range.debugStart = offset
                    offset += 2
                }
                meshRanges.append(range)
                meshSources.append(SIMD3(surface.id, surface.geometryVersion, surface.version))
            }
        }
        meshGeneration &+= 1
    }

    /// Returns the frame's surface buffer, refreshed from the CPU mesh if it holds an older generation.
    private func surfaceBuffer(for index: Int) -> MTLBuffer? {
        guard !meshRanges.isEmpty else { return nil }
        let length = mesh.count * MemoryLayout<SurfaceVertex>.stride
        if surfaceBuffers.count != Self.maxFramesInFlight || surfaceBuffers[0].length < length {
            // Only happens when the set of surfaces grows, never in steady state.
            surfaceBuffers = (0..<Self.maxFramesInFlight).compactMap { _ in
                device.makeBuffer(length: length, options: .storageModeShared)
            }
            guard surfaceBuffers.count == Self.maxFramesInFlight else { return nil }
            surfaceBufferGenerations = Array(repeating: -1, count: Self.maxFramesInFlight)
        }
        let buffer = surfaceBuffers[index]
        if surfaceBufferGenerations[index] != meshGeneration {
            mesh.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
            surfaceBufferGenerations[index] = meshGeneration
        }
        return buffer
    }

    /// Window positions arrive with a delay and the frame shows even later. Moving window surfaces are drawn
    /// where the window will be by then, extrapolated from its measured velocity.
    private func predictedOffset(for surface: Surface, now: CFTimeInterval) -> CGVector {
        guard case .window(let number) = surface.kind,
              let motion = simulation.motion(ofWindow: number), motion.velocity != .zero else { return .zero }
        let horizon = CGFloat(min(max(now - motion.timestamp + Self.displayLatency, 0), Self.maxPrediction))
        return CGVector(dx: motion.velocity.dx * horizon, dy: motion.velocity.dy * horizon)
    }

    func setWindows(_ windows: [WindowInfo], timestamp: CFTimeInterval) {
        simulation.setWindows(windows, timestamp: timestamp)
    }

    /// One line of numbers for the snapshot log: flakes, powder, and snow height per surface.
    func statsLine() -> String {
        var parts = ["Flocken \(simulation.snowfallCount)", "Pulver \(simulation.activeCount - simulation.snowfallCount)"]
        for surface in simulation.surfaces {
            let heights = surface.heights
            let maxHeight = heights.max() ?? 0
            let mean = heights.isEmpty ? 0 : heights.reduce(0, +) / CGFloat(heights.count)
            let name: String
            switch surface.kind {
            case .ground: name = "Boden"
            case .window(let number): name = "Fenster \(number)"
            }
            parts.append(String(format: "%@ x %.0f–%.0f: max %.1f / Ø %.1f pt", name, surface.minX, surface.maxX, maxHeight, mean))
        }
        return parts.joined(separator: " · ")
    }

    private func updateDebugLabel(dt: CFTimeInterval) {
        guard let debugLabel else { return }
        debugFrames += 1
        debugElapsed += dt
        guard debugElapsed >= 0.5 else { return }
        let fps = Double(debugFrames) / debugElapsed
        var groundMax: CGFloat = 0
        var windowSurfaces = 0
        for surface in simulation.surfaces {
            if case .ground = surface.kind { groundMax = surface.heights.max() ?? 0 } else { windowSurfaces += 1 }
        }
        debugLabel.stringValue = String(
            format: "%.0f FPS · Flocken: %d/%d · Pulver: %d · Boden max: %.1f pt · Fensterkanten: %d",
            fps, simulation.snowfallCount, simulation.config.maxFlakes,
            simulation.activeCount - simulation.snowfallCount, groundMax, windowSurfaces
        )
        debugFrames = 0
        debugElapsed = 0
    }
}
