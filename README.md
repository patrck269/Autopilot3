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
| `electric_motor_6` | R6 | RCS, bow port (puller) | 0–15000 |
| `electric_motor_1` | R1 | RCS, bow starboard (puller) | 0–15000 |
| `electric_motor_4` | R4 | RCS, stern port (puller) | 0–15000 |
| `electric_motor_0` | R0 | RCS, stern starboard (puller) | 0–15000 |
| `electric_motor_8` | L8 | Port pusher on the stern, facing aft. Positive RPM moves the ship forward; negative is reverse thrust | ±10000 |
| `electric_motor_9` | S9 | Starboard pusher on the stern, facing aft | ±10000 |

The 3.0 ships' pusher and RCS props are small: measured on 2026-11-22, both pushers at 10000 RPM give about 32 m/s² and a speed of 20 m/s needs only a few hundred RPM.

**Eureka helm brake: off.** When nobody sits at the helm, Eureka pushes the ship toward a stop with a force capped near 0.84 m/s² (`linearStabilizeMaxAntiVelocity` in the server's `serverconfig/valkyrienskies/vs_eureka.toml`). It cancelled every small thrust (1500 RPM on both pushers only crept the ship at 0.08 m/s), so the server runs with it at `0.0` and the autopilot does all station keeping. Edit that file only while the server is stopped: the server writes its values back on shutdown. Measured with the brake off: about 0.05 m/s² of drag at 35 m/s, so the hull coasts.

| Relay | Role |
|---|---|
| `redstone_relay_59` | Bomb bay doors. Every side on closes them; off opens them |
| `redstone_relay_13` to `redstone_relay_58` | One bomb each. Every side is pulsed to drop it |

Each motor gets its own RPM, and the motors draw no rotational load from a shared engine. Names, caps, and a per-motor `sign` flip are in `ap3/config.lua`, along with the relay prefix. The MFDs use every attached monitor (`monitors = {}`); list monitor names there to use only some.

## Install

On computer 12, run one line in the shell (not the Lua prompt):

```
wget run https://raw.githubusercontent.com/patrck269/Autopilot3/master/install.lua [commit]
```

The installer looks up the latest commit, downloads every file from that exact commit, and reboots. If any download fails, nothing on the computer changes. An existing `startup.lua` or `ap3/config.lua` that differs from the new one is kept as `.bak`, so copy any peripheral-name edits back from `ap3/config.lua.bak`. Re-run the same line to update. Add a commit SHA to install that exact version. The installed commit is written to `ap3/VERSION`.

## Start-up checks

At start-up the flight loop checks the ship API, a wired modem, and all ten motors. Anything missing is listed on the terminal and on every MFD. Nothing is written to the motors until the list is clear; the flight loop then starts on its own as soon as the missing device is attached. Missing bomb relays are only warnings: the ship still flies, and drops are refused while the door relay is missing. On start the flight loop switches bomb triggers off and the door relay on to close the doors.

## DEBUG direction check

Before the first flight, land and type `debug` (or SYS: DEBUG then CONF DEBUG). Every motor turns at +15 RPM as written to the block. Positive RPM must pull on all four lift corners and all four RCS corners, and push both pushers forward. A motor that turns backwards gets `sign = -1` in `ap3/config.lua`; restart the computer after editing. Then lift off in HOVER and type `rcs check` once: DEBUG shows which way each corner pulls, but not *where* each motor sits.

The bow axis doesn't have to be right in `frame.forward` (default +X). The flight loop checks it against which way the pushers push the hull (not the RCS, which would mislead it if its corner labels were wrong). It snaps the result to the block grid; if that differs, it switches to it while keeping the ship pointing where it is, and remembers it. SYS shows "BOW AXIS CORRECTED: HEADING NOW TRUE", and CAL shows the axis as learned. Until the axis is confirmed, the sideways brake is held to 20% and the lift corners are not levelled. The confirmed axis is saved, so later flights level from the start.

### RCS check

If the heading isn't held and the ship strafes when it should turn, the RCS corner labels are probably wrong. For example, if R4 really sits at stern *starboard*, the "right turn" pair (bow starboard + stern port) pulls both starboard corners and the ship strafes. SYS then shows "TURN COMMANDS DO NOT TURN THE SHIP: RUN 'rcs check'".

In HOVER, type `rcs check` (or SYS: RCS CHECK, then CONF CHECK). Each of the four RCS motors pulls at 2000 RPM for 4 s, one at a time, about 45 s in all. The lift holds altitude; heading, sideslip and the pushers rest. For each motor it measures which way the hull slides and turns. The side it slides toward is its side. Of the two on a side, the bow one swings the nose toward that side more than the stern one does. The SYS event log shows each reading and the result:

- "RCS LAYOUT MATCHES CONFIG": nothing to do.
- "RCS LAYOUT DIFFERS", with e.g. "STERN_STBD IS R4": type `rcs apply` (or SYS: RCS APPLY). The layout is saved with the calibration and the computer restarts with it. The lift keeps spinning, so it takes over in HOVER. The saved layout overrides the RCS motor names in `ap3/config.lua` and survives reinstalls.
- "RCS CHECK UNCLEAR": the observations do not identify one layout; nothing changes. A bearing change still counts as evidence when sideways motion is too small. With outward-facing pullers, right yaw indicates bow starboard or stern port (`BS/SP`); left yaw indicates bow port or stern starboard (`BP/SS`). Other corners' slide measurements can resolve the remaining choice. Yaw alone cannot distinguish a misplaced motor from reversed thrust, so it never saves an arbitrary layout.

For yaw-only responses, the log also reports the lateral pull direction **if the named mounting location is correct**. For example, a right turn from a correctly mounted bow-port motor indicates a starboard pull, not its expected port pull. This is a direction warning, not proof that its mounting label is correct.

If the sideways brake runs for 10 s and the drift has grown, it stops and SYS shows "SIDEWAYS BRAKE STOPPED: IT MADE THE DRIFT WORSE". That means a wrong bow axis or wrong corner labels. It starts again on the next HOVER or CRUISE engagement.

## Flying

| Command (terminal) | MFD | Effect |
|---|---|---|
| `alt 150` | AP: ALT ±1/±10, UFC: ALT SET | Target altitude (world Y) |
| `brg 90` | AP: BRG ±5, HSI: BRG ±1/±10/SYNC, UFC: BRG SET | Target bearing, 0 = N, 90 = E |
| `spd 30` / `spd -5` | AP: SPD ±1/±5, UFC: SPD SET | Signed target speed, clamped to −35…+35 m/s. Negative backs up while keeping the bow on the selected bearing; engage CRUISE to drive it. In NAV it sets the transit speed instead (5…35 m/s) |
| `spd 0` | AP: SPD 0, between SPD +1 and SPD −1 | Brake to a stop and rest the pushers while retaining altitude/heading control. With `rcs off`, release the pushers instead of station-keeping braking |
| `hover` | HOVR | Climb or descend to the altitude and hold it. Brake to a stop, hold heading, then hold the point where the ship came to rest (fore/aft with the pushers, sideways with the RCS) |
| `cruise` | CRZ | Altitude, bearing, and speed together |
| `stby` | STBY | Autopilot off: pushers and RCS to 0, lift left as it is |
| `kill` | SYS: KILL then CONF KILL | Every motor to 0 immediately |
| `debug` | SYS: DEBUG then CONF DEBUG | Every motor at +15 RPM as written to the block (config `sign` not applied), to see which way each prop pushes. **The lift drops to 15 RPM too, so an airborne ship falls.** Learning is paused. Leave with any other mode |
| `sync` | PFD: SYNC | Targets become the current altitude and heading |
| `recal` | CAL: RECAL then CONF | Forget the hover calibration: back to the 430 RPM first guess, learned again in flight |
| `rcs check` | SYS: RCS CHECK then CONF CHECK | In HOVER: find which motor sits at which RCS corner (see RCS check) |
| `rcs apply` | SYS: RCS APPLY | Use the layout the check found; saved, then the computer restarts |
| `rcs reset` | CAL: RCS RESET then CONF | Forget the learned RCS turning and sideways strength: back to the first guesses, learned again in flight. The corner layout from `rcs apply` and the bow axis stay |
| `rcs off` / `rcs on` | SYS: RCS OFF / RCS ON | Hand horizontal station keeping to the Eureka helm: corner RCS rests at 0, heading/sideslip control stops, and the pushers stop braking fore/aft drift in HOVER or zero-speed CRUISE. Nonzero CRUISE propulsion and altitude hold stay active. `rcs on` resumes from the current speed and heading. The setting survives a reboot (`/ap3_rcs.off`) |
| `doors open` / `doors close` | BOMB: DOOR OPEN / DOOR CLOSE | Bomb bay doors |
| `salvo 1` (`3`, `5`, `10`, `all`) | BOMB: 1 3 5 10 ALL | Bombs per drop |
| `drop` | BOMB: DROP | Drop one salvo (see Bomb bay) |
| `reload` | BOMB: RELOAD then CONF RELOAD | Mark every bomb loaded again |
| `goto X Z [Y] [BRG]` / `goto <name>` | — | NAV to a world point (see Navigation). It cruises at Y 500 or higher and descends to Y over the point; without Y it stays at the cruise altitude. With BRG the ship turns to it there |
| `wp save <name>` / `wp del <name>` / `wp list` | — | Named waypoints: the current position, altitude and heading (up to 30, saved in `/ap3_nav.dat`) |
| `route add X Z [Y] [BRG]` / `route add <name>` | — | Append a leg to the stored route (up to 20). A leg with BRG is a stop; others are flown through |
| `route go` / `route clear` / `route list` | NAV: NAV GO, CLR ROUTE then CONF CLEAR | Fly the stored route (it is kept), empty it, or show it |
| `rec on` / `rec off` | — | Flight recorder (see Flight recorder) |
| `dock fwd 5` (`aft`, `port`, `stbd`, `up`, `down`), `dock turn -10`, `dock here` | DOCK: STEP 1/2/5/10, FWD/AFT/PORT/STBD, UP/DOWN, BRG −/+, HOLD HERE | Docking: hold a point N blocks along one ship axis, or turn N degrees in place (see Docking) |

Type `help` for the list. It pages to fit the terminal: up/down, PgUp/PgDn or the mouse wheel scroll it, `help 2` opens page 2 and Enter closes it. If the computer reboots while the lift is spinning, it takes over in HOVER at the current altitude (NAV never resumes on its own).

## Navigation

`goto` and `route go` fly in NAV mode. They need RCS on, the ship in the air and a confirmed bow axis (cruise forward once on a new hull). While NAV flies, `alt`, `brg` and `sync` are refused; `hover` (or any other mode) takes over and ends NAV, and `rcs off` drops it to HOVER.

Each leg climbs first and descends last. The ship cruises at the highest of its altitude, the leg's Y and Y 500 (`nav.min_transit_alt`, above the reach of ground Warium fire), and only descends to a stop's Y once it is within 3 blocks of it. A stop without Y is held at the cruise altitude.

| Phase | What happens |
|---|---|
| CLIMB | Climb (or stay) at the transit altitude while turning toward the point; no forward speed |
| TRANSIT | Bow on the point at the NAV speed (25 m/s, `spd` changes it). Speed follows a 0.5 m/s² braking profile that reaches 0 four blocks short of the next stop; no forward speed while the bow is more than 20° off the course. A fly-through leg hands over to the next one 12 blocks out |
| HOLD | Inside 8 blocks of a stop: station keeping moves the hull onto the point without turning (pushers fore/aft up to 2 m/s, RCS sideways up to 1.5 m/s) and holds it within 0.5 blocks. The ship then descends and turns to the stop's bearing. Within 1 block, at the bearing and altitude for 3 s, the next leg starts |
| ARRIVED | The last stop is reached; the ship keeps holding there |

A stop closer than 24 blocks when its leg starts is reached in HOLD alone, sideways or backwards if need be, without the climb to Y 500 (that is not a cruise). A stop without a bearing keeps the heading the ship had when it got there. The last leg of a route is always a stop.

### Docking

The DOCK page (through MENU) moves the held point by the selected step: 1, 2, 5 or 10. FWD, AFT, PORT and STBD move it that many blocks along the ship's bow or beam, taken from the bearing being held, not the momentary heading. UP and DOWN move it that many blocks in Y. BRG − and BRG + turn the held bearing that many degrees, in place. HOLD HERE holds the current position. The same moves are typed as `dock fwd 5`, `dock turn -10` or `dock here`.

- **Where a move starts:** in HOVER, from the current position, target altitude and bearing. In a NAV hold (HOLD or ARRIVED at the last leg), from the held point, so repeated presses add up exactly: three FWD 10 presses hold 30 blocks ahead.
- **How it flies:** the new point is held in NAV by translation alone, however far it is: no climb to Y 500 and no turn toward it. A lower Y is reached once within 3 blocks of the point.
- **Refused:** in CRUISE, STBY and other modes, and while NAV is still climbing or in transit.
- **Precision:** station keeping holds the point within 0.5 blocks, so a 1-block step moves the hull 1 block.

## Flight recorder

`rec on` writes five rows a second to `/ap3_rec.csv` (overwritten each time) until `rec off`: time, mode, position, API velocity, attitude, yaw rate, targets, speed reference, altitude phase, whether the heading correction and the sideways brake are active, NAV phase and the RPM on all ten motors. The alert list shows RECORDING while it runs. It stops on its own, with "RECORDER FULL", when the computer has under 100 kB free.

On the host, `python tools/rec_analyze.py ap3_rec.csv` prints:

- `PHANTOM_VELOCITY yes|no`: the hull stood still (by position) for 5 s or more while the velocity API read over 0.5 m/s different
- `ALT_P2P`: the largest peak-to-peak altitude error over 30 s or more at one altitude target (climbs and descents left out)
- `HDG_P2P`: the same for heading error in HOVER, counted from the first time the heading is within 2° of the bearing (a commanded turn is not sway)
- `HDG_AFTER_PUSHER` / `HDG_AFTER_LIFT`: the share of HOVER heading corrections that started within 2 s of a pusher (or lift) RPM change

## Host inbox

From the server host, commands can be dropped into the computer's folder in the world save (`computercraft/computer/<id>`): `ap3_host.in` holds terminal-syntax commands, one per line. The flight loop runs them about once a second, deletes the file and appends each reply to `ap3_host.log`. For 15 minutes after the last command it also rewrites `ap3_host.status` every second (mode, position, heading, targets, phases, alerts, recorder rows). `tools/ap3_host.py <folder> send "hover" "rec on"` writes the inbox atomically and prints the replies; `status` and `log` print the other two files.

## Bomb bay

The bay holds 46 bombs in two rows of 23. Bay row 1 is at the bow. The port row runs 14 to 34 from the bow, then 13, then 35; the starboard row runs 58 down to 36 from the bow. So the numbering starts at 14 in the port-bow corner and runs counterclockwise, with 13 between 34 and 35.

A drop is refused, with the reason on the BOMB page and in the reply, when:

- the door relay is missing, the doors are closed, or they opened less than 1 s ago
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
| HSI | Heading-up compass rose with bearing bug, track and (in NAV) a `W` toward the point, ground speed, drift, X/Z position |
| NAV | Leg, phase, the point (name or X,Z), its altitude and bearing, distance, bearing to it and ETA, the HOLD fore/aft and sideways offsets, NAV speed, route length and waypoint names. HOVR/CRZ/STBY, NAV GO (fly the route), CLR ROUTE then CONF CLEAR, SPD ±5. Reached through MENU |
| DOCK | Step size, the held point's offset ahead and to starboard, distance, altitude and heading against target, ground speed and drift. STEP 1/2/5/10, HOLD HERE, FWD/AFT/PORT/STBD, UP/DOWN, BRG −/+ by the step. Reached through MENU |
| ENG | Each motor's applied and desired RPM against its cap. Red: missing. A red bar: the last write failed |
| BOMB | Bay map (bow on the left, starboard row on top): lime loaded, yellow in the next salvo, gray used, red relay missing. Bombs loaded, salvo size, doors and how long they have been open, the reason the next drop would be refused or READY. Salvo size, DOOR, DROP and RELOAD buttons |
| CAL | Ground or airborne, sample count, hover RPM here and at target, air density, lift constant, altitude trim, mass, level trim, learned thrust and drag, learned RCS turning and sideways strength, bow axis (learned or config). RECAL and RCS RESET |
| SYS | Flight loop health, start-up errors and warnings, live alerts, event log (RCS check results), RCS OFF/ON, RCS CHECK, RCS APPLY, DEBUG, KILL |
| UFC | Keypad: type a number, then ALT, BRG, or SPD SET |

Horizontal readouts (`GS`, `FWD`, `DRIFT`, `TRK`) use the change in world X/Z position divided by elapsed sample time. Forward and sideways speed are projected onto the current bow; reverse movement gives negative `FWD`. The first sample shows `---` until a second position establishes speed. `REF` is the controller's ramped speed command, not measured movement. This changes display measurement only: flight control and vertical speed still use the CC:VS velocity API, so this does not repair an inaccurate API reading for control.

## How it flies

**Hover calibration.** Clockwork blade thrust is `0.5·ρ·v_tip²·C_L·area`, and tip speed is proportional to RPM, so each corner's lift is `k·ρ(y)·RPM²`. Inflow from climbing is negligible next to tip speed. The flight loop measures vertical acceleration over 1-second windows against the force the four lift props are actually making and refines the single constant `k`. Hover RPM per corner at any height is then `sqrt(g / (k·ρ(h)))`, with `ρ` from `aero.getAirDensity`. The first guess is 430 RPM at sea level. On the ground, while asked to climb, RPM steps up until the hull lifts, so a low guess only costs a slower liftoff; a guess far above the real hover would launch the hull. It only learns in HOVER and CRUISE: a parked ship with the lift turning (STBY after DEBUG leaves it at 15 RPM) would otherwise learn that 15 RPM hovers. A calibration that puts the sea-level hover under `min_hover_rpm` (100) or over the lift cap is never believed: learning stops at those limits, and such a saved value is replaced by the first guess at start-up. The learned values are saved to `/ap3_cal.dat`.

**Altitude.** The altitude error sets a vertical-speed command. That command is capped at 6 m/s up and 5 m/s down, and further limited near the target so the ship can still stop in time. A vertical-speed loop turns it into an acceleration, and the calibration turns that acceleration into one collective lift RPM. The lift props are pullers and never run below 0. The lift stays closed-loop when settled: holding a fixed RPM left a 0.5–1% force error (whole RPM, write deadband) that walked the hull out to the release band and back, about 2 blocks peak to peak. The lift deadband thins the writes instead: 10 RPM, or 5 while station keeping (at 10 each write moved the lift by about 0.15 m/s² and altitude cycled 0.5 blocks peak to peak in game). Within 0.5 blocks and 0.4 m/s the phase reads HOLD.

**Levelling.** The collective lift is spread over the four corners: bow port `L·(1+P−R)`, bow starboard `L·(1+P+R)`, stern port `L·(1−P−R)`, stern starboard `L·(1−P+R)`. `P` and `R` come from a PD loop on pitch and roll (positive pitch is nose up, positive roll is starboard down) plus an integral trim, up to 30% of `L`, that learns an off-centre load such as a half-empty bomb bay. CAL shows the trims. Levelling waits until the bow axis is confirmed, because with `frame.forward` wrong it would tip the hull further.

**Speed.** The signed speed reference ramps toward a moving target in 14 s and stops 0.5 m/s inside either ±35 m/s cap; it eases into the target at 0.5 m/s³ (`jerk`). Negative targets drive astern without turning the bow around. Both pushers get the same RPM. Control uses normalised force (`RPM²`) with acceleration and drag learned in flight, starting from the measured 30 m/s² at full and almost no drag; a learned or saved full-thrust acceleration at or under 0.3 m/s² is not believed (it is the learner's floor, not a measurement), a save above 60 m/s² (`max_accel_full`) is discarded, and a saved one is rescaled when the pusher cap changes. Learning reads the change of world velocity along the bow, so a turn is not mistaken for thrust. The loop asks for at most 4 m/s² beyond drag (`max_accel`), 5 m/s² while a stop slows the hull (`max_brake`): pushers this strong need several seconds to spin up and down again (32 RPM a tick), so asking for more only overshoots. A stop's reference reaches 0 in 10.8 s (`stop_time`), leaving time for the thrust to wind down inside 15 s. Until the bow axis is confirmed the pushers only probe, with 2% of full thrust. A preview of at least 1.2 s tracks future reference and velocity, accounting for propeller spin and the force left while paced writes reduce RPM; the acceleration feed starts to fall a whole thrust ramp-down before the reference arrives. Zero-speed requests reserve response time for braking, then rest the pushers. Pitch protection still holds thrust back when acceleration tips the nose past 6°. Cruise thrust is held once measured and projected speeds are within 0.3 m/s of target, or measured speed has stayed within 0.3 m/s for two write intervals, and released if either drifts 0.5 m/s. Its integral (at most 0.5 m/s²) freezes while thrust is held. At zero speed with RCS enabled, fore/aft drift over 0.8 m/s wakes braking again; `rcs off` releases this station-keeping role.

**Station keeping.** With the helm brake off a stopped hull keeps drifting, so HOVER, NAV HOLD and ARRIVED, and DOCK hold a point with `ap3/station.lua`, aiming for under 0.5 blocks of movement in any direction. In HOVER the point is taken once ground speed falls under 0.5 m/s and the bow axis is confirmed: where the hull will come to rest braking at 0.15 m/s². `rcs off`, an RCS check and any new mode drop it; DOCK moves from HOVER start from it.

It runs all the time, with no rest band: fore/aft with the pushers, sideways with the RCS, without turning. Each axis steers on where the hull will be 1 s ahead (`station.lead`: writes reach the props about 0.4 s late, then pace and spin), asks for a speed toward the point (`pos_gain` 0.25 m/s per block, at most `fwd_max` 2 / `side_max` 1.5 m/s, slowing at `plan_accel`), and turns the speed error into an acceleration (`vel_gain` 0.4 m/s² per m/s, at most `max_accel` 0.15 m/s²). A world-frame integral within 2 blocks of the point cancels steady pushes such as a slightly tilted lift. The pushers' strength at these small forces has measured from a quarter to four times what the speed loop learned at cruise forces, which made the old hold swing ±12 blocks, so each axis learns its own gain: half-second windows of the hull's real acceleration against the modelled prop push (delayed 0.4 s), with a slow bias term, by least squares (bounded 0.2 to 8). In the model, with 0.4 s write delay, gusts, a steady push and pushers or RCS 3 to 4 times off, the hull stays within 0.13 blocks and altitude within 0.11.

**Heading and sideslip.** The RCS only pulls; no motor ever reverses. For a turn force `u` and a sideways force `s`, each corner gets `max(0, …)` of: bow starboard `u+s`, stern port `u−s`, bow port `−u−s`, stern starboard `s−u`. A pure turn is a diagonal pair (right: bow starboard + stern port; left: bow port + stern starboard), a pure strafe is a same-side pair (both starboard corners pull to starboard), and blends stay proportional. One corner on its own mostly strafes the hull, because the Eureka helm's stabilisation resists the turn.

The bearing error sets a yaw-rate command, at most 15°/s; the planned 0.15°/s² arrival deceleration means a 180° turn peaks near 9°/s. A PI loop on yaw rate gives a yaw acceleration. Commands are divided by the learned turning strength. The RCS cap is 15000 RPM; strength guesses, bounds and force-share thresholds keep the absolute forces they had at the old 4000 RPM cap (force scales with RPM squared), and saved turning calibration rescales automatically using its recorded cap. Turning is learned from half-second windows with enough turn force. Turning strength stays between 5.6 and 2800 deg/s² at full RCS. If the RCS pulls at full for 3 s and the heading is still off, SYS shows "RCS AT FULL: HEADING NOT HELD".

Station keeping: a heading correction starts when the heading is more than 2° off (1° in CRUISE and NAV TRANSIT) or the hull turns faster than 0.5°/s, and stops within 0.5°. In between, the RCS holds the trim its integral learned (an off-centre thrust line, say) or rests. Outside station keeping (which sets the sideways force itself) the sideways brake holds sideways velocity at 0. An error over 0.2 m/s, including drift the ship already had when the autopilot took over, is braked with the same-side pair until it is under 0.08 m/s; then the sideways force rests. If braking for 10 s has made the error worse, the brake stops (wrong bow axis or corner labels); that window starts again while the hull turns, since a turn at speed swings the hull's momentum into sideslip. The smallest RCS pulse is 100 RPM. Heading gets first call on the RCS.

Clockwork props don't follow the motor at once: the bearing changes spin by at most 32 RPM a tick, so 0 → 2000 RPM takes about 3.1 s, and spinning down takes as long. The flight loop models that spin. Every learner uses the force the props are really making, not the commanded RPM. The heading loop gets a lead for turn force still on its way, and the sideslip brake lets go early when the remaining spin will finish the job.

**Motor pacing.** `setSpeed` runs on the server thread and stalls for a tick, so the flight loop only records the RPM each motor should have, and a writer task sends at most one write per tick:

- each motor is written at most once a second. Changes under 10 RPM (lift; 5 while station keeping), 15 (pushers) and 100 (RCS) are skipped, but a start or a stop is always written. One write changes a motor by at most 300 RPM (lift), 900 (pushers) or 7500 (RCS). Sign reversals pass through 0, and a remainder under half a step on the way there goes straight to 0 (884 → 484 → 0, not → 84 → 0)
- the motors move in groups: the four lift corners, the four RCS corners and the two pushers. A group is written as one batch, motors turning down first, then motors turning up, on consecutive ticks with the values chosen when the batch started. Each member must be eligible in its planned tick slot before the batch starts, and its interval is checked again at the write. A due motor cannot pull a recently written partner into another update. Intervals run from the completion of each yielding call
- a running batch goes first, then the lift, then the group with the largest need. A lift trim (no corner moving 20 RPM or more) does not jump the queue: it waits behind a due pusher or RCS batch
- KILL bypasses all of it: every motor goes to 0 at once

Changing an electric motor's speed detaches and reattaches its kinetic network. Downstream bearings still incur Create's flicker score: a running-speed change adds up to 10, it decays by 1 per game tick, and scores above 128 destroy blocks. Normal one-second pacing prevents our writes from accumulating that score. This does not protect against independent power starvation or redstone cycling: an underfed motor can stop and restart even with its commanded RPM unchanged. Check power delivery if bearings still stutter or break.

## Limits

- Peripheral names come from the motor and relay numbers in the spec. If SYS lists missing motors or relays, read the real names from the wired modems and edit `ap3/config.lua`.
- If a motor's `getSpeed` doesn't report its RPM, the computer can't tell after a reboot that the lift is spinning, so it doesn't take over in HOVER on its own.
- RCS turning force is capped at 15000 RPM. If the pusher thrust line is far off the centre of mass, the heading can still drift during hard acceleration (SYS shows "RCS AT FULL").
- With the helm brake off, speed changes overshoot more than they did with drag: in the simulated hull a 0 → 30 m/s cruise overshoots by about 1 m/s and a 35 → 0 stop takes close to the 15 s limit. Position holds keep within about 2 blocks.
- Gains are tuned against a simulated hull. In-flight learning covers lift, thrust, drag, and RCS strength and direction; the remaining gains are in `ap3/config.lua` if the real hull needs different ones.

## Tests

```
lua tests/test_flight.lua
lua tests/test_actuators.lua
lua tests/test_rcscheck.lua
lua tests/test_install.lua
lua tests/test_bombs.lua
lua tests/test_mfd.lua
lua tests/test_telemetry.lua
lua tests/test_nav.lua
python tests/cc/run.py <CraftOS-PC_console.exe>
```

`tests/test_flight.lua` flies the real control modules against `tests/world.lua`, a hull model with the Clockwork thrust law per motor, air density, drag, RCS yaw, thrust misalignment, nose dip, corner lift torque, an off-centre load, prop lag, an optional write delay, steady and random horizontal pushes, and ground contact. It checks liftoff, climbing and holding at several heights from wrong calibrations, cruise to 30 m/s within 15 s, the 35 m/s cap, reverse-thrust braking, heading hold, the pitch limit, KILL and DEBUG on all ten motors, noisy telemetry, a wrong bow axis, wrong RCS labels with the RCS check, levelling under an off-centre load, and paired pushers. Cases 31–37 check the closed-loop altitude band with noisy velocity, the pusher-calibration floor, NAV HOLD translating onto a nearby point without turning, a 180° turn under the 15°/s cap, `goto` climbing first and ending at its bearing, descending last, a route through a fly-through waypoint, docking moves (fore, starboard, up, a 90° turn in place, and three 10-block presses adding up without a climb), and HOVER holding position on a hull with almost no drag. Case 42 holds a HOVER point within 0.5 blocks in every direction with writes reaching the props 0.4 s late, gusts, a steady push, and pushers or RCS 3 to 4 times stronger or weaker than learned.

`tests/test_nav.lua` checks the `goto`/`wp`/`route`/`rec`/`dock` parser, waypoint-name rules, loading a saved waypoint file with bad entries, and which phase a leg starts in.

`tests/test_install.lua` checks that the installer downloads every module `startup.lua` can load. `tests/test_bombs.lua` checks the bay layout, salvo selection, the interlocks, the trigger pulse and door timing, and the bay wrapper (save before fire, bad save files, a missing door relay, salvo sizes). `tests/test_mfd.lua` checks that every display keeps three different formats and every page is on screen at most once, whatever is pressed or loaded.

`tests/test_actuators.lua` checks staggered batch eligibility, pinned targets, per-motor write intervals under rapid requests, downstream bearing flicker, paired pushers, completion-time pacing, and emergency zero interrupting a batch. Flight checks include plain-hover starts to 20 and 30 m/s with less than 1 m/s overshoot in the simulated hull.

`tests/test_rcscheck.lua` checks mixed slide/bearing inference across all corner permutations, refuses ambiguous yaw-only or conflicting observations, and checks heading wraparound. Flight and emulator checks exercise RCS off/on while the pushers are braking, while drifting, and while driving a nonzero cruise target.

`tests/test_telemetry.lua` checks stationary readings despite an accumulating physics velocity, signed and diagonal displacement, irregular sample times, bow changes and clock resets.

`tests/cc/run.py` boots the real `startup.lua` in [CraftOS-PC](https://www.craftos-pc.cc) with fake motors, relays and monitors. It presses MFD buttons, types terminal and keypad commands, refuses a drop below Y 200, drops at Y 210 and watches the relays, and checks the missing-peripheral path. Its `velocity` scenario holds the world position still while the velocity API increases, then moves forward, reverses and stops; the rendered PFD/AP/HSI readouts must follow world movement rather than that API. Its `nav` scenario saves a waypoint, flies `goto` 40 blocks east to bearing 90 (up to Y 500 and back down to 200) until MENU → NAV shows ARRIVED, records 3 s with `rec on`/`rec off`, then on MENU → DOCK picks STEP 5 and STBD 5 and checks the ship holds 5 blocks to starboard.
