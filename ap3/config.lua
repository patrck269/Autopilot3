-- Autopilot 3.0 configuration. Edit peripheral names and tuning here.
-- Every value is read at program start; reboot the computer after editing.
return {
  -- Create Crafts & Additions electric motors on the computer's wired
  -- network, one RPM per motor. cap is the absolute RPM limit; sign flips a
  -- motor that runs backwards. Every lift and RCS prop is a puller; the two
  -- pushers sit on the stern facing aft (positive RPM moves the ship forward).
  motors = {
    lift_bow_port   = { name = "electric_motor_7", cap = 5500, sign = 1, label = "E7 LIFT BOW PORT" },
    lift_bow_stbd   = { name = "electric_motor_2", cap = 5500, sign = 1, label = "E2 LIFT BOW STBD" },
    lift_stern_port = { name = "electric_motor_5", cap = 5500, sign = 1, label = "E5 LIFT STRN PORT" },
    lift_stern_stbd = { name = "electric_motor_3", cap = 5500, sign = 1, label = "E3 LIFT STRN STBD" },
    bow_port        = { name = "electric_motor_6", cap = 15000, sign = 1, label = "R6 BOW PORT" },
    bow_stbd        = { name = "electric_motor_1", cap = 15000, sign = 1, label = "R1 BOW STBD" },
    stern_port      = { name = "electric_motor_4", cap = 15000, sign = 1, label = "R4 STRN PORT" },
    stern_stbd      = { name = "electric_motor_0", cap = 15000, sign = 1, label = "R0 STRN STBD" },
    thrust_port     = { name = "electric_motor_8", cap = 10000, sign = 1, label = "L8 PUSH PORT" },
    thrust_stbd     = { name = "electric_motor_9", cap = 10000, sign = 1, label = "S9 PUSH STBD" },
  },

  -- Monitors used as MFDs, in display order. SWAP exchanges displays 1<->2
  -- and 3<->4 (an odd last display swaps with display 1).
  -- An empty list uses every attached monitor.
  monitors = {},
  monitor_scale = 0.5,

  -- Ship-local axes as they were when the hull was assembled. forward points
  -- out of the bow, up out of the deck. Compass bearing: 0 = north (-Z),
  -- 90 = east (+X), 180 = south, 270 = west. forward is only the first
  -- guess: the flight computer learns the real bow axis from which way the
  -- pushers push the hull, snaps it to the block grid, switches to it
  -- and remembers it (SYS shows "BOW AXIS CORRECTED").
  frame = {
    forward = { x = 1, y = 0, z = 0 },
    up = { x = 0, y = 1, z = 0 },
    bow_samples = 8,      -- 0.5 s windows with pusher thrust before the bow axis is trusted
    vote_force = 0.0125,  -- share of full pusher thrust a window needs to count (0.4 m/s^2 at 32 m/s^2)
    bow_min_accel = 0.05, -- m/s^2 at full thrust: smaller responses are not trusted
    bow_snap_deg = 25,    -- the learned direction must be this close to a grid axis
    bow_streak = 4,       -- and give the same axis this many windows running
  },

  loop_period = 0.1,    -- control loop period, seconds
  status_period = 0.25, -- telemetry broadcast period, seconds
  gravity = 10,         -- VS gravity, m/s^2

  -- Motor pacing (see ap3/actuators.lua).
  actuator = {
    prop_slew = 32,       -- Clockwork props change spin by at most this RPM per tick
    min_interval = { lift = 1.0, thrust = 1.0, rcs = 1.0 }, -- seconds between writes to one motor
    deadband = { lift = 10, thrust = 15, rcs = 100 },       -- smallest RPM change worth a write
    lift_fine = 5,        -- lift deadband while station keeping (10 cycled altitude 0.5 blocks live; 3 crowds the pushers' writes)
    lift_priority = 20,   -- a lift step this big (RPM, any corner) is written before pushers and RCS
    weight = { lift = 3, thrust = 2, rcs = 1.5 },            -- which group gets the next write
    slew = { thrust = 900, lift = 300, rcs = 7500 },         -- largest RPM change per write
    rcs_min_rpm = 100,    -- smaller RCS commands are sent as 0 (finer pulses for a strong RCS)
  },

  altitude = {
    climb_rate = 6,       -- max climb, m/s
    descent_rate = 5,     -- max descent, m/s
    brake_accel = 1.0,    -- deceleration planned when arriving, m/s^2
    pos_gain = 0.5,       -- (m/s) per block of altitude error
    vel_gain = 1.0,       -- (m/s^2) per m/s of vertical speed error
    max_accel = 3,        -- largest commanded climb acceleration, m/s^2
    min_accel = -6,       -- largest commanded sink acceleration
    int_gain = 0.02,      -- altitude integral, (m/s^2) per block-second
    int_limit = 1.0,      -- integral limit, m/s^2
    int_zone = 6,         -- integral runs inside this many blocks
    hold_band = 0.5,      -- within this many blocks (and |vy| < 0.4) the phase shows HOLD
    reverse_lift = false, -- the lift props are pullers: never written below 0
    -- Hover calibration. Lift = k * airDensity(y) * rpm^2 per corner, learned in flight.
    -- Keep the first guess low: on the ground the RPM is raised step by step
    -- until the hull lifts, but a guess far above the real hover launches it.
    default_hover_rpm = 430, -- first guess per corner at sea-level density, before any learning
    min_hover_rpm = 100,  -- a calibration that says a corner hovers below this (at sea level) is not believed
    cal_window = 1.0,     -- seconds per calibration sample
    cal_rate = 0.5,       -- fraction of each sample applied (0..1)
    cal_max_vy = 15,      -- samples taken only while |vy| is below this, m/s
    liftoff_step = 0.88,  -- grounded and asked to climb: k *= this per window (+6.6% RPM)
    liftoff_accel = 1.0,  -- climb acceleration asked for while still on the ground, m/s^2
  },

  -- Four-corner levelling: the lift corners are trimmed apart to hold pitch
  -- and roll at 0. Gains are fractions of the collective lift RPM per degree
  -- (kp), per deg/s (kd) and per degree-second (ki, the trim for an
  -- off-centre load, limited to trim_max).
  level = { kp = 0.0087, kd = 0.0052, ki = 0.0017, trim_max = 0.3 },

  speed = {
    max = 35,             -- hard speed cap, m/s
    cap_margin = 0.5,     -- the speed reference stops this far under the cap
    ramp_time = 14,       -- reference reaches the new target in this many s (requirement: within 15 s)
    stop_time = 10.8,     -- a stop's reference reaches 0 in this many s; braking ends within 15 s
    min_ramp = 0.3,       -- slowest reference ramp, m/s^2
    vel_gain = 1.0,       -- (m/s^2) per m/s of predicted speed error
    thrust_lag = 1.2,     -- minimum preview horizon; grows if paced RPM ramp-down needs longer
    int_gain = 0.15,      -- integral (m/s^2) per (m/s * s)
    int_limit = 0.5,      -- integral limit, m/s^2
    stop_band = 0.2,      -- stopped: brake drift down to this (m/s), then the pushers rest
    hover_engage = 0.8,   -- stopped: drift (m/s) that wakes the pushers again
    hold_band = 0.3,      -- cruising within this of the target speed (m/s): thrust is held
    hold_release = 0.5,   -- release early enough to stay near either signed target, including the cap margin
    pitch_limit = 6,      -- degrees of acceleration-induced nose dip before thrust is held back
    probe_force = 0.02,   -- share of full thrust allowed until the bow axis is confirmed (0.64 m/s^2 at 32 m/s^2)
    jerk = 0.5,           -- m/s^3: the speed reference eases into its target this gently
    max_accel = 4,        -- largest acceleration asked for beyond drag, m/s^2 (strong pushers spin up and down slowly)
    max_brake = 5,        -- and the largest deceleration while slowing down, m/s^2
    -- Thrust model a = A*f - D*v|v| (f = normalised force, rpm^2/cap^2), learned in flight.
    -- First guesses measured on the 3.0 ship (2026-11-22, 10000 RPM cap):
    -- about 32 m/s^2 at full thrust, and (Eureka helm brake off) 0.05 m/s^2 of drag at 35 m/s.
    accel_full = 30,      -- first guess: m/s^2 at full pusher thrust, sea-level air density
    min_accel_full = 0.3, -- m/s^2 at full thrust: a learned or saved value below this is not believed
    max_accel_full = 250, -- and above this (sea level; in-game fits gave 37-166; a save above it is discarded)
    top_speed = 900,      -- first guess: speed where full thrust equals drag
  },

  heading = {
    bearing_gain = 0.2,   -- (deg/s) of yaw rate per degree of bearing error
    max_rate = 15,        -- max commanded yaw rate, deg/s (yaw_accel limits how much of it a turn uses)
    yaw_accel = 0.15,     -- yaw deceleration planned when arriving, deg/s^2 (RCS updates lag ~3 s)
    rate_gain = 0.4,      -- (deg/s^2) per deg/s of yaw-rate error
    int_gain = 0.1,       -- integral (deg/s^2) per (deg/s * s)
    int_limit = 3,        -- integral limit, deg/s^2
    -- Station keeping: a correction starts when the heading is off by more than
    -- the deadzone (or the hull turns faster than engage_rate), and stops once
    -- within settle_deg and turning slower than settle_rate. In between the RCS
    -- holds a steady trim against any steady torque, or rests.
    hover_deadzone = 2,   -- degrees, HOVER
    cruise_deadzone = 1,  -- degrees, CRUISE
    settle_deg = 0.5,
    settle_rate = 0.2,    -- deg/s
    engage_rate = 0.5,    -- deg/s
    high_speed = 20,      -- above this ground speed the heading integral works harder
    high_speed_gain = 2.0,
    -- Positive RPM pulls on every RCS corner (fixed). Only the strength is
    -- learned in flight; these are the first guesses at full RCS.
    yaw_authority = 140,  -- deg/s^2 at full RCS; doubling RPM quadruples force
    min_authority = 5.6,  -- smallest yaw strength believed (deg/s^2)
    max_authority = 2800, -- largest yaw strength believed; a saved value past it is discarded
    -- Turn force (share of full) a 0.5 s window needs before the strength is
    -- learned. Weaker windows mostly measure yaw from something else (a bump,
    -- an off-centre thrust line). Keep it under what a turn commands at
    -- max_authority (about 0.001), so a high estimate can still come down.
    -- These keep the absolute forces they had at the 4000 RPM cap: force
    -- goes with RPM squared, so at 15000 the shares are (4000/15000)^2 of them.
    learn_min_force = 0.00053, -- same absolute learning force as 3% at 2000 RPM
    probe_limit = 0.0036, -- same absolute sideways probe as 20% at 2000 RPM
    -- Sideslip: drift past sway_engage (m/s) is braked with the same-side
    -- pullers until it is under sway_settle, then the sway force rests.
    sway_authority = 42,  -- first guess: m/s^2 sideways at full RCS
    min_sway_authority = 1.1,
    sway_gain = 0.3,      -- (m/s^2) per m/s of sideslip
    sway_engage = 0.2,    -- m/s
    sway_settle = 0.08,   -- m/s
    sway_lag = 1.0,       -- s: drift the props' current spin will still add (they spin down slowly)
    turn_yield_drift = 0.5, -- m/s sideways (off target): the turn slows and the sideways force gets the RCS first
    turn_yield_rate = 3,  -- deg/s: turn rate cap while yielding
    yaw_lag = 1.0,        -- s: lead on yaw rate, including the enforced per-motor write interval
  },

  -- NAV: 'goto' and routes (see ap3/nav.lua).
  nav = {
    speed = 25,            -- default transit speed, m/s ('spd' changes it while NAV flies)
    min_speed = 5,         -- slowest transit speed 'spd' may set
    min_transit_alt = 500, -- CLIMB and TRANSIT fly at least this high (ground Warium fire); a stop's Y is reached over the point
    brake_accel = 0.5,     -- planned deceleration approaching a stop, m/s^2
    stop_margin = 4,       -- blocks short of a stop where the transit profile reaches 0
    align_deg = 20,        -- no forward speed while the bow is further than this off the course
    capture = 8,           -- stop waypoint: HOLD takes over inside this distance
    pass_radius = 12,      -- fly-through waypoint: the next leg starts inside this distance
    translate_radius = 24, -- a stop this close when its leg starts is reached by translation alone
    climb_band = 1.5,      -- CLIMB ends within this many blocks of the transit altitude
    arrive = 1.0,          -- a stop counts as reached within this many blocks (with bearing and altitude)
    stop_speed = 0.5,      -- HOLD: the speed loop brakes until ground speed is under this (m/s)
    stop_push = 0.05,      -- and the pushers' props push under this (m/s^2); then station keeping holds the point
    pause_vy = 0.3,        -- a paused descent holds the height where its vertical speed fell under this (m/s)
    settle_time = 3,       -- s settled at a stop before the next leg starts
    max_legs = 20,
    max_points = 30,
  },

  -- Station keeping (HOVER, NAV HOLD, DOCK): see ap3/station.lua.
  station = {
    capture = 0.5,         -- HOVER takes its point once ground speed drops under this (m/s), where the hull will stop
    lead = 1.0,            -- s: steer on the hull's position this far ahead (server delay, paced writes, prop spin)
    pos_gain = 0.25,       -- (m/s) wanted per block of error
    plan_accel = 0.08,     -- m/s^2: the wanted speed slows at this rate approaching the point
    vel_gain = 0.4,        -- m/s^2 per m/s of speed error
    int_gain = 0.004,      -- m/s^2 per block-second (cancels steady pushes)
    int_limit = 0.08,      -- m/s^2
    int_zone = 2,          -- blocks: the integral only runs this close to the point
    max_accel = 0.15,      -- m/s^2 asked of the pushers or the RCS
    fwd_max = 2,           -- fastest fore/aft move, m/s
    side_max = 1.5,        -- fastest sideways move, m/s
    delay = 0.4,           -- s from a write to the props answering (fitted from recordings)
    learn_window = 0.5,    -- s per sample of each axis' learned gain
    learn_forget = 0.98,   -- per sample (about 25 s memory)
    learn_min_accel = 0.01, -- m/s^2 of modelled push needed to learn from a sample
    min_gain = 0.2,        -- learned gain bounds (real strength / the strength the speed and sway loops learned)
    max_gain = 8,
  },

  -- Flight recorder ('rec on'): one CSV row every 'every' control steps.
  rec = { every = 2, min_free = 100000 }, -- stops itself when the disk has less than min_free bytes

  -- Host inbox: commands in terminal syntax, one per line, written into this
  -- computer's folder on the server host. Replies are appended to log; while
  -- the inbox was used in the last 'active' s, a status snapshot is written
  -- every 'poll' s.
  host = { inbox = "/ap3_host.in", log = "/ap3_host.log", status = "/ap3_host.status", poll = 1, active = 900 },

  -- DEBUG mode RPM for every motor (written to the block as is).
  debug_rpm = 15,

  -- RCS check (terminal 'rcs check' or SYS RCS CHECK, in HOVER): finds which
  -- motor is at which corner. Each corner pulls at rpm for 'on' s, then
  -- coasts while its effect is measured, then the hull settles.
  rcs_check = {
    rpm = 2000, on = 4, coast = 2, settle = 4,
    min_v = 0.03,         -- m/s: smaller changes in speed are not a reading
    min_deg = 0.1,        -- degrees: the two corners on a side must turn the hull this differently
  },

  -- Bomb bay: redstone relays prefix..13 to prefix..58 trigger one bomb each
  -- (every side fired), prefix..59 closes the bay doors when powered. Drops need the doors
  -- open for door_settle s, Y >= bomb_min_altitude and bomb_min_interval s
  -- since the last salvo. Triggers pulse for bomb_pulse s; the doors close
  -- door_close_delay s after the pulse ends.
  bombs = {
    relay_prefix = "redstone_relay_",
    door_relay = 59,
    door_open_signal = false, -- no signal opens; a signal closes the doors
    bomb_min_altitude = 200,
    bomb_min_interval = 5,
    door_settle = 1,
    door_close_delay = 10,
    bomb_pulse = 0.5,
    sizes = { 1, 3, 5, 10, "all" },
  },

  -- Files on the computer.
  cal_file = "/ap3_cal.dat",
  mfd_file = "/ap3_mfd.dat",
  bomb_file = "/ap3_bombs.dat",   -- bombs used and salvo size
  rcs_off_file = "/ap3_rcs.off",  -- present while the helm steers (rcs off)
  nav_file = "/ap3_nav.dat",      -- waypoints and the stored route
  rec_file = "/ap3_rec.csv",      -- flight recorder output
}
