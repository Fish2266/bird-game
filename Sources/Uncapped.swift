import AppKit
import SceneKit
import QuartzCore

/// V-Sync off: draws the game on its own thread as fast as the Mac can and shows each frame the moment it's done,
/// instead of SceneKit's view (which always waits for the screen, so it can't go past the screen's refresh rate).
/// It sits over the game view; clicks and keys still go to the game underneath.
final class UncappedView: NSView {
    /// Draws the scene; its delegate (the app) updates the game every frame, like SceneKit's view does.
    let renderer: SCNRenderer
    private let metalLayer = CAMetalLayer()
    private let commandQueue: MTLCommandQueue
    /// The game's clock (the same one SceneKit's view uses, so time doesn't jump when switching).
    private let clock: () -> TimeInterval

    // Shared with the render thread (under `lock`).
    private let lock = NSLock()
    private var running = false
    private var samples = 4
    private var visible = true
    /// While the menu is open there's nothing to gain from going flat out: 60 fps then.
    private var paced = false
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    // Render thread only.
    private var msaa: MTLTexture?
    private var depth: MTLTexture?

    init?(device: MTLDevice, delegate: SCNSceneRendererDelegate, clock: @escaping () -> TimeInterval) {
        guard let q = device.makeCommandQueue() else { return nil }
        commandQueue = q
        self.clock = clock
        renderer = SCNRenderer(device: device, options: nil)
        renderer.delegate = delegate
        super.init(frame: .zero)
        metalLayer.device = device
        // What SceneKit's own view draws into, so the picture looks exactly the same.
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.displaySyncEnabled = false
        metalLayer.maximumDrawableCount = 3
        layer = metalLayer
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func layout() { super.layout(); updateSize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateSize() }
    private func updateSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
    }

    func set(scene: SCNScene?, camera: SCNNode?) {
        lock.lock(); renderer.scene = scene; renderer.pointOfView = camera; lock.unlock()
    }
    func set(samples n: Int) { lock.lock(); samples = n; lock.unlock() }
    func set(visible v: Bool, paced p: Bool) { lock.lock(); visible = v; paced = p; lock.unlock() }

    func start() {
        guard thread == nil else { return }
        updateSize()
        lock.lock(); running = true; lock.unlock()
        let t = Thread { [unowned self] in self.loop() }
        t.name = "bird.uncapped"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stop drawing and wait for the last frame, so SceneKit's view can take over without both drawing at once.
    func stop() {
        guard thread != nil else { return }
        lock.lock(); running = false; lock.unlock()
        finished.wait()
        thread = nil
    }

    private func loop() {
        // When paced, frames follow a fixed 60-a-second schedule (sleeping only rounds up, so aiming at the next
        // slot rather than "1/60 s after the last frame" keeps it at 60 instead of drifting lower).
        var next = CACurrentMediaTime()
        while true {
            lock.lock()
            let go = running, n = samples, show = visible, pace = paced
            lock.unlock()
            guard go else { break }
            if !show { Thread.sleep(forTimeInterval: 0.05); continue }
            let now = CACurrentMediaTime()
            if pace {
                if next > now { Thread.sleep(forTimeInterval: next - now) }
                next = max(next + 1.0 / 60, CACurrentMediaTime() - 1.0 / 60)
            } else {
                next = now
            }
            autoreleasepool { frame(samples: n) }
        }
        finished.signal()
    }

    private func frame(samples n: Int) {
        guard let drawable = metalLayer.nextDrawable(), let cb = commandQueue.makeCommandBuffer() else { return }
        let w = drawable.texture.width, h = drawable.texture.height
        makeTargets(w, h, n)
        let pass = MTLRenderPassDescriptor()
        if n > 1, let msaa {
            pass.colorAttachments[0].texture = msaa
            pass.colorAttachments[0].resolveTexture = drawable.texture
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = renderer.usesReverseZ ? 0 : 1
        pass.stencilAttachment.texture = depth
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare
        lock.lock()
        renderer.render(atTime: clock(), viewport: CGRect(x: 0, y: 0, width: w, height: h), commandBuffer: cb, passDescriptor: pass)
        lock.unlock()
        cb.present(drawable)
        cb.commit()
    }

    /// Antialiasing and depth buffers the size of the screen's drawable (remade when that or the antialiasing changes).
    private func makeTargets(_ w: Int, _ h: Int, _ n: Int) {
        if let d = depth, d.width == w, d.height == h, d.sampleCount == n { return }
        func texture(_ f: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            d.textureType = n > 1 ? .type2DMultisample : .type2D
            d.sampleCount = n
            d.usage = .renderTarget
            d.storageMode = .private
            return metalLayer.device?.makeTexture(descriptor: d)
        }
        msaa = n > 1 ? texture(.bgra8Unorm_srgb) : nil
        depth = texture(.depth32Float_stencil8)
    }
}

extension GraphicsQuality {
    /// Antialiasing samples per pixel (matches `antialiasing`).
    var samples: Int { [1, 2, 4][rawValue] }
}
