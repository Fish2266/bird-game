# Bird Game

Fly a bird by flapping your arms in front of your Mac's camera.

## Install (no coding needed)

You need a Mac running **macOS 14 Sonoma or newer** with a camera (Apple Silicon or Intel).

1. **Download** `BirdGame-0.2.dmg` from the [latest release](https://github.com/Fish2266/bird-game/releases/latest)
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
| Open your mouth all the way | Attack the bird you're locked on to (in fights, or LAN games with PvP on) |

Keyboard works too: ←→ bank, ↑↓ pitch, space flap, shift dive, Return or E attack.
R recalibrate · C camera preview · H help · N restart / race again · J accept an invite · M mute · F full screen.

## Worlds

Unlock worlds with coins in the pause menu (Esc → Worlds). In Free Roam all worlds are endless.

| World | Cost | Rings | Ring boost | Hazards |
|---|---|---|---|---|
| Home Isles | free | ×1 | +18 km/h | none — the original, unchanged sandbox |
| Volcano | 250 | ×2 + streak | +36 km/h | lava geysers (they rumble and glow first), lava lakes. Hot air over lava gives free lift. |
| Glow Caves | 400 | ×3 + streak | +22 km/h | tunnel walls and ceilings; rings follow the tunnels |
| Dogfight | 600 | ×3 + streak | +43 km/h | WWI biplanes that line up (“Plane on your tail!”) and fire bursts |

In challenge worlds, consecutive rings build a **streak** (up to ×3 coins). Getting hit knocks you back,
resets your streak and costs coins (lava 5, bullets 3, hard wall hits 2). Storm Coast, Slot Canyon,
Frozen Peaks and Sky Islands are listed as coming soon.

## Game modes

Pick a mode and a map in the pause menu (Esc → Play). Every mode works on all four maps, alone or over LAN,
and every mode pays out coins (scaled by your bird's Luck).

| Mode | What it is |
|---|---|
| Free Roam | The original game: endless rings. Unchanged in single player. |
| Ring Race | A fixed course of 16 rings. Every ring you miss adds 5 seconds. Race your ghost and chase bronze, silver and gold medal times. |
| Speed Race | Follow the glowing sky road through checkpoints. Stray too far and you're put back on the course. Ghost and medals too. |
| PvP Fight | Three lives each; last bird flying wins (after 5 minutes, most lives then health). Single player fights 1–5 bots (Easy / Normal / Hard) matched to your bird. The arena wall closes in after 45 s; green health orbs (+35) float around the arena. Out of lives? Watch the rest with ← → to switch birds. |

Race courses are the same every time, so best times mean something. Each map has its own obstacles
(race and fight modes only; the free-roam worlds are untouched):

| Map | Obstacles |
|---|---|
| Home Isles | wind turbines with spinning blades, sea-stack slaloms, stone arches (floating sky-rock versions up high) |
| Volcano | lava geysers beside the course that erupt in turn, basalt column clusters, plus the world's own geysers |
| Glow Caves | stalactite crushers that slam down, glowing crystal columns |
| Dogfight | a barn to fly straight through, farm windmills, barrage balloons on cables, grain silos — and the biplanes still hunt you in every mode |

All race courses also have blue boost rings. Medals pay extra coins — double the first time you earn a new one on a course.

## LAN multiplayer

No server needed: one player hosts and the others join over the same Wi-Fi / network (up to 8 birds).
Open Esc → LAN, set your name and nametag color, and click **Go online**. Then either **Host a game** or **Join** one
from the list. Hosts can invite anyone else who is online (they get a "press J to join" banner) and kick players.

The host picks the mode and map in the Play tab (everyone switches with them) and starts each race or fight round
(Start round in the LAN or Play tab, or N). Host settings (all on by default):

- **Collisions**: flying into someone knocks them flying. Your Ram stat sets how hard you hit, their Weight how much they shrug off.
- **PvP**: attacks work in every mode (in Free Roam and races you respawn after being knocked out).
- **Show location**: everyone glows through walls, with a colored marker far away and a compass in the corner.

macOS asks to allow **Local Network** access the first time you go online — allow it, or other players can't reach you
(System Settings › Privacy & Security › Local Network).

## Birds

Pricier birds are better overall, but every bird has its own shape and its own attack. Cheaper birds also have a
lower upgrade cap per stat.

| Bird | Cost | Power | Dive | Agility | Glide | Luck | Weight | Ram | Attack | Upgrades / stat | Attack |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Seagull | free | 5 | 5 | 5 | 5 | 5 | 4 | 4 | 3 | 2 | Pebble Shot — one curving pebble |
| Sparrow | 50 | 7 | 3 | 10 | 4 | 6 | 2 | 3 | 5 | 3 | Seed Spray — shotgun burst |
| Albatross | 120 | 4 | 6 | 3 | 10 | 6 | 9 | 4 | 3 | 3 | Gale Gust — huge knockback |
| Peregrine Falcon | 200 | 6 | 10 | 8 | 4 | 5 | 5 | 9 | 5 | 4 | Razor Feathers — fast 3-shot burst |
| Golden Eagle | 350 | 9 | 7 | 6 | 7 | 6 | 8 | 7 | 7 | 4 | Homing Missiles |
| Phoenix | 700 | 9 | 9 | 8 | 8 | 9 | 7 | 7 | 10 | 5 | Phoenix Fire — homing fireballs that burn |

Upgrades cost 10 / 20 / 35 / 55 / 80 coins. Attack upgrades add damage and reload speed (and an extra projectile at 13+).

**Fighting:** your bird automatically locks on to the best target in a wide cone ahead (red brackets = in range).
Open your mouth wide (or press Return) and your attack homes in on it — you just need to be roughly facing them.
Back-to-back hits only shove you a little, so you're never juggled out of control, and ramming only hurts when it's a
real high-speed dive-bomb. In Dogfight fights, plane bullets and lava hurt too.

**Turning upgrades off:** in the Birds tab, pick a stat with ↑↓ (or the ‹ › buttons) and press ← to turn one bought
upgrade off — handy if a maxed-out Dive Speed is too much for a twisty course. → turns it back on for free.
(0.1 saves are converted automatically; levels above a bird's new cap are refunded.)

Snowy Owl and Hummingbird are coming soon. Progress is saved automatically.

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
- `--render-test <dir> [seconds] [bird] [world] [mode]` with a mode (`ringRace`, `speedRace`, `pvp`) flies the course / fights the bots with a test pilot.
- `--net-test` runs a host and two guests in one process over real Bonjour/TCP (join, sync, attacks, rounds, invite, kick).
  Set `BIRD_LOOPBACK=1` to keep it on loopback (a freshly signed build hasn't been granted Local Network access yet).
- `--scenario-test` checks race and fight flows headless (countdown, pause, ghost, medals, off-course, lives, orbs, spectating).
- `--pvp-sim [bird] [world] [seconds] [demo|chase]` plays a fight against the bots headless and prints a summary.
- `--gallery <dir> [world]` renders every race gate and obstacle for checking looks.
- `--demo --no-autopause --host-lan ringRace --auto-start 8` and `--demo --no-autopause --join-lan` run a LAN game between two copies on one Mac.
- `--audio-test <file.wav>`, `--menu-snapshot <file.png>`, `--hud-snapshot <file.png>` check sound and UI offscreen.
