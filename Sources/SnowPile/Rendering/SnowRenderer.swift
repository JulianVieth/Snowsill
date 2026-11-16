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

    private struct SurfaceRange {
        var bodyStart: Int
        var bodyCount: Int
        var debugStart: Int
    }

    private let screenFrameCG: CGRect
    private let debug: Bool
    private var simulation: SnowSimulation
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let flakePipeline: MTLRenderPipelineState
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
    private var surfaceBuffers: [MTLBuffer] = []
    private var surfaceBufferGenerations: [Int]

    private let debugLabel: NSTextField?
    private var debugFrames = 0
    private var debugElapsed: CFTimeInterval = 0

    init?(view: MTKView, screenFrameCG: CGRect, debug: Bool) {
        guard let device = view.device, let queue = device.makeCommandQueue() else { return nil }
        self.screenFrameCG = screenFrameCG
        self.debug = debug
        self.device = device
        simulation = SnowSimulation(bounds: screenFrameCG)
        commandQueue = queue
        surfaceBufferGenerations = Array(repeating: -1, count: Self.maxFramesInFlight)

        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            flakePipeline = try Self.makePipeline(device, library, view, vertex: "flakeVertex", fragment: "flakeFragment")
            surfacePipeline = try Self.makePipeline(device, library, view, vertex: "surfaceVertex", fragment: "surfaceFragment")
        } catch {
            NSLog("SnowPile: Metal pipeline failed: \(error)")
            return nil
        }

        let length = MemoryLayout<FlakeInstance>.stride * max(simulation.flakes.count, 1)
        var buffers: [MTLBuffer] = []
        for _ in 0..<Self.maxFramesInFlight {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            buffers.append(buffer)
        }
        instanceBuffers = buffers

        if debug {
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.textColor = .systemRed
            label.frame = NSRect(x: 12, y: 60, width: 760, height: 20)
            view.addSubview(label)
            debugLabel = label
        } else {
            debugLabel = nil
        }
        super.init()
    }

    private static func makePipeline(
        _ device: MTLDevice, _ library: MTLLibrary, _ view: MTKView, vertex: String, fragment: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = view.colorPixelFormat
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
        let now = CACurrentMediaTime()
        let dt = lastFrameTime.map { now - $0 } ?? 0
        lastFrameTime = now
        simulation.step(dt: dt)
        rebuildMeshIfNeeded(now: now)
        updateDebugLabel(dt: dt)

        inFlight.wait()
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else {
            inFlight.signal()
            return
        }
        let index = frameIndex
        frameIndex = (frameIndex + 1) % Self.maxFramesInFlight
        var viewSize = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
        let viewSizeLength = MemoryLayout<SIMD2<Float>>.stride

        if let surfaceBuffer = surfaceBuffer(for: index) {
            encoder.setRenderPipelineState(surfacePipeline)
            encoder.setVertexBuffer(surfaceBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewSize, length: viewSizeLength, index: 1)
            for range in meshRanges {
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: range.bodyStart, vertexCount: range.bodyCount)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: range.bodyStart + range.bodyCount, vertexCount: range.bodyCount)
                if debug {
                    encoder.drawPrimitives(type: .line, vertexStart: range.debugStart, vertexCount: 2)
                }
            }
        }

        let buffer = instanceBuffers[index]
        let capacity = buffer.length / MemoryLayout<FlakeInstance>.stride
        let pointer = buffer.contents().bindMemory(to: FlakeInstance.self, capacity: capacity)
        let count = FlakeInstances.pack(
            simulation.flakes,
            screenFrameCG: screenFrameCG,
            into: UnsafeMutableBufferPointer(start: pointer, count: capacity)
        )
        if count > 0 {
            encoder.setRenderPipelineState(flakePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewSize, length: viewSizeLength, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        encoder.endEncoding()

        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func rebuildMeshIfNeeded(now: CFTimeInterval) {
        let surfaces = simulation.surfaces
        // Moved or new surfaces are rebuilt right away so the snow sticks to a dragged window;
        // snow piling up only needs the 20 Hz rate.
        let layoutChanged = meshSources.count != surfaces.count || surfaces.indices.contains {
            surfaces[$0].id != meshSources[$0].x || surfaces[$0].geometryVersion != meshSources[$0].y
        }
        guard layoutChanged || now - lastMeshBuild >= Self.meshRebuildInterval else { return }
        guard layoutChanged || surfaces.indices.contains(where: { surfaces[$0].version != meshSources[$0].z }) else { return }
        lastMeshBuild = now

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
                SurfaceMesh.build(surface, screenFrameCG: screenFrameCG, into: UnsafeMutableBufferPointer(rebasing: out[offset..<(offset + count)]))
                var range = SurfaceRange(bodyStart: offset, bodyCount: count / 2, debugStart: -1)
                offset += count
                if debug {
                    let red = SIMD4<Float>(1, 0, 0, 1)
                    let start = Coordinates.sceneLocal(CGPoint(x: surface.minX, y: surface.baseY), screenFrameCG: screenFrameCG)
                    let end = Coordinates.sceneLocal(CGPoint(x: surface.maxX, y: surface.baseY), screenFrameCG: screenFrameCG)
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

    func setWindows(_ windows: [WindowInfo], timestamp: CFTimeInterval) {
        simulation.setWindows(windows, timestamp: timestamp)
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
            format: "%.0f FPS · Flocken: %d/%d · Boden max: %.1f pt · Fensterkanten: %d",
            fps, simulation.activeCount, simulation.flakes.count, groundMax, windowSurfaces
        )
        debugFrames = 0
        debugElapsed = 0
    }
}
