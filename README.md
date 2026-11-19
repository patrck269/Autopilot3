# Autopilot 3.0

Single-computer flight control and bombing system for the rebuilt Valkyrien Skies bomber. Computer 9 controls ten Create Crafts & Additions electric motors, 47 CC:Tweaked redstone relays, every wired monitor, and the local terminal.

## Features

- Manual, semi-automatic, and waypoint flight modes
- Learned hover RPM with per-corner pitch and roll correction
- Compass heading, sway, and forward-speed control
- Five swappable MFD pages on every wired monitor
- 46-position bomb-bay map, balanced drop selection, safety interlocks, timed trigger pulses, and automatic doors
- Atomic state persistence and a staged installer
- `rcs` CLI toggle that releases or restores the four RCS thrusters for Eureka helm control

## Install

On computer 9:

```text
wget run https://raw.githubusercontent.com/patrck269/Autopilot3/master/install/autopilot.lua
```

The published installer is pinned to an immutable commit after each release. It installs `programs/autopilot.lua` as `startup.lua`, `programs/rcs.lua` as `rcs.lua`, and all modules under `src/`.

## Controls

| Key | Action |
|---|---|
| `M`, `S`, `U`, `T` | Manual, semi, auto, standby |
| Arrows | Forward/reverse and port/starboard manual stick |
| `Space`, `Left Shift` | Up/down manual stick |
| `Y`, `B`, `V` | Enter altitude, bearing, or semi-mode speed |
| `X`, `Z` | Enter waypoint coordinates |
| `W` | Toggle cruise/warp profile |
| `E`, `C` | Emergency stop/clear |
| `O`, `P`, `F` | Open doors, close doors, drop |
| `[` / `]` | Select bomb salvo size |

Numeric entry accepts digits, `-`, and `.`. Press Enter to commit or Tab to cancel.

Run `rcs` from a ComputerCraft shell to disable all four RCS motors for Eureka helm control. Run `rcs` again to re-enable autopilot RCS control. The state survives an autopilot restart.

## Configuration

All tunable values are in `src/config.lua`. Commission `forward_axis` first. Change a motor's `motor_sign` only when that motor pushes opposite its assigned role.

Run the local suite with:

```text
lua tests/run.lua
```
