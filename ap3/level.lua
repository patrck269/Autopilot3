-- Four-corner levelling. The altitude loop gives one collective lift RPM L;
-- this spreads it over the four lift corners so the hull stays level:
--   P (pitch) moves lift between bow and stern, R (roll) between port and
--   starboard, each a fraction of L from a PD loop on the attitude plus a
--   slow integral trim that learns an off-centre load.
-- Telemetry signs: positive pitch is nose up, positive roll is starboard down.
local util = require("ap3.util")

local M = {}
M.__index = M

function M.new(cfg)
  return setmetatable({
    c = cfg.level,
    cap = cfg.motors.lift_bow_port.cap,
    trim_pitch = 0,
    trim_roll = 0,
  }, M)
end

function M:reset()
  self.trim_pitch, self.trim_roll = 0, 0
end

-- L: collective lift RPM; s: telemetry; active: airborne (trims learn and
-- the corners are trimmed apart). Returns RPM per lift corner.
function M:mix(L, s, dt, active)
  local c = self.c
  local P, R = 0, 0
  if active and L > 0 then
    self.trim_pitch = util.clamp(self.trim_pitch + c.ki * s.pitch * dt, -c.trim_max, c.trim_max)
    self.trim_roll = util.clamp(self.trim_roll + c.ki * s.roll * dt, -c.trim_max, c.trim_max)
    P = -(c.kp * s.pitch + c.kd * s.pitch_rate + self.trim_pitch)
    R = c.kp * s.roll + c.kd * s.roll_rate + self.trim_roll
  end
  local function corner(f) return util.clamp(L * f, 0, self.cap) end
  return {
    lift_bow_port = corner(1 + P - R),
    lift_bow_stbd = corner(1 + P + R),
    lift_stern_port = corner(1 - P - R),
    lift_stern_stbd = corner(1 - P + R),
  }
end

return M
