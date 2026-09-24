# Bird Game

Fly a bird by flapping your arms in front of your Mac's camera.

## Install (no coding needed)

You need a Mac running **macOS 14 Sonoma or newer** with a camera (Apple Silicon or Intel).

1. **Download** `BirdGame-0.1.dmg` from the [latest release](https://github.com/Fish2266/bird-game/releases/latest)
   (click the file under **Assets**).
2. **Open** the downloaded file (it's in your Downloads folder). A window appears.
3. **Drag** the **Bird Game** icon onto the **Applications** folder in that window.
4. **Open Bird Game** from your Applications folder (or search for it with Spotlight: ⌘ + Space, type "Bird Game").

### "Bird Game Not Opened" / "Apple could not verify…"

This is normal the first time. The game is free and made by one person, so it isn't registered with Apple.
You only need to do this once:

1. Click **Done** on the message.
2. Open **System Settings** (Apple menu  → System Settings) → **Privacy & Security**.
3. Scroll down. Next to *"Bird Game" was blocked…*, click **Open Anyway**, then enter your Mac password.
4. Click **Open Anyway** once more. From now on it opens normally.

When it asks to use the camera, click **Allow** — that's how it sees you flap.

## Play

Allow camera access the first time. Stand ~2 m back so both hands are in the camera preview
(bottom-right), then hold your arms out like wings for a second to calibrate.

## Controls

| Your arms | The bird |
|---|---|
| Flap down (bigger / faster = more power) | Thrust + climb |
| One arm up, the other down (or lean) | Bank and turn |
| Both arms raised a little | Nose up (trades speed for height) |
| Both arms lowered a little | Nose down |
| Arms pinned to your sides | Tuck and dive |

Keyboard works too: ←→ bank, ↑↓ pitch, space flap, shift dive.
R recalibrate · C camera preview · H help · N restart · M mute · F full screen.

## Worlds

Unlock worlds with coins in the pause menu (Esc → Shop → Worlds). All worlds are endless.

| World | Cost | Rings | Ring boost | Hazards |
|---|---|---|---|---|
| Home Isles | free | ×1 | +18 km/h | none — the original, unchanged sandbox |
| Volcano | 250 | ×2 + streak | +36 km/h | lava geysers (they rumble and glow first), lava lakes. Hot air over lava gives free lift. |
| Glow Caves | 400 | ×3 + streak | +22 km/h | tunnel walls and ceilings; rings follow the tunnels |
| Dogfight | 600 | ×3 + streak | +43 km/h | WWI biplanes that line up (“Plane on your tail!”) and fire bursts |

In challenge worlds, consecutive rings build a **streak** (up to ×3 coins). Getting hit knocks you back,
resets your streak and costs coins (lava 5, bullets 3, hard wall hits 2). Storm Coast, Slot Canyon,
Frozen Peaks and Sky Islands are listed as coming soon.

## Birds

| Bird | Cost | Power | Dive | Agility | Glide | Luck |
|---|---|---|---|---|---|---|
| Seagull | free | 5 | 5 | 5 | 5 | 5 |
| Sparrow | 50 | 6 | 3 | 9 | 3 | 5 |
| Albatross | 120 | 4 | 6 | 3 | 10 | 5 |
| Peregrine Falcon | 200 | 5 | 10 | 7 | 4 | 4 |
| Golden Eagle | 350 | 8 | 7 | 5 | 7 | 6 |
| Phoenix | 700 | 9 | 9 | 8 | 8 | 9 |

Each stat can be upgraded 5 times (10 / 20 / 35 / 55 / 80 coins). Snowy Owl and Hummingbird are coming soon.
Progress is saved automatically.

## Camera

The app picks each camera's widest, uncropped mode (on the built-in FaceTime HD camera: the
full-sensor 1760×1328 mode instead of the cropped 16:9 default) and turns off Center Stage.

## Build from source

Needs Xcode (or its command line tools) on macOS 14+.

```
./build.sh              # builds "Bird Game.app"
open "Bird Game.app"
./release.sh            # builds and packages dist/BirdGame-<version>.dmg
```

The version number lives in `Info.plist` (`CFBundleShortVersionString`); the settings screen and About box read it
from there, so bump it in that one place. The app icon is `Resources/AppIcon.icon` (Icon Composer).

## Debugging

- Tracking stats (no images) are logged to `~/Library/Logs/BirdGame.log`.
- `"Bird Game.app/Contents/MacOS/BirdGame" --demo [--world volcano|caves|dogfight]` flies a scripted player.
- `--render-test <dir> [seconds] [bird] [world]` renders frames offscreen and prints flight telemetry.
- `--dogfight-test` measures how often planes hit a bird flying straight.
- `--audio-test <file.wav>`, `--menu-snapshot <file.png>`, `--hud-snapshot <file.png>` check sound and UI offscreen.
