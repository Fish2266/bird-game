import SceneKit

/// How hard the renderer works. Automatic by default: High on Apple silicon, Balanced on Intel Macs, and a step lower
/// whenever flying stays choppy for a while (remembered). The Game menu can pin a level instead.
enum GraphicsQuality: Int, CaseIterable {
    case low, balanced, high

    var title: String { ["Low", "Balanced", "High"][rawValue] }
    var antialiasing: SCNAntialiasingMode { [.none, .multisampling2X, .multisampling4X][rawValue] }
    var shadows: Bool { self != .low }
    var shadowMapSize: CGFloat { self == .high ? 2048 : 1024 }
    var shadowSamples: Int { self == .high ? 8 : 2 }
    var shadowCascades: Int { self == .high ? 3 : 2 }
    var bloom: CGFloat { [0, 0.4, 0.5][rawValue] }

    /// Chosen in the menu (nil = automatic).
    static var pinned: GraphicsQuality? {
        get { (UserDefaults.standard.object(forKey: "graphics.quality") as? Int).flatMap(GraphicsQuality.init(rawValue:)) }
        set {
            if let q = newValue { UserDefaults.standard.set(q.rawValue, forKey: "graphics.quality") }
            else { UserDefaults.standard.removeObject(forKey: "graphics.quality") }
        }
    }

    /// The automatic level: what this Mac starts at, lowered after slow stretches.
    static var automatic: GraphicsQuality {
        get { (UserDefaults.standard.object(forKey: "graphics.auto") as? Int).flatMap(GraphicsQuality.init(rawValue:)) ?? hardwareDefault }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "graphics.auto") }
    }

    static var hardwareDefault: GraphicsQuality {
        #if arch(arm64)
        return .high
        #else
        return .balanced
        #endif
    }

    static var current: GraphicsQuality { pinned ?? automatic }
}

extension Game {
    /// Shadows and bloom for a quality level (the view's antialiasing is set by the app).
    func apply(_ q: GraphicsQuality) {
        enqueue { g in
            if let light = g.sun.light {
                light.castsShadow = g.visuals.shadows && q.shadows
                light.shadowMapSize = CGSize(width: q.shadowMapSize, height: q.shadowMapSize)
                light.shadowSampleCount = q.shadowSamples
                light.shadowCascadeCount = q.shadowCascades
            }
            g.cameraNode.camera?.bloomIntensity = q.bloom
        }
    }
}
