import SceneKit
import simd

/// Low-poly WWI biplane. Local space: forward = -Z, up = +Y. About 7 m wingspan.
final class BiplaneNode {
    let node = SCNNode()
    private let prop = SCNNode()

    struct Livery {
        var body: NSColor
        var wing: NSColor
        var trim: NSColor
        var roundels: Bool
    }

    static let liveries: [Livery] = [
        Livery(body: NSColor(srgbRed: 0.72, green: 0.12, blue: 0.10, alpha: 1), wing: NSColor(srgbRed: 0.78, green: 0.16, blue: 0.12, alpha: 1),
               trim: NSColor(white: 0.95, alpha: 1), roundels: false),
        Livery(body: NSColor(srgbRed: 0.42, green: 0.42, blue: 0.24, alpha: 1), wing: NSColor(srgbRed: 0.80, green: 0.76, blue: 0.62, alpha: 1),
               trim: NSColor(srgbRed: 0.20, green: 0.25, blue: 0.55, alpha: 1), roundels: true),
        Livery(body: NSColor(srgbRed: 0.40, green: 0.46, blue: 0.54, alpha: 1), wing: NSColor(srgbRed: 0.62, green: 0.66, blue: 0.70, alpha: 1),
               trim: NSColor(srgbRed: 0.95, green: 0.80, blue: 0.20, alpha: 1), roundels: false),
    ]

    init(livery: Livery) {
        func mat(_ c: NSColor, rough: CGFloat = 0.7) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = c
            m.roughness.contents = rough
            return m
        }
        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, _ p: SCNVector3, chamfer: CGFloat = 0.05) -> SCNNode {
            let g = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.position = p
            node.addChildNode(n)
            return n
        }
        let body = mat(livery.body), wing = mat(livery.wing), trim = mat(livery.trim)
        let dark = mat(NSColor(white: 0.12, alpha: 1)), wood = mat(NSColor(srgbRed: 0.45, green: 0.30, blue: 0.18, alpha: 1))

        // Fuselage (tapering tail boom) and engine cowling
        box(0.95, 1.0, 3.2, body, SCNVector3(0, 0, -0.4), chamfer: 0.18)
        let boom = box(0.7, 0.7, 2.6, body, SCNVector3(0, 0.1, 2.4), chamfer: 0.12)
        boom.scale = SCNVector3(0.8, 0.8, 1)
        let cowl = SCNNode(geometry: SCNCylinder(radius: 0.55, height: 0.6))
        cowl.geometry?.materials = [dark]
        cowl.eulerAngles.x = .pi / 2
        cowl.position = SCNVector3(0, 0, -2.2)
        node.addChildNode(cowl)
        // Pilot
        let head = SCNNode(geometry: SCNSphere(radius: 0.26))
        head.geometry?.materials = [mat(NSColor(srgbRed: 0.45, green: 0.32, blue: 0.22, alpha: 1))]
        head.position = SCNVector3(0, 0.72, 0.2)
        node.addChildNode(head)
        // Wings + struts
        box(7.2, 0.12, 1.4, wing, SCNVector3(0, 1.25, -0.7))
        box(6.4, 0.12, 1.3, wing, SCNVector3(0, -0.45, -0.6))
        for x: CGFloat in [-2.6, -1.0, 1.0, 2.6] {
            box(0.07, 1.65, 0.07, wood, SCNVector3(x, 0.4, -0.7), chamfer: 0)
        }
        if livery.roundels {
            for x: CGFloat in [-2.6, 2.6] {
                for (r, c) in [(0.45, NSColor(srgbRed: 0.20, green: 0.28, blue: 0.62, alpha: 1)), (0.3, NSColor.white),
                               (0.15, NSColor(srgbRed: 0.78, green: 0.14, blue: 0.12, alpha: 1))] {
                    let d = SCNNode(geometry: SCNCylinder(radius: CGFloat(r), height: 0.02))
                    d.geometry?.materials = [mat(c)]
                    d.position = SCNVector3(x, 1.32 + CGFloat(0.45 - r) * 0.02, -0.7)
                    node.addChildNode(d)
                }
            }
        } else {
            box(7.25, 0.13, 0.25, trim, SCNVector3(0, 1.26, -1.25))
        }
        // Tail
        box(2.6, 0.08, 0.9, wing, SCNVector3(0, 0.15, 3.5))
        box(0.08, 1.1, 0.9, trim, SCNVector3(0, 0.65, 3.5))
        // Landing gear
        for x: CGFloat in [-0.7, 0.7] {
            box(0.06, 0.8, 0.06, wood, SCNVector3(x, -0.8, -1.1), chamfer: 0)
            let w = SCNNode(geometry: SCNCylinder(radius: 0.32, height: 0.14))
            w.geometry?.materials = [dark]
            w.eulerAngles.z = .pi / 2
            w.position = SCNVector3(x, -1.2, -1.1)
            node.addChildNode(w)
        }
        // Propeller
        prop.position = SCNVector3(0, 0, -2.55)
        let blade = SCNNode(geometry: SCNBox(width: 0.18, height: 2.4, length: 0.06, chamferRadius: 0.05))
        blade.geometry?.materials = [wood]
        prop.addChildNode(blade)
        node.addChildNode(prop)
        prop.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: .pi * 2, duration: 0.06)))
        node.enumerateHierarchy { n, _ in n.castsShadow = true }
    }
}
