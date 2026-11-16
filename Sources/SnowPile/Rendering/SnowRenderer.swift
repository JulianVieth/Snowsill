import AppKit
import MetalKit
import QuartzCore
import SnowPileCore

/// Drives the frame loop of one overlay: steps the simulation and draws all flakes in one instanced draw call.
@MainActor
final class SnowRenderer: NSObject, MTKViewDelegate {
    private static let maxFramesInFlight = 3

    private let screenFrameCG: CGRect
    private var simulation: SnowSimulation
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let instanceBuffers: [MTLBuffer]
    private let inFlight = DispatchSemaphore(value: SnowRenderer.maxFramesInFlight)
    private var bufferIndex = 0
    private var lastFrameTime: CFTimeInterval?

    private let debugLabel: NSTextField?
    private var debugFrames = 0
    private var debugElapsed: CFTimeInterval = 0

    init?(view: MTKView, screenFrameCG: CGRect, debug: Bool) {
        guard let device = view.device, let queue = device.makeCommandQueue() else { return nil }
        self.screenFrameCG = screenFrameCG
        simulation = SnowSimulation(bounds: screenFrameCG)
        commandQueue = queue

        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "flakeVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "flakeFragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = view.colorPixelFormat
            // Premultiplied alpha, matching the transparent window.
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
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
            label.frame = NSRect(x: 12, y: 40, width: 400, height: 20)
            view.addSubview(label)
            debugLabel = label
        } else {
            debugLabel = nil
        }
        super.init()
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

        let buffer = instanceBuffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % Self.maxFramesInFlight
        let capacity = buffer.length / MemoryLayout<FlakeInstance>.stride
        let pointer = buffer.contents().bindMemory(to: FlakeInstance.self, capacity: capacity)
        let count = FlakeInstances.pack(
            simulation.flakes,
            screenFrameCG: screenFrameCG,
            into: UnsafeMutableBufferPointer(start: pointer, count: capacity)
        )

        if count > 0 {
            var viewSize = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        encoder.endEncoding()

        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateDebugLabel(dt: CFTimeInterval) {
        guard let debugLabel else { return }
        debugFrames += 1
        debugElapsed += dt
        guard debugElapsed >= 0.5 else { return }
        let fps = Double(debugFrames) / debugElapsed
        debugLabel.stringValue = String(format: "%.0f FPS · Flocken: %d/%d", fps, simulation.activeCount, simulation.flakes.count)
        debugFrames = 0
        debugElapsed = 0
    }
}
