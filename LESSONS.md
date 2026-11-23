# Lessons learned

From rebuilding Autopilot 3.0 on Autopilot 2.0 and from the in-game faults that followed on both ships. Each entry gives what happened, the evidence, and what to do next time. Commit hashes are in this repo unless marked "2.0" (the Autopilot 2.0 repo).

## 1. A learner must only learn while its model holds

The 2.0 ship decided that 15 RPM holds it in the air. The hover learner fits `lift = k·ρ·RPM²` and ran in every mode whenever the lift was turning. After DEBUG (every prop at 15 RPM), the ship sat in STBY on its moorings. It jittered enough not to count as grounded, so the learner fitted `k` to 15 RPM. The saved calibration in the server backups shows the runaway:

| Time | Hover RPM implied by the saved `k` |
|---|---|
| Night before | about 415 |
| 17:57 | about 2100 |
| 18:02 | about 7 |
| 18:12 | about 15 (= DEBUG's RPM) |

`recal` did not help. In a steady hover it re-seeded `k` from the RPM on the lift, which was the same bad 15 RPM.

Fixed in 2.0 `51c1070` and here in `aff3d43`:

- The hover is learned only in HOVER and CRUISE.
- `k` is bounded to a hover between 100 RPM and the lift cap. A saved value outside that range is dropped.
- `recal` always returns to the first guess.

**Next time:** for every learner, write down the conditions its model assumes (here: the autopilot is flying, the hull is free) and gate learning on them. Bound what it can learn to what is physically possible. A reset must not read the state it is meant to clear.

## 2. Test the configuration that ships

Two in-game UI faults passed every emulator test because the harness did not match the ships.

- **Monitor sizes.** The harness used 3×2 and 2×2 monitors. The ships have 2-wide by 3-tall monitors (36×38 characters). On those, pages wrote past their 22-column content area into the side buttons, and the HSI rose drew as a tall oval. Fixed in 2.0 `0d4e724` and here in `c44c984`.
- **Monitor names.** The 2.0 harness listed four monitors by name, while both ships use `monitors = {}` (every monitor). A monitor touching the computer and also wired to a modem appears twice, as `left` and `monitor_15`. Each name got an MFD, so two pages drew on one screen. Fixed in 2.0 `c6261e7` and here in `38cf1aa`. The harness now uses every monitor and reaches one monitor under a second name. The old code fails that test exactly as the screenshot did.

**Next time:** copy the live config (monitor list, sizes, peripheral names) into the test setup before trusting a pass. When a user reports a UI fault, ask for a screenshot first. One picture showed BOMB and PFD on one screen, which pointed straight at the duplicate names.

## 3. A test that passes by timing is not a pass

Several ported 2.0 checks passed by luck of phase rather than by design.

- **Altitude.** The light-hull case checked `|y − 100| < 1` at one instant, while the hold band lets the hull wander ±1.5. Both 2.0 and 3.0 trace the same ±1.5 cycle. 2.0 happened to be at 99.2 when sampled and 3.0 at 101.3.
- **Speed.** Cruise-speed checks passed or failed depending on whether the first pusher write landed one tick earlier or later.
- **Emulator.** One emulator run failed "holds 20 m/s" at 16.7 and the next passed. Both were the same code under wall-clock timing.

**Next time:** check over a window and against the controller's designed band, not a single sample. When a change flips a check, compare the full trajectory with the old code before tuning anything.

## 4. Measure before accepting a number from a plan

The approved plan set the hover first guess to 800 RPM per corner. A 300 RPM test hull with that guess launched and was still climbing at Y 7304 after 120 s. The descent command never asked for less than about 506 RPM, and learning stops above 15 m/s. AP2's 430 RPM guess keeps that case under 6 blocks of overshoot (`be7c93b`).

**Next time:** run a plan's numbers through the simulation before shipping them. If a value only moves the result a little, the plan was fine; if it moves it a lot, stop and ask before changing it.

## 5. Scaling a limit changes the loop

Doubling the caps (`37c0039`) gave four times the force (force goes with RPM²). Clockwork props still follow at a fixed 32 RPM a tick, so the props lag further behind every command.

| Measurement | Before retune | After retune |
|---|---|---|
| Cruise peak at a 30 m/s target | 33.7 m/s | 31.2 m/s |
| Nose dip | 15.3° | within the 8° limit |
| Wrong-bow runaway | about 60 m/s | under 18 m/s |

The fixes were:

- Write steps no larger than the props can follow (600 RPM a second).
- Speed corrections capped at 1.5 m/s² beyond the ramp.
- First guesses rescaled by the cap ratio squared.
- Pushers held to 25% force until the bow is confirmed.

**Next time:** when a limit changes, list every quantity expressed as "share of full", and every absolute rate that does not scale with it.

The caps were later reverted to 2750 / 2000 / 1500 on request, which also reverted that retune.

Cruise initially overshot from a plain hover: earlier probes measured 1.0–1.9 m/s at the old caps. Pending-force lead alone did not solve it: the ramp kept requesting acceleration until arrival, and cruise hold captured an accelerating pass through target. The speed loop now previews the ramp end and projected hold speed, compensates for pending propeller force, and freezes the held integral. The 20 and 30 m/s regression scenarios stay below 1 m/s overshoot over 60 seconds on the simulated hull; this is not a live-flight measurement.

## 6. Feedback needs the right frame, and paired actuators need paired values

- **Levelling sign.** Levelling reads pitch and roll along `frame.forward`. With that axis 180° off, the levelling became positive feedback and tipped the hull, and the ship then mis-learned its bow (test 20). Levelling now waits for a confirmed bow axis (`be7c93b`).
- **Pusher pairs.** Batched writes picked each value when it was written. The two pushers drifted apart for up to 181 ticks because the speed command changed between the first and second write. Each batch now fixes its values when it starts.

**Next time:** before closing a loop, ask what happens if the sign of each input is wrong. For actuators that must move together, decide their values in one step.

## 7. Operations

- **Line endings.** `git archive` applies `core.autocrlf`, so files deployed straight from it did not match the commit hashes. Deploy with `git -c core.autocrlf=false archive`.
- **Backups.** The server's backup mod deletes a full backup that is cut short. When asked to restore at 18:15, the full backup started at 17:57 was still being written, so I waited about 2 minutes for it to finish before stopping the server. Its incremental backups are "changed since the last full", so a restore means the full backup plus the latest increment.
- **Undo copies.** Before any destructive step, keep the old state where it can be undone:
  - the world as `RIBBED_pre-restore_…`
  - computer 3's files as `pre-51c1070/`
  - computer 12's 1.0-era install as `old-ap3-v1/`
- **Server-owned config.** The server rewrites `vs_eureka.toml` from memory when it shuts down, so an edit made while it runs is lost. Edit it only while the server is stopped. A failed `sed -i` once left the file empty; keep a copy (`vs_eureka.toml.before-antivelocity-0`) before editing.
- **"Latest backup before 5:14".** Asked for this after a crash at about 5:14, I restored 17:13. Patrick wanted 17:08, the last one before the trouble started. Each restore of the 42 GB world took 17–21 minutes. When the time is near the incident, confirm which backup before stopping the server.
- **Do not restart a computer that is flying.** I restarted computer 12 to load an update while Patrick was climbing in NAV at 10 m/s. The restart dropped NAV. HOVER then braked at 8 m/s, which my test script's abort guard read as a fault, and it switched the ship to CRUISE. Read the status (mode, ground speed) first, and restart only in HOVER or STBY or when asked. An abort guard must know which states are normal right after its own action.
- **Stale status.** `ap3_host.status` is only written while the host inbox is in use, so an old file means "no command sent lately", not "computer off". Send a harmless command (`wp list`) and check the file's time.

## 8. Removing a damper changes every loop

Eureka's helm brake (`linearStabilizeMaxAntiVelocity`) cancelled up to about 0.84 m/s² whenever no player was seated. The first live run at 1500 RPM pushers moved only 0.08 m/s. With the brake off (`963b4ad`) the hull has almost no drag (about 0.05 m/s² at 35 m/s), and loops tuned with that brake lost their damping:

| 3-minute hover, old build | Brake on | Brake off |
|---|---|---|
| Drift | 0.04 blocks | 62 blocks |
| Hull moved during a 90° turn | 0.05 blocks | 20 blocks |

**Next time:** when an outside force is removed or added, list which loops relied on it (here: every "rest when close" behaviour) and retest each before shipping.

## 9. On a hull without drag, a hold must never rest

The first position hold (`963b4ad`, `8db1884`) rested within 0.75 blocks and drove back from 1.5. Without drag, any rest drifts, so it cycled through that band by design. Asking the pushers for up to 4 m/s² made it worse: their RPM took seconds to reverse, and a live dock hold swung ±12 blocks at ±3 m/s. `52c206a` replaced it with continuous station keeping (`ap3/station.lua`): a speed-toward-the-point loop capped at 0.15 m/s², steering on the position 1 s ahead, with an integral and no rest band. Live it held 0.12 blocks fore/aft and 0.07 sideways over three minutes.

**Next time:** for a requirement like "under 0.5 blocks", start from a continuous loop and give it a hard number to meet in a test (here test 42). Hysteresis bands only fit plants that settle on their own.

## 10. Check the diagnosis against more than one recording

NAV HOLD drifted away with a learned pusher strength of 84 m/s². I assumed that value was mislearned, so `c796cc3` discarded it and stopped the learner during holds. The next recording swung the hull ±4 m/s on pushers four times stronger than the autopilot then believed. Fitting `a = A·ρ·RPM²` to every recording of the day gave very different sea-level strengths:

| Recording | Highest pusher RPM | Fitted A at sea level (m/s² at full) |
|---|---|---|
| NAV flyaway | 2809 | 37.5 |
| Dock swing | 3204 | 45.6 |
| Cruise test | 3483 | 63.8 |
| HOVER at Y 70 | 569 | 156 |
| HOVER at Y 250 | 1288 | 166 |

No thrust exponent between 0.5 and 2 made them agree. Pitch did not explain it either (correlation −0.1). The cause is still unknown, so station keeping now learns its own gain per axis at the forces it uses, and saves it (`46b6f0d`). One part of `c796cc3` was right: the learner read turns as thrust (a 90° turn at 20 m/s skewed A by a third), so it now uses world velocity along the bow.

**Next time:** before acting on "the learned value is wrong", fit the model to several recordings. If the fits disagree, the model is incomplete, and the controller must cope with the spread instead of trusting one number.

## 11. Put the measured lag and disturbances in the model before tuning

The hull model sent motor writes to the props at once, with no disturbances. In it the old hold settled; at 20 RPM a tick of prop spin it diverged (test 40). The recordings fit a 0.4 s write delay and about 25 RPM a tick. `tests/world.lua` now has `cmd_delay`, `push_x`/`push_z` and `gust`. Every station-keeping setting was swept against pushers and RCS three to four times off, slow props, a starting drift and gusts, before choosing one (worst case 0.26 blocks at the chosen setting, against 1–3 for others).

**Next time:** fit delay and noise from a live recording first, add them to the model, and tune against the worst plausible mix, not the nominal hull.

## 12. A check that flips on an unrelated change has found a thin margin

Lowering the lift deadband from 10 to 3 RPM, a change to the lift only, made cruise checks fail: a 30 m/s start overshot by 2.9 m/s, and the 45 m/s reversal passed the cap at 37. Two causes came out of tracing them:

- **Write slots.** Lift trims jumped the write queue whenever a corner moved twice the deadband. At 3 RPM that was almost every trim, and it delayed pusher writes. The queue jump now has its own threshold (`actuator.lift_priority`, 20 RPM). The fine deadband (5 RPM) applies only while station keeping (`f9e8583`).
- **A late start.** Pushers left turning backwards by station keeping must pass through 0, one write interval each way. The speed reference ran on without the hull and the loop overshot catching up. The reference now waits, when starting from rest, until the props push its way.

**Next time:** when a check fails after a change to another subsystem, trace why before retuning anything. The margin it found is usually real.
