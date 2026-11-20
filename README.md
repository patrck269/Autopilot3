# Autopilot 3.0

A ComputerCraft autopilot for a Valkyrien Skies bomber that flies on ten Create Crafts & Additions electric motors driving Clockwork propellers. It flies with the Autopilot 2.0 controller. It climbs to a typed block height and holds it, learning hover power on its own at any height. Four lift corners keep the hull level. It flies a bearing at a set speed up to 35 m/s, with the target speed reached through a ramp that arrives within 15 s, and slows down with reverse thrust. It drops bombs in salvos from a 46-bomb bay. Fighter-style MFDs run on every monitor, and commands are typed on the terminal.

Needs CC: Tweaked and CC:VS (`ship` and `aero` APIs). Everything runs on one computer.

## Hardware

| Motor | Label | Role | Cap |
|---|---|---|---|
| `electric_motor_7` | E7 | Lift, bow port (puller) | 0–5500 |
| `electric_motor_2` | E2 | Lift, bow starboard (puller) | 0–5500 |
| `electric_motor_5` | E5 | Lift, stern port (puller) | 0–5500 |
| `electric_motor_3` | E3 | Lift, stern starboard (puller) | 0–5500 |
| `electric_motor_6` | R6 | RCS, bow port (puller) | 0–4000 |
| `electric_motor_1` | R1 | RCS, bow starboard (puller) | 0–4000 |
| `electric_motor_4` | R4 | RCS, stern port (puller) | 0–4000 |
| `electric_motor_0` | R0 | RCS, stern starboard (puller) | 0–4000 |
| `electric_motor_8` | L8 | Port pusher on the stern, facing aft. Positive RPM moves the ship forward; negative is reverse thrust | ±3000 |
| `electric_motor_9` | S9 | Starboard pusher on the stern, facing aft | ±3000 |

| Relay | Role |
|---|---|
| `redstone_relay_59` | Bomb bay doors. Every side on opens them |
| `redstone_relay_13` to `redstone_relay_58` | One bomb each. Every side is pulsed to drop it |

Each motor gets its own RPM, and the motors draw no rotational load from a shared engine. Names, caps, and a per-motor `sign` flip are in `ap3/config.lua`, along with the relay prefix. The MFDs use every attached monitor (`monitors = {}`); list monitor names there to use only some.

## Install

On computer 12, run one line in the shell (not the Lua prompt):

```
wget run https://raw.githubusercontent.com/patrck269/Autopilot3/master/install.lua [commit]
```

The installer looks up the latest commit, downloads every file from that exact commit, and reboots. If any download fails, nothing on the computer changes. An existing `startup.lua` or `ap3/config.lua` that differs from the new one is kept as `.bak`, so copy any peripheral-name edits back from `ap3/config.lua.bak`. Re-run the same line to update. Add a commit SHA to install that exact version. The installed commit is written to `ap3/VERSION`.

## Start-up checks

At start-up the flight loop checks the ship API, a wired modem, and all ten motors. Anything missing is listed on the terminal and on every MFD. Nothing is written to the motors until the list is clear; the flight loop then starts on its own as soon as the missing device is attached. Missing bomb relays are only warnings: the ship still flies, and drops are refused while the door relay is missing. On start the flight loop switches every relay output off.

## DEBUG direction check

Before the first flight, land and type `debug` (or SYS: DEBUG then CONF DEBUG). Every motor turns at +15 RPM as written to the block. Positive RPM must pull on all four lift corners and all four RCS corners, and push both pushers forward. A motor that turns backwards gets `sign = -1` in `ap3/config.lua`; restart the computer after editing. Then lift off in HOVER and type `rcs check` once: DEBUG shows which way each corner pulls, but not *where* each motor sits.

The bow axis doesn't have to be right in `frame.forward` (default +X). The flight loop checks it against which way the pushers push the hull (not the RCS, which would mislead it if its corner labels were wrong). It snaps the result to the block grid; if that differs, it switches to it while keeping the ship pointing where it is, and remembers it. SYS shows "BOW AXIS CORRECTED: HEADING NOW TRUE", and CAL shows the axis as learned. Until the axis is confirmed, the sideways brake is held to 5% of full RCS force, the pushers to 25% of full force (what 1500 RPM gives), and the lift corners are not levelled. The confirmed axis is saved, so later flights use the full range from the start.

### RCS check

If the heading isn't held and the ship strafes when it should turn, the RCS corner labels are probably wrong. For example, if R4 really sits at stern *starboard*, the "right turn" pair (bow starboard + stern port) pulls both starboard corners and the ship strafes. SYS then shows "TURN COMMANDS DO NOT TURN THE SHIP: RUN 'rcs check'".

In HOVER, type `rcs check` (or SYS: RCS CHECK, then CONF CHECK). Each of the four RCS motors pulls at 1000 RPM for 4 s, one at a time, about 45 s in all. The lift holds altitude; heading, sideslip and the pushers rest. For each motor it measures which way the hull slides and turns. The side it slides toward is its side. Of the two on a side, the bow one swings the nose toward that side more than the stern one does. The SYS event log shows each reading and the result:

- "RCS LAYOUT MATCHES CONFIG": nothing to do.
- "RCS LAYOUT DIFFERS", with e.g. "STERN_STBD IS R4": type `rcs apply` (or SYS: RCS APPLY). The layout is saved with the calibration and the computer restarts with it. The lift keeps spinning, so it takes over in HOVER. The saved layout overrides the RCS motor names in `ap3/config.lua` and survives reinstalls.
- "RCS CHECK UNCLEAR": a corner didn't move the hull clearly; nothing changes.

If the sideways brake runs for 10 s and the drift has grown, it stops and SYS shows "SIDEWAYS BRAKE STOPPED: IT MADE THE DRIFT WORSE". That means a wrong bow axis or wrong corner labels. It starts again on the next HOVER or CRUISE engagement.

## Flying

| Command (terminal) | MFD | Effect |
|---|---|---|
| `alt 150` | AP: ALT ±1/±10, UFC: ALT SET | Target altitude (world Y) |
| `brg 90` | AP: BRG ±5, HSI: BRG ±1/±10/SYNC, UFC: BRG SET | Target bearing, 0 = N, 90 = E |
| `spd 30` | AP: SPD ±1/±5, UFC: SPD SET | Target speed, clamped to 0–35 m/s |
| `hover` | HOVR | Climb or descend to the altitude and hold it. Brake to a stop, hold heading, cancel drift |
| `cruise` | CRZ | Altitude, bearing, and speed together |
| `stby` | STBY | Autopilot off: pushers and RCS to 0, lift left as it is |
| `kill` | SYS: KILL then CONF KILL | Every motor to 0 immediately |
| `debug` | SYS: DEBUG then CONF DEBUG | Every motor at +15 RPM as written to the block (config `sign` not applied), to see which way each prop pushes. **The lift drops to 15 RPM too, so an airborne ship falls.** Learning is paused. Leave with any other mode |
| `sync` | PFD: SYNC | Targets become the current altitude and heading |
| `recal` | CAL: RECAL then CONF | Forget the hover calibration: back to the 430 RPM first guess, learned again in flight |
| `rcs check` | SYS: RCS CHECK then CONF CHECK | In HOVER: find which motor sits at which RCS corner (see RCS check) |
| `rcs apply` | SYS: RCS APPLY | Use the layout the check found; saved, then the computer restarts |
| `rcs reset` | CAL: RCS RESET then CONF | Forget the learned RCS turning and sideways strength: back to the first guesses, learned again in flight. The corner layout from `rcs apply` and the bow axis stay |
| `rcs off` / `rcs on` | SYS: RCS OFF / RCS ON | Hand steering to the Eureka helm: the RCS rests at 0 and the heading loop stops. `rcs on` takes it back and holds the heading the ship is on. The setting survives a reboot (`/ap3_rcs.off`) |
| `doors open` / `doors close` | BOMB: DOOR OPEN / DOOR CLOSE | Bomb bay doors |
| `salvo 1` (`3`, `5`, `10`, `all`) | BOMB: 1 3 5 10 ALL | Bombs per drop |
| `drop` | BOMB: DROP | Drop one salvo (see Bomb bay) |
| `reload` | BOMB: RELOAD then CONF RELOAD | Mark every bomb loaded again |

Type `help` for the list. If the computer reboots while the lift is spinning, it takes over in HOVER at the current altitude.

## Bomb bay

The bay holds 46 bombs in two rows of 23. Bay row 1 is at the bow. The port row runs 14 to 34 from the bow, then 13, then 35; the starboard row runs 58 down to 36 from the bow. So the numbering starts at 14 in the port-bow corner and runs counterclockwise, with 13 between 34 and 35.

A drop is refused, with the reason on the BOMB page and in the reply, when:

- the door relay is missing, the doors are closed, or they opened less than 3 s ago
- the ship is below Y 200
- the last salvo was less than 5 s ago
- a drop is still in progress
- fewer bombs are left than the salvo size

A salvo fires at once: every trigger relay of the salvo turns on all six sides for 0.5 s. The bombs are picked as far apart as the bay allows (largest smallest distance between any two, then the most even remaining load). The used bombs and the salvo size are saved to `/ap3_bombs.dat` before any trigger fires, so a crash mid-drop never re-drops a bomb. The doors close on their own 10 s after the trigger pulse ends.

## MFDs

Each monitor is one MFD with option-select buttons around the edge. Top-row and side buttons belong to the page on screen. The bottom row is **MENU**, three format buttons (the lit one is shown), and **SWAP**.

- A format button shows that page. Pressing the lit one, or MENU, opens the format menu, which lists every page.
- A page is only shown on one MFD at a time. Picking a page that another MFD is showing moves it here and sends this MFD's old page there.
- SWAP exchanges two MFDs: 1↔2 and 3↔4, with an odd last display swapping with display 1.
- The layout is saved (`/ap3_mfd.dat`) and comes back after a reboot.
- A monitor reached under two names (touching the computer and also wired to a modem) carries one MFD; SYS lists the second name.
- Pages fit any monitor size: they draw only inside the area between the buttons. On narrow monitors (two blocks wide) AP, CAL, PFD and HSI move their extra columns onto extra lines, and on a narrow, tall one BOMB stands the bay map upright with the bow at the top.

At first start, display 1 shows PFD, display 2 BOMB, display 3 HSI and display 4 ENG.

| Page | Shows |
|---|---|
| PFD | Attitude (pitch ladder, roll), heading and bearing, ground and forward speed, altitude, target, vertical speed, altitude and speed phases |
| AP | Mode, every target against its actual value, bearing error, speed reference, hover RPM here and at the target, alerts |
| HSI | Heading-up compass rose with bearing bug and track, ground speed, drift, X/Z position |
| ENG | Each motor's applied and desired RPM against its cap. Red: missing. A red bar: the last write failed |
| BOMB | Bay map (bow on the left, starboard row on top): lime loaded, yellow in the next salvo, gray used, red relay missing. Bombs loaded, salvo size, doors and how long they have been open, the reason the next drop would be refused or READY. Salvo size, DOOR, DROP and RELOAD buttons |
| CAL | Ground or airborne, sample count, hover RPM here and at target, air density, lift constant, altitude trim, mass, level trim, learned thrust and drag, learned RCS turning and sideways strength, bow axis (learned or config). RECAL and RCS RESET |
| SYS | Flight loop health, start-up errors and warnings, live alerts, event log (RCS check results), RCS OFF/ON, RCS CHECK, RCS APPLY, DEBUG, KILL |
| UFC | Keypad: type a number, then ALT, BRG, or SPD SET |

## How it flies

**Hover calibration.** Clockwork blade thrust is `0.5·ρ·v_tip²·C_L·area`, and tip speed is proportional to RPM, so each corner's lift is `k·ρ(y)·RPM²`. Inflow from climbing is negligible next to tip speed. The flight loop measures vertical acceleration over 1-second windows against the force the four lift props are actually making and refines the single constant `k`. Hover RPM per corner at any height is then `sqrt(g / (k·ρ(h)))`, with `ρ` from `aero.getAirDensity`. The first guess is 430 RPM at sea level. On the ground, while asked to climb, RPM steps up until the hull lifts, so a low guess only costs a slower liftoff; a guess far above the real hover would launch the hull. It only learns in HOVER and CRUISE: a parked ship with the lift turning (STBY after DEBUG leaves it at 15 RPM) would otherwise learn that 15 RPM hovers. A calibration that puts the sea-level hover under `min_hover_rpm` (100) or over the lift cap is never believed: learning stops at those limits, and such a saved value is replaced by the first guess at start-up. The learned values are saved to `/ap3_cal.dat`.

**Altitude.** The altitude error sets a vertical-speed command. That command is capped at 6 m/s up and 5 m/s down, and further limited near the target so the ship can still stop in time. A vertical-speed loop turns it into an acceleration, and the calibration turns that acceleration into one collective lift RPM. The lift props are pullers and never run below 0. Once settled within 0.5 blocks, the lift is held at the calibrated hover RPM (plus its altitude trim) and only recomputed if the hull drifts past 1 block or starts moving.

**Levelling.** The collective lift is spread over the four corners: bow port `L·(1+P−R)`, bow starboard `L·(1+P+R)`, stern port `L·(1−P−R)`, stern starboard `L·(1−P+R)`. `P` and `R` come from a PD loop on pitch and roll (positive pitch is nose up, positive roll is starboard down) plus an integral trim, up to 30% of `L`, that learns an off-centre load such as a half-empty bomb bay. CAL shows the trims. Levelling waits until the bow axis is confirmed, because with `frame.forward` wrong it would tip the hull further.

**Speed.** The speed reference ramps to the target in 12 s and stops 0.5 m/s under the 35 m/s cap. Both pushers always get the same RPM. Control uses normalised force (`RPM²`) with acceleration and drag learned in flight. The pushers can give far more than the ramp needs, and their props take seconds to spin up or down, so the loop asks for at most 1.5 m/s² more or less than the ramp's own acceleration. Slowing down uses negative RPM on the pushers. If acceleration pitches the nose past `pitch_limit` (6°), thrust is held back and the ramp pauses until the nose recovers. Once at cruise speed (within 0.3 m/s), the pusher thrust is held at the RPM that balances drag and only recomputed if the speed drifts 0.5 m/s. Stopped (HOVER), the pushers rest until drift passes 0.8 m/s, brake it under 0.2 m/s, and rest again.

**Heading and sideslip.** The RCS only pulls; no motor ever reverses. For a turn force `u` and a sideways force `s`, each corner gets `max(0, …)` of: bow starboard `u+s`, stern port `u−s`, bow port `−u−s`, stern starboard `s−u`. A pure turn is a diagonal pair (right: bow starboard + stern port; left: bow port + stern starboard), a pure strafe is a same-side pair (both starboard corners pull to starboard), and blends stay proportional. One corner on its own mostly strafes the hull, because the Eureka helm's stabilisation resists the turn.

The bearing error sets a yaw-rate command, and a PI loop on yaw rate (taken from the change in heading between samples) gives a yaw acceleration. The turn profile and integral gain are limited so the ship does not bounce ±2° across a new bearing. The directions are fixed: positive RPM pulls on every corner. Only the turning and sideways *strength* is learned in flight, and commands are divided by it. Turning strength is only learned from half-second windows where the RCS makes at least 0.75% of its full turn force. Weaker windows mostly measure yaw from something else, such as an off-centre thrust line or a bump, and crediting that to a tiny RCS force inflates the strength. An inflated strength shrinks every turn command, and the ship stops turning. The learned value stays between 0.4 and 200 deg/s² at full RCS. A saved value above 200 is discarded at start-up, and learning starts again from the first guess. If the RCS pulls at full for 3 s and the heading is still off, SYS shows "RCS AT FULL: HEADING NOT HELD".

Station keeping: a heading correction starts when the heading is more than 2° off (1° in CRUISE) or the hull turns faster than 0.5°/s, and stops within 0.5°. In between, the RCS holds the trim its integral learned (an off-centre thrust line, say) or rests. Sideways drift over 0.5 m/s, including drift the ship already had when the autopilot took over, is braked with the same-side pair until it is under 0.15 m/s; then the sideways force rests. The smallest RCS pulse is 100 RPM. Heading gets first call on the RCS.

Clockwork props don't follow the motor at once: the bearing changes spin by at most 32 RPM a tick (640 RPM a second), so 0 → 4000 RPM takes about 6 s, and spinning down takes as long. The flight loop models that spin. Every learner uses the force the props are really making, not the commanded RPM. The heading loop gets a lead for turn force still on its way, and the sideslip brake lets go early when the remaining spin will finish the job.

**Motor pacing.** `setSpeed` runs on the server thread and stalls for a tick, so the flight loop only records the RPM each motor should have, and a writer task sends at most one write per tick:

- each motor is written at most once a second. Changes under 5 RPM (lift), 15 (pushers) and 100 (RCS) are skipped, but a start or a stop is always written. One write changes a motor by at most 600 RPM (lift and pushers, about what the props can follow in that second) or 2000 (RCS). Sign reversals pass through 0
- the motors move in groups: the four lift corners, the four RCS corners and the two pushers. A group is written as one batch, motors turning down first, then motors turning up, on consecutive ticks with the values chosen when the batch started. So the pushers never differ for more than a tick and an RCS corner never pulls without its diagonal partner
- a running batch goes first, then the lift, then the group with the largest need
- KILL bypasses all of it: every motor goes to 0 at once

## Limits

- Peripheral names come from the motor and relay numbers in the spec. If SYS lists missing motors or relays, read the real names from the wired modems and edit `ap3/config.lua`.
- If a motor's `getSpeed` doesn't report its RPM, the computer can't tell after a reboot that the lift is spinning, so it doesn't take over in HOVER on its own.
- RCS turning force is capped at 4000 RPM. If the pusher thrust line is far off the centre of mass, the heading can still drift during hard acceleration (SYS shows "RCS AT FULL").
- Gains are tuned against a simulated hull. In-flight learning covers lift, thrust, drag, and RCS strength and direction; the remaining gains are in `ap3/config.lua` if the real hull needs different ones.

## Tests

```
lua tests/test_flight.lua
lua tests/test_install.lua
lua tests/test_bombs.lua
lua tests/test_mfd.lua
python tests/cc/run.py <CraftOS-PC_console.exe>
```

`tests/test_flight.lua` flies the real control modules against `tests/world.lua`, a hull model with the Clockwork thrust law per motor, air density, drag, RCS yaw, thrust misalignment, nose dip, corner lift torque, an off-centre load, prop lag and ground contact. It checks liftoff, climbing and holding at several heights from wrong calibrations, cruise to 30 m/s within 15 s, the 35 m/s cap, reverse-thrust braking, heading hold, the pitch limit, KILL and DEBUG on all ten motors, noisy telemetry, a wrong bow axis, wrong RCS labels with the RCS check, levelling under an off-centre load, and paired pushers.

`tests/test_install.lua` checks that the installer downloads every module `startup.lua` can load. `tests/test_bombs.lua` checks the bay layout, salvo selection, the interlocks, the trigger pulse and door timing, and the bay wrapper (save before fire, bad save files, a missing door relay, salvo sizes). `tests/test_mfd.lua` checks that every display keeps three different formats and every page is on screen at most once, whatever is pressed or loaded.

`tests/cc/run.py` boots the real `startup.lua` in [CraftOS-PC](https://www.craftos-pc.cc) with fake motors, relays and monitors. It presses MFD buttons, types terminal and keypad commands, refuses a drop below Y 200, drops at Y 210 and watches the relays, and checks the missing-peripheral path.
