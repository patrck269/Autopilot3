local numeric = require("numeric")
local M = {}

local ROLES = {
  "elev_pb", "elev_ps", "elev_sb", "elev_ss",
  "rcs_pb", "rcs_ps", "rcs_sb", "rcs_ss",
  "push_port", "push_stbd",
}

local function clamp(v, lo, hi)
  return numeric.clamp(v, lo, hi)
end

local function normalized(stick)
  local length = math.sqrt(stick.x * stick.x + stick.y * stick.y + stick.z * stick.z)
  if length == 0 then
    return { x = 0, y = 0, z = 0 }
  end
  return { x = stick.x / length, y = stick.y / length, z = stick.z / length }
end

local function zeros()
  local out = {}
  for _, role in ipairs(ROLES) do
    out[role] = 0
  end
  return out
end

function M.new_state(cfg)
  return {
    mode = "standby",
    emergency = false,
    alt_target = 0,
    bearing_target = 0,
    speed_target = 0,
    ramp = 0,
    ramp_rate = 0,
    stick = { x = 0, y = 0, z = 0 },
    waypoint_x = nil,
    waypoint_z = nil,
    profile = "warp",
    phase = nil,
    cruise_alt = cfg.auto_cruise_alt,
    hover_rpm = cfg.hover_rpm_initial,
    trim_pitch = 0,
    trim_roll = 0,
    push_i = 0,
  }
end

function M.enter(st, mode, s, cfg)
  if mode == "standby" then
    st.mode = "standby"
    return nil
  end
  if st.emergency then
    return "clear emergency first"
  end
  if s == nil then
    return "no ship data"
  end
  if mode == "auto" and (st.waypoint_x == nil or st.waypoint_z == nil) then
    return "set waypoint X and Z first"
  end
  if mode == "manual" or mode == "semi" then
    st.alt_target = s.y
    st.bearing_target = s.heading
    st.speed_target = 0
    st.ramp = s.forward_speed
    st.ramp_rate = (0 - st.ramp) / cfg.semi_ramp_seconds
    st.stick = { x = 0, y = 0, z = 0 }
  elseif mode == "auto" then
    st.phase = "climb"
    st.cruise_alt = math.max(cfg.auto_cruise_alt, s.y)
    st.ramp = s.forward_speed
  else
    error("invalid flight mode")
  end
  st.mode = mode
  return nil
end

function M.set_speed(st, value, cfg)
  if st.mode ~= "semi" then
    return false
  end
  st.speed_target = clamp(value, -cfg.semi_speed_cap, cfg.semi_speed_cap)
  st.ramp_rate = (st.speed_target - st.ramp) / cfg.semi_ramp_seconds
  return true
end

local function advance_ramp(st, dt)
  local delta = st.speed_target - st.ramp
  local amount = math.abs(st.ramp_rate) * dt
  if math.abs(delta) <= amount then
    st.ramp = st.speed_target
  elseif delta > 0 then
    st.ramp = st.ramp + amount
  elseif delta < 0 then
    st.ramp = st.ramp - amount
  end
end

function M.step(st, s, cfg)
  if st.emergency then
    return zeros()
  end
  if st.mode == "standby" then
    return nil
  end

  local stick = normalized(st.stick)
  if st.mode == "manual" then
    st.speed_target = cfg.manual_speed * stick.x
    st.ramp_rate = cfg.manual_speed
  elseif st.mode == "auto" then
    require("autonav").step(st, s, cfg)
  end

  local vt
  if st.mode == "manual" and st.stick.z ~= 0 then
    vt = cfg.manual_speed * stick.z
    st.alt_target = s.y
  else
    vt = clamp(cfg.alt_gain * (st.alt_target - s.y), -cfg.max_descent, cfg.max_climb)
  end
  local vertical_error = vt - s.vy
  local hover = st.hover_rpm
  local collective = hover + cfg.vs_kp * hover * vertical_error
  if not ((collective >= cfg.elev_max and vertical_error > 0)
      or (collective <= 0 and vertical_error < 0)) then
    st.hover_rpm = clamp(
      hover + cfg.vs_ki * hover * vertical_error * s.dt,
      cfg.hover_rpm_min, cfg.elev_max)
  end
  collective = clamp(collective, 0, cfg.elev_max)

  st.trim_pitch = clamp(st.trim_pitch + cfg.att_ki * s.pitch * s.dt,
    -cfg.att_trim_max, cfg.att_trim_max)
  st.trim_roll = clamp(st.trim_roll + cfg.att_ki * s.roll * s.dt,
    -cfg.att_trim_max, cfg.att_trim_max)
  local pitch = -hover * (cfg.att_kp * s.pitch + cfg.att_kd * s.pitch_rate + st.trim_pitch)
  local roll = hover * (cfg.att_kp * s.roll + cfg.att_kd * s.roll_rate + st.trim_roll)

  local output = {
    elev_pb = clamp(collective + pitch - roll, 0, cfg.elev_max),
    elev_sb = clamp(collective + pitch + roll, 0, cfg.elev_max),
    elev_ps = clamp(collective - pitch - roll, 0, cfg.elev_max),
    elev_ss = clamp(collective - pitch + roll, 0, cfg.elev_max),
  }

  local heading_error = numeric.wrap(st.bearing_target - s.heading)
  if math.abs(heading_error) < math.rad(cfg.yaw_deadzone_deg) then
    heading_error = 0
  end
  local yaw = clamp(cfg.yaw_kp * heading_error - cfg.yaw_kd * s.yaw_rate,
    -cfg.rcs_max, cfg.rcs_max)
  local side_target = st.mode == "manual" and cfg.manual_speed * stick.y or 0
  local sway = cfg.sway_k * (side_target - s.side_speed)
  local bow = yaw + sway
  local stern = -yaw + sway
  output.rcs_sb = clamp(bow > 0 and bow or 0, 0, cfg.rcs_max)
  output.rcs_pb = clamp(bow < 0 and -bow or 0, 0, cfg.rcs_max)
  output.rcs_ss = clamp(stern > 0 and stern or 0, 0, cfg.rcs_max)
  output.rcs_ps = clamp(stern < 0 and -stern or 0, 0, cfg.rcs_max)

  advance_ramp(st, s.dt)
  local speed_error = st.ramp - s.forward_speed
  local push = st.push_i + cfg.fwd_kp * speed_error
  if not ((push >= cfg.push_max and speed_error > 0)
      or (push <= -cfg.push_max and speed_error < 0)) then
    st.push_i = clamp(st.push_i + cfg.fwd_ki * speed_error * s.dt,
      -cfg.push_max, cfg.push_max)
  end
  push = clamp(push, -cfg.push_max, cfg.push_max)
  output.push_port = push
  output.push_stbd = push
  return output
end

return M
