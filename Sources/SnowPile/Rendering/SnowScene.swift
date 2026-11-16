import SnowPileCore
import SpriteKit

final class SnowScene: SKScene {
    private static let textureRadius: CGFloat = 16

    private let screenFrameCG: CGRect
    private var simulation: SnowSimulation
    private var flakeNodes: [SKSpriteNode] = []
    private var lastUpdate: TimeInterval?

    private let debugLabel: SKLabelNode?
    private var debugLabelAge: TimeInterval = 0

    init(screenFrameCG: CGRect, debug: Bool) {
        self.screenFrameCG = screenFrameCG
        simulation = SnowSimulation(bounds: screenFrameCG)
        debugLabel = debug ? SKLabelNode(fontNamed: "Menlo") : nil
        super.init(size: screenFrameCG.size)

        backgroundColor = .clear
        scaleMode = .resizeFill
        anchorPoint = .zero

        let texture = Self.makeFlakeTexture()
        flakeNodes.reserveCapacity(simulation.flakes.count)
        for _ in simulation.flakes.indices {
            let node = SKSpriteNode(texture: texture)
            node.isHidden = true
            node.blendMode = .alpha
            addChild(node)
            flakeNodes.append(node)
        }

        if let debugLabel {
            debugLabel.fontSize = 13
            debugLabel.fontColor = .red
            debugLabel.horizontalAlignmentMode = .left
            debugLabel.verticalAlignmentMode = .bottom
            debugLabel.position = CGPoint(x: 12, y: 40)
            debugLabel.zPosition = 1000
            addChild(debugLabel)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdate.map { currentTime - $0 } ?? 0
        lastUpdate = currentTime
        simulation.step(dt: dt)

        simulation.flakes.withUnsafeBufferPointer { flakes in
            for i in flakes.indices {
                let flake = flakes[i]
                let node = flakeNodes[i]
                guard flake.isActive else {
                    if !node.isHidden { node.isHidden = true }
                    continue
                }
                // A slot is always hidden for at least one frame between two flakes, so hidden + active means freshly spawned.
                // Setting SpriteKit properties is expensive, so radius and opacity are only applied then.
                if node.isHidden {
                    node.isHidden = false
                    node.setScale(flake.radius / Self.textureRadius)
                    node.alpha = flake.opacity
                }
                node.position = Coordinates.sceneLocal(flake.position, screenFrameCG: screenFrameCG)
            }
        }

        if let debugLabel {
            debugLabelAge += dt
            if debugLabelAge > 0.25 {
                debugLabelAge = 0
                debugLabel.text = "Flocken: \(simulation.activeCount)/\(simulation.flakes.count)"
            }
        }
    }

    /// Soft white disc with a faint bluish rim so flakes stay visible on white windows.
    private static func makeFlakeTexture() -> SKTexture {
        let size = Int(textureRadius * 2)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SKTexture() }

        let colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 0.85),
            CGColor(red: 0.75, green: 0.82, blue: 0.95, alpha: 0),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.55, 1]) else {
            return SKTexture()
        }
        let center = CGPoint(x: textureRadius, y: textureRadius)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: textureRadius, options: [])
        guard let image = context.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: image)
    }
}
