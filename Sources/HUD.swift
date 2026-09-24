import AppKit
import AVFoundation
import QuartzCore

/// Mirrored camera feed in a rounded frame, with the tracked skeleton drawn on top.
final class CameraPreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let clip = NSView()
    private let bones = CAShapeLayer()
    private let arms = CAShapeLayer()
    private let dots = CAShapeLayer()
    private let calib = CAShapeLayer()
    private let frameView = WiiFrame()
    let caption = WiiLabel(12, color: .white)
    var aspectForLayout: Float = 4.0 / 3.0

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(clip)
        previewLayer.videoGravity = .resizeAspectFill
        clip.layer?.addSublayer(previewLayer)
        for (l, c, w) in [(bones, NSColor.white.withAlphaComponent(0.7), 3.0), (arms, Wii.blue, 6.0)] {
            l.strokeColor = c.cgColor
            l.fillColor = nil
            l.lineWidth = w
            l.lineCap = .round
            l.lineJoin = .round
            clip.layer?.addSublayer(l)
        }
        dots.fillColor = NSColor.white.cgColor
        clip.layer?.addSublayer(dots)
        calib.fillColor = nil
        calib.strokeColor = Wii.blue.cgColor
        calib.lineWidth = 8
        calib.lineCap = .round
        clip.layer?.addSublayer(calib)
        addSubview(frameView)
        caption.align = .center
        caption.wantsLayer = true
        caption.layer?.shadowColor = NSColor.black.cgColor
        caption.layer?.shadowOpacity = 0.6
        caption.layer?.shadowRadius = 2
        caption.layer?.shadowOffset = .zero
        addSubview(caption)
    }
    required init?(coder: NSCoder) { fatalError() }

    func mirror() {
        if let conn = previewLayer.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer.frame = clip.bounds
        for l in [bones, arms, dots, calib] { l.frame = clip.bounds }
        CATransaction.commit()
        frameView.frame = bounds
        caption.frame = NSRect(x: 10, y: 8, width: bounds.width - 20, height: 18)
    }

    func update(pose: RawPose?, control: ControlState) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let w = bounds.width, h = bounds.height
        guard let pose, control.tracking else {
            bones.path = nil; arms.path = nil; dots.path = nil; calib.path = nil
            return
        }
        func pt(_ j: Joint) -> CGPoint? {
            let p = pose[j]
            guard p.z > 0.2 else { return nil }
            return CGPoint(x: CGFloat(1 - p.x) * w, y: CGFloat(p.y) * h)
        }
        let body = CGMutablePath(), armPath = CGMutablePath(), dotPath = CGMutablePath()
        func seg(_ path: CGMutablePath, _ a: Joint, _ b: Joint) {
            if let p = pt(a), let q = pt(b) { path.move(to: p); path.addLine(to: q) }
        }
        seg(body, .lShoulder, .rShoulder); seg(body, .neck, .nose)
        seg(body, .lShoulder, .lHip); seg(body, .rShoulder, .rHip); seg(body, .lHip, .rHip)
        seg(armPath, .lShoulder, .lElbow); seg(armPath, .lElbow, .lWrist)
        seg(armPath, .rShoulder, .rElbow); seg(armPath, .rElbow, .rWrist)
        for j in Joint.allCases { if let p = pt(j) { dotPath.addEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)) } }
        bones.path = body; arms.path = armPath; dots.path = dotPath

        if !control.calibrated && control.calibProgress > 0.01 {
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: w / 2, y: h / 2), radius: min(w, h) * 0.22, startAngle: .pi / 2,
                        endAngle: .pi / 2 - CGFloat(control.calibProgress) * 2 * .pi, clockwise: true)
            calib.path = path
        } else {
            calib.path = nil
        }
    }
}

/// Small dial: a line for the wings (bank / pitch) and a bar for flap power.
final class ControlGaugeView: FlippedView {
    var input = FlightInput() { didSet { needsDisplay = true } }
    var active = false

    override func draw(_ dirtyRect: NSRect) {
        let panel = bounds.insetBy(dx: 4, dy: 4)
        Wii.glossy(panel, radius: 12, rim: Wii.border, rimWidth: 2, maxGlass: 30)
        let d: CGFloat = panel.height - 44
        let dial = NSRect(x: panel.minX + 14, y: panel.minY + 12, width: d, height: d)
        let dp = NSBezierPath(ovalIn: dial)
        Wii.tileLow.setFill(); dp.fill()
        dp.lineWidth = 1.5; Wii.border.setStroke(); dp.stroke()
        let hz = NSBezierPath()
        hz.move(to: NSPoint(x: dial.minX + 6, y: dial.midY)); hz.line(to: NSPoint(x: dial.maxX - 6, y: dial.midY))
        hz.lineWidth = 1; Wii.border.setStroke(); hz.stroke()

        let c = NSPoint(x: dial.midX, y: dial.midY - CGFloat(input.pitch) * d * 0.2)
        let span = d * 0.38 * CGFloat(1 - input.tuck * 0.6)
        let a = CGFloat(input.roll) * 0.8
        let wing = NSBezierPath()
        wing.move(to: NSPoint(x: c.x - span * cos(a), y: c.y - span * sin(a)))
        wing.line(to: NSPoint(x: c.x + span * cos(a), y: c.y + span * sin(a)))
        wing.lineWidth = 4; wing.lineCapStyle = .round
        (active ? Wii.blue : Wii.border).setStroke(); wing.stroke()
        Wii.text.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)).fill()

        let bar = NSRect(x: dial.maxX + 14, y: dial.minY, width: 10, height: d)
        // Recessed track with a thin dark outline so it reads against the glossy panel.
        let track = NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5)
        NSGradient(starting: NSColor(white: 0.82, alpha: 1), ending: NSColor(white: 0.95, alpha: 1))?.draw(in: track, angle: 90)
        let f = CGFloat(min((input.flapL + input.flapR) * 0.5 / 1.2, 1))
        if f > 0.02 {
            let fill = NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.maxY - bar.height * f, width: bar.width, height: bar.height * f),
                                    xRadius: 5, yRadius: 5)
            NSGradient(starting: Wii.blueLight, ending: Wii.blue)?.draw(in: fill, angle: 90)
            fill.lineWidth = 1
            NSColor(srgbRed: 0.05, green: 0.40, blue: 0.58, alpha: 0.7).setStroke(); fill.stroke()
        }
        track.lineWidth = 1.2
        Wii.text.withAlphaComponent(0.45).setStroke(); track.stroke()
        Wii.drawText(input.tuck > 0.5 ? "Dive" : "Wings", in: NSRect(x: dial.minX, y: dial.maxY + 6, width: d, height: 18),
                     size: 11, color: Wii.textSoft, align: .center)
        Wii.drawText("Flap", in: NSRect(x: bar.midX - 20, y: dial.maxY + 6, width: 40, height: 18), size: 11,
                     color: Wii.textSoft, align: .center)
    }
}

final class HUDView: NSView {
    private let statsBox = WiiPanel()
    private let speed = WiiLabel(34, bold: true)
    private let speedUnit = WiiLabel(13, color: Wii.textSoft)
    private let details = WiiLabel(13, color: Wii.textSoft)
    private let coins = WiiLabel(17, bold: true)
    private let hintBox = WiiPanel()
    private let hint = WiiLabel(17)
    private let ring = WiiLabel(13, color: .white)
    private let arrow = CAShapeLayer()
    private let arrowHost = NSView()
    private let flash = WiiLabel(30, bold: true, color: .white)
    private let lossFlash = WiiLabel(24, bold: true, color: NSColor(srgbRed: 1, green: 0.42, blue: 0.38, alpha: 1))
    private let threatBox = WiiPanel()
    private let threatLabel = WiiLabel(15, bold: true, color: NSColor(srgbRed: 0.78, green: 0.16, blue: 0.12, alpha: 1))
    private let streakLabel = WiiLabel(12, bold: true, color: Wii.blue)
    private let helpBox = WiiPanel()
    private let helpTitle = WiiLabel(15, bold: true)
    private let help = WiiLabel(13)
    private let status = WiiLabel(11, color: NSColor.white.withAlphaComponent(0.8))
    let gauge = ControlGaugeView()
    private(set) var preview: CameraPreviewView?
    private var flyingTicks = 0
    private var helpAutoHidden = false
    var showHelp = false { didSet { helpBox.isHidden = !showHelp } }
    var showPreview = true { didSet { preview?.isHidden = !showPreview } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(statsBox)
        for v in [speed, speedUnit, details, coins, streakLabel] { statsBox.addSubview(v) }
        streakLabel.align = .right
        addSubview(threatBox)
        threatBox.borderColor = NSColor(srgbRed: 0.88, green: 0.30, blue: 0.25, alpha: 1)
        threatBox.addSubview(threatLabel)
        threatLabel.align = .center
        threatLabel.centerV = true
        threatBox.isHidden = true
        lossFlash.align = .center
        lossFlash.alphaValue = 0
        lossFlash.wantsLayer = true
        lossFlash.layer?.shadowColor = NSColor.black.cgColor
        lossFlash.layer?.shadowOpacity = 0.35
        lossFlash.layer?.shadowRadius = 3
        lossFlash.layer?.shadowOffset = .zero
        addSubview(lossFlash)
        speedUnit.text = "km/h"
        speed.align = .right
        addSubview(hintBox)
        hintBox.addSubview(hint)
        hint.align = .center
        hint.centerV = true
        addSubview(ring)
        ring.align = .center

        arrowHost.wantsLayer = true
        arrowHost.layer?.addSublayer(arrow)
        let ap = CGMutablePath()
        ap.move(to: CGPoint(x: 0, y: 18))
        ap.addLine(to: CGPoint(x: 11, y: -12)); ap.addLine(to: CGPoint(x: 0, y: -5)); ap.addLine(to: CGPoint(x: -11, y: -12))
        ap.closeSubpath()
        arrow.path = ap
        arrow.fillColor = NSColor.white.cgColor
        arrow.strokeColor = Wii.blue.cgColor
        arrow.lineWidth = 2.5
        arrow.lineJoin = .round
        arrow.shadowColor = NSColor.black.cgColor
        arrow.shadowOpacity = 0.2
        arrow.shadowRadius = 3
        addSubview(arrowHost)

        flash.align = .center
        flash.alphaValue = 0
        flash.wantsLayer = true
        flash.layer?.shadowColor = NSColor.black.cgColor
        flash.layer?.shadowOpacity = 0.35
        flash.layer?.shadowRadius = 4
        flash.layer?.shadowOffset = .zero
        addSubview(flash)
        for l in [ring, status] {
            l.wantsLayer = true
            l.layer?.shadowColor = NSColor.black.cgColor
            l.layer?.shadowOpacity = 0.4
            l.layer?.shadowRadius = 2
            l.layer?.shadowOffset = .zero
        }

        addSubview(helpBox)
        helpBox.isHidden = true
        helpBox.addSubview(helpTitle)
        helpBox.addSubview(help)
        helpTitle.text = "How to fly"
        help.text = """
        Flap your arms down to climb and speed up.
        Raise one arm and lower the other to turn.
        Arms up a little: nose up. Down a little: nose down.
        Arms at your sides: dive.
        Fly through the rings to earn ● coins.

        Keys: ←→ bank, ↑↓ pitch, Space flap, Shift dive
        Esc pause & shop · R recalibrate · H hide help
        """
        addSubview(gauge)
        addSubview(status)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func attachPreview(_ p: CameraPreviewView) {
        preview = p
        addSubview(p)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        statsBox.frame = NSRect(x: 16, y: b.height - 136, width: 210, height: 120)
        let c = statsBox.contentRect
        speed.frame = NSRect(x: c.minX + 8, y: c.minY + 12, width: 92, height: 40)
        speedUnit.frame = NSRect(x: c.minX + 104, y: c.minY + 28, width: 60, height: 18)
        details.frame = NSRect(x: c.minX + 16, y: c.minY + 54, width: c.width - 24, height: 20)
        coins.frame = NSRect(x: c.minX + 16, y: c.minY + 78, width: c.width - 24, height: 26)
        streakLabel.frame = NSRect(x: c.minX + 70, y: c.minY + 83, width: c.width - 82, height: 20)
        threatBox.frame = NSRect(x: b.width / 2 - 150, y: b.height - 226, width: 300, height: 48)
        threatLabel.frame = threatBox.contentRect.offsetBy(dx: 0, dy: 1)
        lossFlash.frame = NSRect(x: b.width / 2 - 300, y: b.height / 2 + 14, width: 600, height: 36)

        let hw = min(620, b.width - 600)
        hintBox.frame = NSRect(x: (b.width - hw) / 2, y: b.height - 74, width: hw, height: 60)
        hint.frame = hintBox.contentRect.insetBy(dx: 16, dy: 0).offsetBy(dx: 0, dy: 2)

        arrowHost.frame = NSRect(x: b.width / 2 - 25, y: b.height - 136, width: 50, height: 50)
        arrow.position = CGPoint(x: 25, y: 25)
        ring.frame = NSRect(x: b.width / 2 - 120, y: b.height - 160, width: 240, height: 18)
        flash.frame = NSRect(x: b.width / 2 - 300, y: b.height / 2 + 60, width: 600, height: 44)

        let pw: CGFloat = 320, ph: CGFloat = pw / (preview.map { CGFloat($0.aspectForLayout) } ?? 4.0 / 3.0)
        preview?.frame = NSRect(x: b.width - pw - 20, y: 20, width: pw, height: ph)
        gauge.frame = NSRect(x: b.width - pw - 20 - 150, y: 16, width: 140, height: 122)
        helpBox.frame = NSRect(x: 16, y: 16, width: 400, height: 214)
        let hc = helpBox.contentRect
        helpTitle.frame = NSRect(x: hc.minX + 16, y: hc.minY + 14, width: hc.width - 32, height: 22)
        help.frame = NSRect(x: hc.minX + 16, y: hc.minY + 42, width: hc.width - 32, height: hc.height - 50)
        status.frame = NSRect(x: 20, y: b.height - 156, width: 200, height: 16)
    }

    func showNotice(_ text: String) {
        flash.text = text
        flash.alphaValue = 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            flash.animator().alphaValue = 0
        }
    }

    func showBonus(coins: Int, total: Int) {
        flash.text = "+\(coins) ●  test coins"
        flash.alphaValue = 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.5
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            flash.animator().alphaValue = 0
        }
        setCoins(total)
    }

    func showRingFlash(coins gained: Int, total: Int, streak: Int = 0) {
        flash.text = streak > 1 ? "Ring!  +\(gained) ●   Streak \(streak)" : "Ring!  +\(gained) ●"
        flash.alphaValue = 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.5
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            flash.animator().alphaValue = 0
        }
        setCoins(total)
    }

    func setCoins(_ total: Int) { coins.text = "● \(total)" }

    func showLoss(coins lost: Int, total: Int) {
        lossFlash.text = lost > 0 ? "Ouch!  −\(lost) ●" : "Ouch!"
        lossFlash.alphaValue = 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            lossFlash.animator().alphaValue = 0
        }
        setCoins(total)
    }

    func update(_ s: HUDStats, pose: RawPose?, cameraName: String) {
        speed.text = String(format: "%.0f", s.speedKmh)
        details.text = String(format: "Height %.0f m   Rings %d", s.agl, s.score)
        streakLabel.isHidden = !s.streakEnabled
        let bonus = 1 + 0.25 * Double(min(max(s.streak - 1, 0), 8))
        streakLabel.text = s.streak > 1 ? String(format: "Streak %d · ×%.2f", s.streak, bonus) : "Streak \(s.streak)"
        threatBox.isHidden = s.threat == nil
        threatLabel.text = s.threat ?? ""

        var message = ""
        if s.usingKeyboard {
            message = ""
        } else if !s.control.tracking {
            message = s.control.hint.isEmpty ? "Step in front of the camera and hold your arms out." : s.control.hint
        } else if !s.control.hint.isEmpty {
            message = s.control.hint
        }
        if message.isEmpty && s.stalled > 0.5 { message = "Stalling — flap or lower your arms." }
        hint.text = message
        hintBox.isHidden = message.isEmpty

        if s.ringDistance > 0 {
            let above = s.ringAbove > 15 ? "  ↑" : (s.ringAbove < -15 ? "  ↓" : "")
            ring.text = String(format: "Next ring  %.0f m", s.ringDistance) + above
            CATransaction.begin(); CATransaction.setDisableActions(true)
            arrow.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(s.ringBearing)))
            CATransaction.commit()
        }
        // Once someone has been flying for ~20 s, get the help out of the way (H brings it back).
        if (s.control.tracking && s.control.calibrated) || s.usingKeyboard { flyingTicks += 1 }
        if !helpAutoHidden && flyingTicks > 600 { helpAutoHidden = true; showHelp = false }
        gauge.active = (s.control.tracking && s.control.ready) || s.usingKeyboard
        gauge.input = s.input
        preview?.update(pose: pose, control: s.control)
        let mode = s.usingKeyboard ? "Keyboard" : (s.control.ready ? "Tracking" : s.control.tracking ? "Show both hands" : "Looking for you")
        preview?.caption.text = "\(cameraName) · \(mode)"
        status.text = String(format: "%.0f fps", s.fps)
    }
}
