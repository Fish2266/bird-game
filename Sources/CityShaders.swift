import SceneKit
import AppKit
import simd

/// Skyline City's materials. Windows, street paint and traffic lights are drawn by shader modifiers from world
/// position and a few numbers packed into the texture coordinates, so the meshes stay tiny and the detail stays sharp
/// up close. `cityTime` (set by the runtime every frame) drives the traffic lights, billboards and cranes, on the same
/// clock the traffic simulation uses.
enum CityShaders {
    /// Packs a facade style (0…7) and a building seed (0…7) into the u coordinate: u = (style + 8·seed)·1000 + metres.
    @inline(__always) static func facadeU(_ style: Int, _ seed: Int, _ metres: Float) -> Float {
        Float(style + 8 * seed) * 1000 + metres
    }

    static let facade: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = WorldMaterials.whitePixel
        m.roughness.contents = 0.85
        m.metalness.contents = 0.0
        let atlas = SCNMaterialProperty(contents: CityShaders.signAtlas)
        atlas.mipFilter = .linear
        m.setValue(atlas, forKey: "signAtlas")
        m.shaderModifiers = [.surface: facadeShader]
        return m
    }()

    /// Shop signs: 4 columns by 8 rows of 256×64 boards.
    static let signAtlas: NSImage = {
        let signs: [(String, NSColor, NSColor)] = [
            ("CAFÉ", rgb(0.16, 0.32, 0.22), rgb(0.95, 0.9, 0.78)), ("PIZZA", rgb(0.72, 0.12, 0.1), .white),
            ("BAKERY", rgb(0.93, 0.86, 0.72), rgb(0.45, 0.25, 0.12)), ("BOOKS", rgb(0.12, 0.16, 0.3), rgb(0.95, 0.85, 0.5)),
            ("FLOWERS", rgb(0.95, 0.9, 0.92), rgb(0.75, 0.2, 0.4)), ("DELI", rgb(0.1, 0.1, 0.1), rgb(1, 0.8, 0.2)),
            ("SHOES", rgb(0.85, 0.85, 0.85), rgb(0.1, 0.1, 0.12)), ("PHARMACY", rgb(0.1, 0.45, 0.3), .white),
            ("BANK", rgb(0.15, 0.2, 0.32), rgb(0.85, 0.75, 0.45)), ("SUSHI", rgb(0.9, 0.9, 0.86), rgb(0.7, 0.1, 0.1)),
            ("BAGELS", rgb(0.85, 0.55, 0.2), rgb(0.25, 0.12, 0.05)), ("BARBER", rgb(0.1, 0.18, 0.4), rgb(0.95, 0.95, 0.95)),
            ("TOYS", rgb(0.95, 0.75, 0.15), rgb(0.85, 0.15, 0.2)), ("RECORDS", rgb(0.08, 0.08, 0.08), rgb(0.95, 0.4, 0.6)),
            ("GROCERY", rgb(0.2, 0.5, 0.2), rgb(1, 0.95, 0.8)), ("HARDWARE", rgb(0.75, 0.3, 0.1), .white),
            ("NOODLES", rgb(0.6, 0.08, 0.08), rgb(1, 0.85, 0.3)), ("TACOS", rgb(0.15, 0.55, 0.45), rgb(1, 0.9, 0.3)),
            ("GYM", rgb(0.12, 0.12, 0.14), rgb(0.3, 0.9, 1)), ("OPTICIAN", rgb(0.92, 0.92, 0.95), rgb(0.15, 0.3, 0.6)),
            ("LAUNDRY", rgb(0.35, 0.65, 0.9), .white), ("DINER", rgb(0.85, 0.15, 0.15), rgb(1, 0.95, 0.85)),
            ("ICE CREAM", rgb(0.98, 0.8, 0.85), rgb(0.5, 0.25, 0.15)), ("JEWELRY", rgb(0.1, 0.1, 0.1), rgb(0.9, 0.78, 0.4)),
            ("BURGERS", rgb(0.95, 0.65, 0.1), rgb(0.35, 0.1, 0.05)), ("TEA HOUSE", rgb(0.25, 0.35, 0.2), rgb(0.95, 0.9, 0.75)),
            ("GALLERY", rgb(0.97, 0.97, 0.97), rgb(0.1, 0.1, 0.1)), ("BIKES", rgb(0.2, 0.4, 0.75), rgb(1, 0.9, 0.2)),
            ("SEED & CO", rgb(0.45, 0.3, 0.15), rgb(0.95, 0.88, 0.7)), ("NEST HOME", rgb(0.3, 0.55, 0.55), .white),
            ("WORM DELI", rgb(0.55, 0.15, 0.35), rgb(1, 0.85, 0.6)), ("FEATHERS", rgb(0.9, 0.85, 0.95), rgb(0.4, 0.2, 0.55)),
        ]
        let fonts = ["Georgia-Bold", "AvenirNext-Heavy", "Futura-Bold", "HelveticaNeue-CondensedBold", "AmericanTypewriter-Bold", "Didot-Bold"]
        return NSImage(size: NSSize(width: 1024, height: 512), flipped: true) { _ in
            for (k, sign) in signs.enumerated() {
                let r = NSRect(x: CGFloat(k % 4) * 256, y: CGFloat(k / 4) * 64, width: 256, height: 64)
                sign.1.setFill(); NSBezierPath(rect: r).fill()
                sign.2.withAlphaComponent(0.35).setStroke()
                let border = NSBezierPath(rect: r.insetBy(dx: 5, dy: 5)); border.lineWidth = 2; border.stroke()
                let para = NSMutableParagraphStyle(); para.alignment = .center
                let font = NSFont(name: fonts[k % fonts.count], size: 34) ?? NSFont.boldSystemFont(ofSize: 34)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: sign.2, .paragraphStyle: para, .kern: 1.5]
                let str = NSAttributedString(string: sign.0, attributes: attrs)
                let h = str.size().height
                str.draw(in: NSRect(x: r.minX + 6, y: r.midY - h / 2, width: r.width - 12, height: h))
            }
            return true
        }
    }()

    /// Lamps, lit signs and the traffic lights (one material, so one draw per chunk).
    static let signals: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = WorldMaterials.whitePixel
        m.diffuse.intensity = 2.3
        m.shaderModifiers = [.surface: signalShader]
        m.setValue(NSNumber(value: 0), forKey: "cityTime")
        return m
    }()

    /// Every city material, for compiling shaders before play.
    static var all: [SCNMaterial] { [facade, signals, screens, craneTop, subway, subwaySigns] }

    /// The subway: lit by its own lamps (baked into the vertex colours), so it ignores the sun and sky. uv.y > 999 marks
    /// tiled surfaces (u along, v − 1000 up, in metres).
    static let subway: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = WorldMaterials.whitePixel
        m.shaderModifiers = [.surface: """
        #pragma arguments
        float subwayLight;
        #pragma body
        float2 tc = _surface.diffuseTexcoord;
        _surface.diffuse.rgb *= subwayLight;
        if (tc.y > 999.0) {
            float2 t = float2(tc.x / 0.3, (tc.y - 1000.0) / 0.15);
            float row = floor(t.y);
            float2 f = fract(float2(t.x + 0.5 * (row - 2.0 * floor(row / 2.0)), t.y));
            float2 fw = fwidth(t);
            float gx = 1.0 - smoothstep(0.0, 0.06 + fw.x, min(f.x, 1.0 - f.x));
            float gy = 1.0 - smoothstep(0.0, 0.1 + fw.y, min(f.y, 1.0 - f.y));
            float grout = max(gx, gy) * (1.0 - smoothstep(0.25, 0.6, max(fw.x, fw.y)));
            _surface.diffuse.rgb *= mix(1.0, 0.72, grout);
        }
        """]
        m.setValue(NSNumber(value: 0.36), forKey: "subwayLight")
        return m
    }()

    /// Station names on the walls: 3 columns by 8 rows of name boards.
    static let subwaySigns: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSImage(size: NSSize(width: 1536, height: 512), flipped: true) { _ in
            for (k, name) in CitySubway.names.enumerated() {
                let r = NSRect(x: CGFloat(k / 8) * 512, y: CGFloat(k % 8) * 64, width: 512, height: 64)
                NSColor(white: 0.08, alpha: 1).setFill(); NSBezierPath(rect: r).fill()
                NSColor(white: 0.95, alpha: 1).setStroke()
                let b = NSBezierPath(rect: r.insetBy(dx: 4, dy: 4)); b.lineWidth = 2; b.stroke()
                let para = NSMutableParagraphStyle(); para.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "HelveticaNeue-Bold", size: 40) ?? NSFont.boldSystemFont(ofSize: 40),
                                                            .foregroundColor: NSColor.white, .paragraphStyle: para, .kern: 2]
                let str = NSAttributedString(string: name.uppercased(), attributes: attrs)
                let h = str.size().height
                str.draw(in: NSRect(x: r.minX + 8, y: r.midY - h / 2, width: r.width - 16, height: h))
            }
            return true
        }
        m.diffuse.mipFilter = .linear
        m.shaderModifiers = [.surface: """
        #pragma arguments
        float subwayLight;
        #pragma body
        _surface.diffuse.rgb *= subwayLight;
        """]
        m.setValue(NSNumber(value: 0.36), forKey: "subwayLight")
        return m
    }()

    /// Down in the subway its lamps are all the light there is; seen from the sunny street or river it's a dark hole.
    static func setUnderground(_ u: Float) {
        let n = NSNumber(value: 0.36 + 0.64 * u)
        subway.setValue(n, forKey: "subwayLight")
        subwaySigns.setValue(n, forKey: "subwayLight")
    }

    static let screens: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = WorldMaterials.whitePixel
        m.setValue(SCNMaterialProperty(contents: CityShaders.adAtlas), forKey: "adAtlas")
        m.setValue(NSNumber(value: 0), forKey: "cityTime")
        m.shaderModifiers = [.surface: screenShader]
        return m
    }()

    static let craneTop: SCNMaterial = {
        let m = WorldMaterials.vertexColor(rough: 0.6, metal: 0.3)
        m.diffuse.contents = WorldMaterials.whitePixel
        m.setValue(NSNumber(value: 0), forKey: "cityTime")
        m.shaderModifiers = [.geometry: craneShader]
        return m
    }()

    /// Everything that reads the clock.
    static func setTime(_ t: Float) {
        let n = NSNumber(value: t)
        signals.setValue(n, forKey: "cityTime")
        screens.setValue(n, forKey: "cityTime")
        craneTop.setValue(n, forKey: "cityTime")
    }

    /// Jib angle of a crane (the crane shader turns it the same way).
    static func craneAngle(phase: Float, time t: Float) -> Float { phase + 0.9 * sin(t * 0.06 + phase * 3) }

    static func configureGround(_ m: SCNMaterial) {
        m.shaderModifiers = [.surface: groundShader]
    }

    // MARK: Billboard ads

    static let adCount = 8
    static let adAtlas: NSImage = {
        let w: CGFloat = 512, h: CGFloat = 256
        let ads: [(String, String, NSColor, NSColor)] = [
            ("FLAP COLA", "taste the updraft", rgb(0.85, 0.1, 0.12), .white),
            ("BIRD GAME", "now with dinosaurs", rgb(0.15, 0.45, 0.95), .white),
            ("SEED BURGER", "100% sunflower", rgb(0.98, 0.78, 0.12), rgb(0.35, 0.15, 0.05)),
            ("NEST REALTY", "penthouses with a view", rgb(0.1, 0.55, 0.42), .white),
            ("WORM PIZZA", "extra wiggly", rgb(0.95, 0.45, 0.15), .white),
            ("SKYLINE TOURS", "see it all from above", rgb(0.45, 0.2, 0.7), .white),
            ("BEAK BEATS FM", "102.5 tweets per minute", rgb(0.08, 0.08, 0.1), rgb(0.3, 1, 0.8)),
            ("FEATHER & CO", "fine plumage since 1902", rgb(0.92, 0.9, 0.86), rgb(0.15, 0.15, 0.2)),
        ]
        return NSImage(size: NSSize(width: w, height: h * CGFloat(ads.count)), flipped: true) { _ in
            for (k, ad) in ads.enumerated() {
                let r = NSRect(x: 0, y: CGFloat(k) * h, width: w, height: h)
                ad.2.setFill(); NSBezierPath(rect: r).fill()
                // A big sun / circle motif behind the text.
                ad.3.withAlphaComponent(0.18).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.maxX - 190, y: r.minY - 40, width: 260, height: 260)).fill()
                let para = NSMutableParagraphStyle(); para.alignment = .center
                let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 74, weight: .heavy), .foregroundColor: ad.3,
                                                          .paragraphStyle: para]
                let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold),
                                                            .foregroundColor: ad.3.withAlphaComponent(0.85), .paragraphStyle: para]
                (ad.0 as NSString).draw(in: NSRect(x: 10, y: r.minY + 52, width: w - 20, height: 92), withAttributes: big)
                (ad.1 as NSString).draw(in: NSRect(x: 10, y: r.minY + 150, width: w - 20, height: 44), withAttributes: small)
            }
            return true
        }
    }()

    // MARK: Shader sources

    /// Facades: windows from the packed uv (see `facadeU`), v = metres above the building's base.
    private static let facadeShader = """
    #pragma arguments
    texture2d<float> signAtlas;
    #pragma declaration
    float cityHash(float2 p) { p = fract(p * float2(127.1, 311.7)); p += dot(p, p + 19.19); return fract(p.x * p.y * 43.758); }
    float cityBand(float x, float a, float b, float fw) { return saturate(smoothstep(a - fw, a + fw, x) - smoothstep(b - fw, b + fw, x)); }
    #pragma body
    float2 tc = _surface.diffuseTexcoord;
    float k = floor(tc.x / 1000.0 + 0.0001);
    float u = tc.x - k * 1000.0;
    float v = tc.y;
    float style = k - 8.0 * floor(k / 8.0);
    float seed = floor(k / 8.0);
    float3 base = _surface.diffuse.rgb;
    float ao = mix(0.62, 1.0, smoothstep(0.0, 16.0, v));
    if (style > 6.5) {
        float n = cityHash(floor(float2(u, v) * 0.5));
        _surface.diffuse.rgb = base * ao * (0.94 + 0.08 * n);
        _surface.roughness = 0.88;
    } else {
        float bay = 3.0, fl = 3.7, x0 = 0.15, x1 = 0.85, y0 = 0.3, y1 = 0.88;
        float3 glass = float3(0.03, 0.036, 0.045);
        float3 frame = base;
        float glassRough = 0.09, glassMetal = 0.75, wallRough = 0.86, wallMetal = 0.0;
        float litChance = 0.07;
        float floorLit = 0.0;
        if (style < 0.5) {
            bay = 1.55; fl = 3.9; x0 = 0.035; x1 = 0.965; y0 = 0.17; y1 = 0.985;
            glass = mix(base, float3(0.42, 0.46, 0.5), 0.35) * 1.25;
            frame = mix(base, float3(0.36, 0.37, 0.4), 0.6);
            wallMetal = 0.75; wallRough = 0.32; glassRough = 0.05; glassMetal = 0.92; floorLit = 1.0; litChance = 0.07;
        } else if (style < 1.5) {
            bay = 3.0; fl = 3.7; x0 = 0.14; x1 = 0.86; y0 = 0.3; y1 = 0.88;
            glass = float3(0.07, 0.085, 0.1);
        } else if (style < 2.5) {
            bay = 6.0; fl = 3.6; x0 = -0.1; x1 = 1.1; y0 = 0.36; y1 = 0.9; floorLit = 1.0; litChance = 0.06;
            glass = float3(0.08, 0.1, 0.12);
        } else if (style < 3.5) {
            bay = 3.2; fl = 3.1; x0 = 0.3; x1 = 0.7; y0 = 0.28; y1 = 0.84; litChance = 0.1;
            glass = float3(0.05, 0.055, 0.06);
        } else if (style < 4.5) {
            bay = 2.2; fl = 3.8; x0 = 0.25; x1 = 0.75; y0 = 0.2; y1 = 0.9;
            glass = float3(0.06, 0.07, 0.08);
        } else if (style < 5.5) {
            bay = 3.6; fl = 3.2; x0 = 0.08; x1 = 0.92; y0 = 0.22; y1 = 0.93; litChance = 0.09;
            glass = float3(0.06, 0.075, 0.09);
        } else {
            bay = 9.0; fl = 3.0; x0 = -0.1; x1 = 1.1; y0 = 0.45; y1 = 0.9; litChance = 0.0;
            glass = float3(0.012, 0.012, 0.014); glassMetal = 0.0; glassRough = 1.0;
        }
        float store = (seed > 3.5 && v < 4.9) ? 1.0 : 0.0;
        if (store > 0.5) { bay = 4.2; fl = 4.9; x0 = 0.06; x1 = 0.94; y0 = 0.05; y1 = 0.7; floorLit = 0.0; }
        float2 cell = float2(u / bay, v / fl);
        float2 id = floor(cell);
        float2 f = cell - id;
        float2 fw = max(fwidth(cell), float2(0.0005));
        float win = cityBand(f.x, x0, x1, fw.x) * cityBand(f.y, y0, y1, fw.y);
        float cover = (min(x1, 1.0) - max(x0, 0.0)) * (y1 - y0);
        float far = smoothstep(0.25, 0.75, max(fw.x, fw.y));
        win = mix(win, cover, far);
        float h = cityHash(id + float2(seed * 17.0, style * 31.0 + 0.5));
        float hf = cityHash(float2(id.y * 1.37 + seed * 3.1, style + 7.0));
        float lit = floorLit > 0.5 ? step(1.0 - litChance, hf) * step(0.35, h) + step(0.975, h) : step(1.0 - litChance, h);
        lit = saturate(lit);
        // Panes vary a little (and curtains or blinds in some windows): no two windows quite alike.
        float pane = cityHash(id + 3.1);
        float3 inside = glass * (0.82 + 0.36 * mix(pane, 0.5, far));
        if (style > 0.5) { inside = mix(inside, inside + float3(0.035, 0.033, 0.028), step(0.78, pane)); }
        float3 warm = mix(float3(1.0, 0.78, 0.52), float3(0.86, 0.9, 1.0), step(0.7, cityHash(id + 9.7)));
        float3 wall = base;
        float rough = glassRough * (0.6 + 0.9 * pane);
        if (style > 2.5 && style < 3.5 && store < 0.5) {
            float2 bc = float2(u / 0.42, v / 0.19);
            float row = floor(bc.y);
            float bx = fract(bc.x + 0.5 * (row - 2.0 * floor(row / 2.0)));
            float2 bfw = fwidth(bc);
            float mortar = max(cityBand(bx, -0.2, 0.07, bfw.x), cityBand(fract(bc.y), -0.2, 0.13, bfw.y));
            mortar *= 1.0 - smoothstep(0.12, 0.45, bfw.y);
            float tone = 0.9 + 0.2 * cityHash(floor(bc) + seed);
            wall = mix(base * tone, base * 0.45 + 0.12, mortar * 0.55);
            float sill = cityBand(f.y, y0 - 0.07, y0, fw.y) * cityBand(f.x, x0 - 0.05, x1 + 0.05, fw.x);
            float lintel = cityBand(f.y, y1, y1 + 0.06, fw.y) * cityBand(f.x, x0 - 0.05, x1 + 0.05, fw.x);
            wall = mix(wall, float3(0.62, 0.6, 0.56), (sill + lintel) * (1.0 - far));
        }
        if (style > 3.5 && style < 4.5) {
            float pier = 1.0 - cityBand(f.x, x0, x1, fw.x);
            wall = mix(base * 0.78, base * 1.06, mix(pier, 0.5, far));
        }
        if (style > 4.5 && style < 5.5 && store < 0.5) {
            float slab = cityBand(f.y, -0.02, 0.07, fw.y);
            float rail = cityBand(f.y, 0.07, 0.34, fw.y) * (1.0 - far);
            wall = mix(wall, float3(0.8, 0.8, 0.78), slab * (1.0 - far));
            win *= 1.0 - rail * 0.45;
            inside = mix(inside, float3(0.3, 0.32, 0.34), rail * 0.5);
        }
        if (style < 0.5) {
            float spandrel = cityBand(f.y, -0.02, 0.17, fw.y);
            wall = mix(frame, frame * 0.7, spandrel);
        }
        if (style > 1.5 && style < 2.5 && store < 0.5) {
            float m = u / 1.5;
            float mull = cityBand(fract(m), -0.1, 0.05, fwidth(m)) * (1.0 - far);
            win *= 1.0 - mull;
        }
        float glow = 0.3;
        if (store > 0.5) {
            // Shop fronts: a sign band over big windows with lit interiors; now and then a door.
            float sign = cityBand(f.y, 0.75, 0.95, fw.y) * cityBand(f.x, 0.06, 0.94, fw.x);
            float hs = cityHash(float2(id.x * 1.7, seed + 2.0));
            float idx = floor(hs * 31.99);
            float col = idx - 4.0 * floor(idx / 4.0), row = floor(idx / 4.0);
            float2 lu = saturate(float2((f.x - 0.06) / 0.88, (f.y - 0.75) / 0.2));
            float2 auv = float2((col + lu.x) / 4.0, (row + 1.0 - lu.y) / 8.0);
            float2 k2 = float2(1.0 / (0.88 * 4.0), -1.0 / (0.2 * 8.0));
            constexpr sampler signSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
            float3 signC = signAtlas.sample(signSampler, auv, gradient2d(dfdx(cell) * k2, dfdy(cell) * k2)).rgb;
            signC *= signC;
            wall = mix(wall * 0.75, signC, sign);
            _surface.emission.rgb += signC * sign * 0.25 * step(0.5, cityHash(float2(id.x + 4.0, seed)));
            float door = step(cityHash(float2(id.x, seed + 9.0)), 0.18);
            float3 shop = float3(0.42, 0.33, 0.22) * (0.55 + 0.6 * f.y / 0.7);
            inside = mix(shop, float3(0.03, 0.03, 0.035), door * cityBand(f.x, 0.3, 0.7, fw.x));
            lit = 1.0 - door * 0.7;
            glow = 0.45;
            rough = 0.12;
        }
        float3 col = mix(wall * ao, inside, win);
        _surface.diffuse.rgb = col;
        _surface.metalness = mix(wallMetal, glassMetal, win * (store > 0.5 ? 0.4 : 1.0));
        _surface.roughness = mix(wallRough, rough, win);
        _surface.emission.rgb += warm * win * lit * glow * (1.0 - far * 0.4);
    }
    """

    /// Streets painted on the ground from world position: asphalt, lane lines, crosswalks, stop lines and sidewalks.
    /// Must match CityLayout's lines (pitch 120; avenues at i % 3, j % 4; elevated train at i % 12 == 6).
    private static let groundShader = """
    #pragma declaration
    float gHash(float2 p) { p = fract(p * float2(127.1, 311.7)); p += dot(p, p + 19.19); return fract(p.x * p.y * 43.758); }
    float gBand(float x, float c, float hw, float fw) { return 1.0 - smoothstep(-fw, fw, abs(x - c) - hw); }
    float gStep(float x, float a, float fw) { return smoothstep(a - fw, a + fw, x); }
    #pragma body
    float3 wp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 wn = normalize((scn_frame.inverseViewTransform * float4(_surface.normal, 0.0)).xyz);
    if (wn.y < 0.7 && wp.y > -1.0) {
        // Quay walls: courses of dressed stone, darker and greener toward the water.
        float along = abs(wn.x) > abs(wn.z) ? wp.z : wp.x;
        float2 st = float2(along / 1.6, wp.y / 0.7);
        float row = floor(st.y);
        float sx = fract(st.x + 0.5 * (row - 2.0 * floor(row / 2.0)));
        float2 sfw = fwidth(st);
        float joint = max(gBand(sx, 0.0, 0.03, sfw.x) + gBand(sx, 1.0, 0.03, sfw.x), gBand(fract(st.y), 0.0, 0.05, sfw.y) + gBand(fract(st.y), 1.0, 0.05, sfw.y));
        joint *= 1.0 - smoothstep(0.15, 0.5, max(sfw.x, sfw.y));
        float3 stone = float3(0.30, 0.28, 0.25) * (0.85 + 0.3 * gHash(floor(st) + 3.0));
        stone = mix(stone, float3(0.12, 0.15, 0.11), smoothstep(4.0, 0.0, wp.y));
        _surface.diffuse.rgb = mix(stone, stone * 0.55, joint);
        _surface.roughness = 0.9;
    }
    if (wp.y > 2.0 && wn.y > 0.75) {
        float G = 120.0;
        float i = floor(wp.x / G + 0.5); float dx = wp.x - i * G;
        float j = floor(wp.z / G + 0.5); float dz = wp.z - j * G;
        float mi3 = i - 3.0 * floor(i / 3.0);
        float mi12 = i - 12.0 * floor(i / 12.0);
        float mj4 = j - 4.0 * floor(j / 4.0);
        bool aveX = mi3 < 0.5; bool elX = abs(mi12 - 6.0) < 0.5; bool aveZ = mj4 < 0.5;
        float hrX = elX ? 9.0 : (aveX ? 7.5 : 6.0);
        float hwX = hrX + (aveX ? 5.0 : 4.0);
        float hrZ = aveZ ? 7.5 : 6.0;
        float hwZ = hrZ + (aveZ ? 5.0 : 4.0);
        float medX = elX ? 2.0 : (aveX ? 0.5 : 0.0);
        float medZ = aveZ ? 0.5 : 0.0;
        float ax = abs(dx), az = abs(dz);
        float fwx = max(fwidth(wp.x), 0.002), fwz = max(fwidth(wp.z), 0.002);
        float inX = 1.0 - gStep(ax, hwX, fwx), inZ = 1.0 - gStep(az, hwZ, fwz);
        float corridor = max(inX, inZ);
        // Inside the blocks: paving on plazas and lots (not on grass, dirt or asphalt).
        float3 dc = _surface.diffuse.rgb;
        float lum = dot(dc, float3(0.3, 0.55, 0.15));
        float sat = max(dc.r, max(dc.g, dc.b)) - min(dc.r, min(dc.g, dc.b));
        float paved = (1.0 - corridor) * smoothstep(0.14, 0.2, lum) * smoothstep(0.13, 0.09, sat);
        if (paved > 0.0) {
            float2 tile = wp.xz / 1.25;
            float2 tf = fract(tile);
            float2 tfw = float2(fwx, fwz) / 1.25;
            float j = max(gBand(tf.x, 0.0, 0.03, tfw.x) + gBand(tf.x, 1.0, 0.03, tfw.x), gBand(tf.y, 0.0, 0.03, tfw.y) + gBand(tf.y, 1.0, 0.03, tfw.y));
            j *= 1.0 - smoothstep(0.1, 0.4, max(tfw.x, tfw.y));
            float3 slab = dc * (0.9 + 0.16 * gHash(floor(tile) + 7.0));
            _surface.diffuse.rgb = mix(dc, slab * (1.0 - 0.3 * j), paved);
        }
        if (corridor > 0.0) {
            float roadX = 1.0 - gStep(ax, hrX, fwx), roadZ = 1.0 - gStep(az, hrZ, fwz);
            float road = max(roadX, roadZ);
            // Asphalt with worn patches and darker tyre tracks.
            float patch = gHash(floor(wp.xz / 3.0));
            float3 asphalt = float3(0.085, 0.087, 0.095) * (0.86 + 0.22 * patch);
            float3 white = float3(0.72, 0.72, 0.70);
            float3 yellow = float3(0.80, 0.52, 0.05);
            float3 c = asphalt;
            float far = smoothstep(0.08, 0.3, max(fwx, fwz));
            // Lane paint on the N-S road (outside the intersection and its crosswalks)
            float segX = roadX * gStep(az, hwZ + 1.0, fwz);
            float segZ = roadZ * gStep(ax, hwX + 1.0, fwx);
            float paintY = 0.0, paintW = 0.0;
            // Centre lines: double yellow (streets), yellow edges of the median (avenues), a concrete strip under the el.
            if (elX) {
                float med = 1.0 - gStep(ax, medX, fwx);
                c = mix(c, float3(0.42, 0.42, 0.41), med * segX);
                paintY += segX * gBand(ax, medX + 0.2, 0.08, fwx);
            } else {
                paintY += segX * (gBand(ax, medX + 0.16, 0.06, fwx));
            }
            paintY += segZ * gBand(az, medZ + 0.16, 0.06, fwz);
            // Dashed lane dividers on avenues, parking lines on streets.
            float dashZ = step(fract(wp.z / 9.0), 0.36);
            float dashX = step(fract(wp.x / 9.0), 0.36);
            if (aveX) { paintW += segX * dashZ * gBand(ax, medX + 3.5, 0.07, fwx); }
            else { paintW += segX * gBand(ax, 3.5, 0.05, fwx); }
            if (aveZ) { paintW += segZ * dashX * gBand(az, medZ + 3.5, 0.07, fwz); }
            else { paintW += segZ * gBand(az, 3.5, 0.05, fwz); }
            // Crosswalks (zebra) where the sidewalks cross the road, and stop lines before them.
            float cwX = roadX * (1.0 - roadZ) * step(az, hwZ - 0.4) * step(hrZ + 0.4, az);
            float cwZ = roadZ * (1.0 - roadX) * step(ax, hwX - 0.4) * step(hrX + 0.4, ax);
            float zebraX = step(fract(dx / 1.2), 0.55);
            float zebraZ = step(fract(dz / 1.2), 0.55);
            paintW += cwX * zebraX + cwZ * zebraZ;
            float stopX = roadX * step(medX, ax) * step(0.0, dx * dz) * gBand(az, hwZ + 0.7, 0.25, fwz);
            float stopZ = roadZ * step(medZ, az) * step(dx * dz, 0.0) * gBand(ax, hwX + 0.7, 0.25, fwx);
            paintW += stopX + stopZ;
            // Manhole covers.
            float2 mh = wp.xz - (floor(wp.xz / 23.0) + 0.5) * 23.0;
            float mhole = (1.0 - smoothstep(0.55, 0.62, length(mh))) * step(0.6, gHash(floor(wp.xz / 23.0) + 5.0)) * road;
            c = mix(c, float3(0.05, 0.05, 0.052), mhole);
            paintW = saturate(paintW) * (1.0 - far * 0.5);
            paintY = saturate(paintY) * (1.0 - far * 0.5);
            c = mix(c, white * (0.82 + 0.18 * patch), paintW);
            c = mix(c, yellow, paintY);
            // Sidewalks: concrete slabs with joints and a bright curb.
            float2 slab = fract(wp.xz / 1.6);
            float2 sfw = float2(fwx, fwz) / 1.6;
            float joint = max(gBand(slab.x, 0.0, 0.025, sfw.x) + gBand(slab.x, 1.0, 0.025, sfw.x),
                              gBand(slab.y, 0.0, 0.025, sfw.y) + gBand(slab.y, 1.0, 0.025, sfw.y)) * (1.0 - far);
            float3 walk = float3(0.42, 0.41, 0.39) * (0.93 + 0.1 * gHash(floor(wp.xz / 1.6))) * (1.0 - 0.25 * joint);
            float curbX = gBand(ax, hrX + 0.15, 0.15, fwx) * (1.0 - roadZ);
            float curbZ = gBand(az, hrZ + 0.15, 0.15, fwz) * (1.0 - roadX);
            walk = mix(walk, float3(0.58, 0.57, 0.55), saturate(curbX + curbZ) * (1.0 - road));
            c = mix(walk, c, road);
            _surface.diffuse.rgb = mix(_surface.diffuse.rgb, c, corridor);
            _surface.roughness = mix(_surface.roughness, mix(0.92, 0.75, road), corridor);
        }
    }
    """

    /// The glow material in the city: ordinary lights (uv.x < 50) stay on; traffic signal lamps have
    /// uv.x = 100 + lamp (0 red, 1 yellow, 2 green) + 10·axis and uv.y = the intersection's phase offset (seconds);
    /// aircraft beacons (uv.x = 130) blink.
    private static let signalShader = """
    #pragma arguments
    float cityTime;
    #pragma body
    float2 tc = _surface.diffuseTexcoord;
    float on = 1.0;
    if (tc.x < 50.0) {
        on = 1.0;
    } else if (tc.x > 125.0) {
        on = step(0.55, fract(cityTime * 0.5 + tc.y));
    } else {
        float code = tc.x - 100.0;
        float axis = floor(code / 10.0 + 0.001);
        float lamp = code - axis * 10.0;
        float p = cityTime + tc.y;
        p = p - 26.0 * floor(p / 26.0);
        float state;
        if (axis < 0.5) { state = p < 10.0 ? 0.0 : (p < 12.5 ? 1.0 : 2.0); }
        else { state = p < 13.0 ? 2.0 : (p < 23.0 ? 0.0 : (p < 25.5 ? 1.0 : 2.0)); }
        on = step(abs(lamp - (2.0 - state)), 0.5);
    }
    _surface.diffuse.rgb *= mix(0.06, 1.0, on);
    """

    /// LED billboards: uv = (across, up + 10·seed); a new ad every few seconds, with a scan-line shimmer.
    private static let screenShader = """
    #pragma arguments
    float cityTime;
    texture2d<float> adAtlas;
    #pragma body
    constexpr sampler adSampler(filter::linear, mip_filter::none, address::clamp_to_edge);
    float2 tc = _surface.diffuseTexcoord;
    float seed = floor(tc.y / 10.0 + 0.001);
    float lv = tc.y - seed * 10.0;
    float slot = floor(cityTime / 7.0 + seed * 0.37);
    float ad = fmod(slot * 3.0 + seed, 8.0);
    float2 uv = float2(tc.x, (ad + (1.0 - lv)) / 8.0);
    float3 c = adAtlas.sample(adSampler, uv).rgb;
    float wipe = smoothstep(0.0, 0.05, fract(cityTime / 7.0 + seed * 0.37));
    float scan = 0.92 + 0.08 * sin(lv * 160.0);
    _surface.diffuse.rgb = c * c * scan * wipe * 1.6;
    """

    /// Crane tops spin about their mast; uv.y holds the crane's phase.
    private static let craneShader = """
    #pragma arguments
    float cityTime;
    #pragma body
    float ph = _geometry.texcoords[0].y;
    float a = ph + 0.9 * sin(cityTime * 0.06 + ph * 3.0);
    float c = cos(a), s = sin(a);
    float2 p = _geometry.position.xz;
    _geometry.position.xz = float2(c * p.x - s * p.y, s * p.x + c * p.y);
    float2 n = _geometry.normal.xz;
    _geometry.normal.xz = float2(c * n.x - s * n.y, s * n.x + c * n.y);
    """
}
