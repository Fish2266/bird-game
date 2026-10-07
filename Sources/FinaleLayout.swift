import Foundation
import simd

// Where things are in The Finale: the castle on its hill in the middle of the island (gate to the south, toward the
// village), the great hall inside with the throne at its north end, the Sky Tower behind it, the road, the village,
// the lake and the mountains. Pure geometry shared by the terrain, the castle builder, the crowds, the collisions and
// the cutscene.

enum FinaleLayout {
    /// The castle's hilltop (and the courtyard floor).
    static let ground: Float = 42
    /// The hill's flat top, and where its slopes reach the meadows.
    static let plateau: Float = 178
    static let hillFoot: Float = 262
    /// The curtain wall: an octagon (corners at 22.5° + 45°·k from +x), a flat side facing the village.
    static let wallRadius: Float = 118
    static let wallHeight: Float = 15
    static let wallThick: Float = 4
    static let towerRadius: Float = 7.5
    static let towerHeight: Float = 27
    /// The dry ditch outside the wall.
    static let ditchIn: Float = 127, ditchOut: Float = 141, ditchDepth: Float = 8
    /// The gate passage through the middle of the south wall.
    static let gateHalf: Float = 5.5, gateHeight: Float = 12.5
    /// Where the gate's opening sits (centre of the south side).
    static var gateZ: Float { wallRadius * cos(.pi / 8) }

    // The great hall: long axis along z, doors at the south end, throne at the north.
    static let hallHalfW: Float = 17
    static let hallSouth: Float = -6, hallNorth: Float = -78
    static let hallWall: Float = 24
    static let hallRidge: Float = 42
    static let doorHalf: Float = 6.5, doorHeight: Float = 16
    /// The opening in the roof over the dais (the Crown Lantern stands round it): the way out for the jetpack.
    static let lanternZ: Float = -60, lanternHalf: Float = 7
    /// The lantern's drum: radius (to its corners), and the top of it, a little above the ridge.
    static let lanternRadius: Float = 8.4
    /// Half-size of the square cut in the roof inside the drum (the largest that fits inside the octagon).
    static let lanternOpening: Float = 5.4
    static var lanternTop: Float { ground + hallRidge + 4 }
    /// The dais and the throne.
    static let daisFront: Float = -62, daisBack: Float = -77, daisHeight: Float = 1.6
    /// The columns down both sides of the nave.
    static let columnX: Float = 10
    static let columnZs: [Float] = [-14, -22, -30, -38, -46, -54]
    /// The Sky Tower behind the hall: the tallest thing on the island.
    static let skyTower = SIMD2<Float>(0, -92)
    static let skyTowerRadius: Float = 9.5, skyTowerHeight: Float = 96

    // Outside the walls.
    static let village = SIMD2<Float>(0, 660)
    static let villageRadius: Float = 165
    static let villageY: Float = 6
    static let roadHalf: Float = 7
    static let lake = SIMD2<Float>(70, -600), lakeRadii = SIMD2<Float>(390, 230)
    static let islandRadius: Float = 2350

    /// The eight corners of the curtain wall (towers), on the hilltop.
    static var corners: [SIMD3<Float>] {
        (0..<8).map { k in
            let a = Float.pi / 8 + Float(k) * .pi / 4
            return SIMD3(cos(a) * wallRadius, ground, sin(a) * wallRadius)
        }
    }

    /// The road's height at z (it climbs from the village to the gate), or nil off the road.
    @inline(__always) static func roadY(_ x: Float, _ z: Float) -> (y: Float, k: Float)? {
        guard z > ditchOut - 2, z < village.y - 60, abs(x) < roadHalf * 2.2 else { return nil }
        let y = lerp(villageY + 1, ground, smoothstep(village.y - 110, plateau + 6, z))
        return (y, smoothstep(roadHalf * 2.2, roadHalf, abs(x)))
    }

    /// Inside the castle walls (the courtyard)?
    @inline(__always) static func insideWalls(_ x: Float, _ z: Float) -> Bool { octagonApothem(x, z) < wallRadius * cos(.pi / 8) - wallThick / 2 }

    /// Distance from the castle centre measured toward the octagon's sides (the wall line is a constant).
    @inline(__always) static func octagonApothem(_ x: Float, _ z: Float) -> Float {
        var best: Float = 0
        for k in 0..<8 {
            let a = Float(k) * .pi / 4 + .pi / 2
            best = max(best, x * cos(a) + z * sin(a))
        }
        return best
    }

    /// Inside the great hall (its floor area)?
    @inline(__always) static func insideHall(_ p: SIMD3<Float>) -> Bool {
        abs(p.x) < hallHalfW - 0.6 && p.z < hallSouth - 0.6 && p.z > hallNorth + 0.6 && p.y > ground - 1 && p.y < ground + hallWall
    }

    /// The roof's underside height over a point in the hall (pitched, ridge along z).
    @inline(__always) static func roofY(_ x: Float) -> Float { ground + hallWall + (hallRidge - hallWall) * (1 - abs(x) / (hallHalfW + 1.5)) }

    /// The way in for the cutscene: road, drawbridge, gate, courtyard, doors, carpet, dais.
    static let processional: [SIMD3<Float>] = [
        SIMD3(0, ground, 190), SIMD3(0, ground, 150), SIMD3(0, ground, 112), SIMD3(0, ground, 60), SIMD3(0, ground, 6),
        SIMD3(0, ground, -20), SIMD3(0, ground, -56), SIMD3(0, ground + daisHeight, -63),
    ]
}
