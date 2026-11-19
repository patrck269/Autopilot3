local M = {}

function M.default()
  return {
    tick = 0.05, redraw = 0.25, persist_every = 5,
    state_file = "autopilot3.dat", rcs_disable_file = "autopilot3.rcs-disabled",
    forward_axis = "+x",
    motors = {
      elev_pb = 7, elev_ps = 5, elev_sb = 2, elev_ss = 3,
      rcs_pb = 6, rcs_ps = 4, rcs_sb = 1, rcs_ss = 0,
      push_port = 8, push_stbd = 9,
    },
    motor_sign = { elev_pb=1, elev_ps=1, elev_sb=1, elev_ss=1, rcs_pb=1, rcs_ps=1, rcs_sb=1, rcs_ss=1, push_port=1, push_stbd=1 },
    elev_max = 2750, rcs_max = 2500, push_max = 1500,
    write_deadband = 2,
    alt_gain = 0.2, max_climb = 6, max_descent = 4,
    vs_kp = 0.08, vs_ki = 0.04, hover_rpm_initial = 800, hover_rpm_min = 50,
    att_kp = 0.5, att_kd = 0.3, att_ki = 0.1, att_trim_max = 0.3,
    yaw_kp = 600, yaw_kd = 1200, yaw_deadzone_deg = 0.2, sway_k = 400,
    fwd_kp = 150, fwd_ki = 30,
    manual_speed = 3, semi_speed_cap = 35, semi_ramp_seconds = 15,
    auto_cruise = 7, auto_warp = 50, auto_accel = 50 / 15, auto_brake = 1.0,
    auto_cruise_alt = 400, auto_arrive_alt = 329, arrive_radius = 10, arrive_speed = 0.3,
    bomb_first = 13, bomb_last = 58, door_relay = 59,
    bomb_min_altitude = 200, bomb_min_interval = 5, door_settle = 3,
    door_close_delay = 10, bomb_pulse = 0.5,
    bomb_sizes = { 1, 3, 5, 10, "all" },
  }
end

function M.motor_name(id)
  return "electric_motor_" .. id
end

function M.relay_name(id)
  return "redstone_relay_" .. id
end

return M
