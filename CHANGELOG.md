# Changelog

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
