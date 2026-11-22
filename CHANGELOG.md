# Changelog

## Unreleased

- Caps raised for the 3.0 ships' small props: pushers ±10000 RPM, RCS 15000 RPM (write steps 900 and 7500). Measured in game: both pushers at 10000 RPM give about 32 m/s². RCS strength guesses, bounds and force-share thresholds keep their absolute forces; saved pusher and RCS calibrations rescale with the cap (`thrust_cap` is now saved).
- Eureka's helm brake (`linearStabilizeMaxAntiVelocity`) is turned off on the server: it cancelled any thrust under about 0.84 m/s². With it off the hull has almost no drag, so HOVER now holds the point where the ship came to rest (pushers fore/aft, RCS sideways), and DOCK moves from HOVER start from that point.
- Speed control for strong, slowly spinning pushers on a near-frictionless hull: first guesses from the measured hull, at most 4 m/s² asked beyond drag, a jerk-limited reference that reaches its target in 14 s, a feed that falls a whole thrust ramp-down before arrival, a 0.5 m/s² integral, and only a 2% probe thrust until the bow axis is confirmed. The sideways brake engages at 0.2 m/s; position hold uses half the gain and 2 m/s fore/aft.
- A NAV descent that drifts more than 3 blocks off the point pauses where it is instead of continuing.
- NAV mode: `goto X Z [Y] [BRG]` or `goto <name>` flies to a world point, climbing first and descending last, holds position there by translating (pushers fore/aft, RCS sideways) and turns to the final bearing. `wp save|del|list` keeps up to 30 named waypoints and `route add|go|clear|list` a stored route of up to 20 legs, with fly-through legs and stops; both are saved in `/ap3_nav.dat`. A stop within 24 blocks is reached by translation alone. New NAV MFD page (through MENU), a NAV line on the terminal and a waypoint mark on the HSI.
- NAV cruises at Y 500 or higher (`nav.min_transit_alt`) to stay out of reach of ground Warium fire: it climbs there before transit and descends to a stop's Y only once over it. A stop without Y is held at the cruise altitude; a stop reached by translation alone (within 24 blocks) does not climb.
- DOCK MFD page and `dock` command: move the held point 1, 2, 5 or 10 blocks fore/aft, port/starboard or up/down along the ship's axes, or turn the held bearing by the same step, in place. Moves start from the held point (so presses add up) or, in HOVER, from the current position, and are flown by translation alone.
- Host inbox: terminal-syntax commands written to `ap3_host.in` in the computer's folder are run by the flight loop, replies go to `ap3_host.log`, and `ap3_host.status` holds a live snapshot while it is in use. `tools/ap3_host.py` sends commands and reads both.
- The sideways brake tracks a sideways velocity target (0 except in NAV HOLD). Its wrong-direction guard restarts its window while the hull turns, so a turn at speed no longer disables it.
- Altitude is held closed-loop: the open-loop held lift RPM drifted 2.1 blocks peak to peak in a limit cycle; the simulated band with velocity noise is now under 1 block. The lift deadband rises from 5 to 10 RPM, `altitude.hold_release` is gone, and a lift trim under 20 RPM no longer jumps ahead of a due pusher or RCS batch.
- A learned or saved full-thrust pusher acceleration under 0.3 m/s² (`speed.min_accel_full`) is not believed; computer 12's saved 0.05 was the learner's floor and reloads as the 1.5 m/s² first guess.
- RCS yaw-rate cap raised from 4 to 15 deg/s; the 0.15 deg/s² arrival deceleration still limits a 180° turn to about 9 deg/s.
- Cruise thrust is also held after two write intervals inside the hold band: paced writes could swing the pushers 400 RPM up and down every second around the target. A pusher reversal no longer spends a write on a remainder under half a step (884 → 484 → 0).
- Flight recorder: `rec on|off` writes five rows a second to `/ap3_rec.csv`; `tools/rec_analyze.py` reports phantom velocity, altitude and heading peak-to-peak, and whether HOVER heading corrections follow pusher or lift RPM changes.
- Anticipate pending pusher force and taper acceleration before the speed ramp ends. Cruise hold now checks projected speed and freezes its integral instead of capturing an accelerating pass through the target.
- Enforce each motor's write interval within coordinated batches and measure it from call completion. A due motor no longer forces recently written partners to update; KILL still bypasses pacing. Adjust the yaw lead to the enforced cadence.
- Invert bomb-door output: powered closes, unpowered opens. Startup closes the doors without firing any bomb triggers; manual and timed closing use the same polarity.
- Add motor-cadence, bearing-flicker, cruise-arrival and door-polarity regressions.
- Reduce the door-opening drop lockout from three seconds to one second; salvo spacing and automatic closing delays are unchanged.
- `rcs off` also releases the pushers from fore/aft station keeping in HOVER and zero-speed CRUISE. Nonzero CRUISE propulsion and altitude hold remain active; `rcs on` restarts speed control from the current drift.
- Double only the RCS cap to 4000 RPM and its write step to 2000 RPM. Rescale full-force strength guesses/bounds and force-share learning/probe thresholds; lift and pusher caps and write cadence stay unchanged.
- Raise RCS-check pulses to 2000 RPM. Accept bearing-only evidence when other corners make the layout unique; otherwise report diagonal candidates and conditional thrust direction without saving a guessed mapping.
- Accept negative speed targets for reverse CRUISE, with symmetric speed limits and pitch protection. Preview stopping impulse from paced RPM reductions so the zero target brakes either direction without repeated fore/aft surges.
- Add AP's SPD 0 button between the +1 and −1 speed buttons, retaining all four step controls. It commands a controlled stop; altitude hold and motor pacing remain active.
- Measure displayed horizontal speed, drift and track from world-position changes instead of physics-reported velocity. A stationary hull reads zero and backing up gives negative forward speed; thrust control and vertical speed are unchanged.
- Add telemetry sampling regressions and a CraftOS display scenario for stationary, forward and reverse movement while the velocity API accumulates independently.

## 3.1.0

Rebuilt on the Autopilot 2.0 codebase. This replaces the 1.0-derived modes and UI.

- Flight control is Autopilot 2.0's: learned altitude, speed and heading control, the HOVER, CRUISE, STBY, KILL and DEBUG modes, the RCS check and the learned bow axis.
- The MFDs are Autopilot 2.0's fighter MFDs, with OSBs, MENU, three formats per display, SWAP and a saved layout. A new BOMB page shows the bay map and has salvo, door, drop and reload buttons.
- Commands are typed on the terminal with Autopilot 2.0's command line. New commands are `doors open|close`, `salvo`, `drop`, `reload` and `rcs off|on`.
- The ten electric motors are driven as three batched groups: four lift corners, four RCS corners and two paired pushers.
- Four-corner levelling trims the lift corners to hold pitch and roll. It learns an off-centre load and waits for a confirmed bow axis.
- The bomb bay logic is unchanged. The bay record and salvo size live in `/ap3_bombs.dat`.
- Removed: MAN, SEMI and AUTO modes, waypoint autonav, the arrow-key stick, the single-letter hotkeys and the `rcs` shell program.
- The hover calibration is learned only in HOVER and CRUISE and bounded to a sea-level hover between 100 RPM and the lift cap; `recal` always resets to the first guess. (Autopilot 2.0 learned a 15 RPM hover from a parked ship.)
- MFD format slots stay distinct: picking a page an MFD already held in another slot made a duplicate, and pages dropped out of every slot.
- MFD pages fit narrow monitors (2 blocks wide): drawing is clipped to the content area, AP/CAL/PFD/HSI use extra lines, BOMB stands the bay map upright on a tall one.
- `rcs reset` (or CAL: RCS RESET) forgets the learned RCS turning and sideways strength.
- A monitor reached under two names (touching the computer and on the wired network) carries one MFD instead of two drawing over each other.

## 3.0.0

- Replaced grouped propulsion with ten independently controlled electric motors.
- Added learned hover control, per-corner leveling, compass heading, sway, and speed loops.
- Added manual, semi-automatic, and waypoint flight modes on one ship computer.
- Added five swappable monitor pages and keyboard/terminal controls.
- Added the 46-trigger bomb bay with balanced selection, door and altitude interlocks, timed pulses, reload confirmation, and automatic door closure.
- Added the `rcs` CLI toggle for releasing and restoring RCS control while using a Eureka helm.
- Added atomic persistence, automated Lua tests, and a staged installer.
