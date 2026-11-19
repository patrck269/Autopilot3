local numeric = require("numeric")
local M = {}

function M.step(st, s, cfg)
  local dx = st.waypoint_x - s.x
  local dz = st.waypoint_z - s.z
  local distance = math.sqrt(dx * dx + dz * dz)
  local bearing = numeric.atan2(dx, -dz)
  local limit = st.profile == "cruise" and cfg.auto_cruise or cfg.auto_warp
  local profile_speed = math.min(limit,
    math.sqrt(2 * cfg.auto_brake * math.max(distance - 5, 0)))
  st.ramp_rate = cfg.auto_accel

  if st.phase == "climb" then
    st.alt_target = st.cruise_alt
    st.speed_target = 0
    st.bearing_target = bearing
    if s.y >= st.cruise_alt - 5 then
      st.phase = "track"
    end
  elseif st.phase == "track" then
    st.alt_target = st.cruise_alt
    st.bearing_target = bearing
    st.speed_target = profile_speed
    if distance <= cfg.arrive_radius and math.abs(s.forward_speed) <= cfg.arrive_speed then
      st.phase = "descend"
    end
  elseif st.phase == "descend" or st.phase == "hold" then
    st.alt_target = cfg.auto_arrive_alt
    if distance > cfg.arrive_radius then
      st.speed_target = math.min(2, profile_speed)
      st.bearing_target = bearing
    else
      st.speed_target = 0
    end
    if st.phase == "descend" and s.y <= cfg.auto_arrive_alt + 2 then
      st.phase = "hold"
    end
  else
    error("invalid auto phase")
  end

  return {
    distance = distance,
    bearing = bearing,
    profile_speed = profile_speed,
  }
end

return M
