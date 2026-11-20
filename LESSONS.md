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

Still open: from a plain hover, cruise overshoots its target. With the doubled caps that was 1.7–3.1 m/s; with the old caps it is 1.0–1.9 m/s (peaks 21.6–21.9 at 20 m/s, 31.0 at 30 m/s). The fix is a lead term in the speed loop for force that is still spinning up, the same way the heading loop handles it.

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
