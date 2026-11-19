local numeric = require("numeric")
local M = {}

local function dot(a, b)
  return a.x * b.x + a.y * b.y + a.z * b.z
end

function M.rotate(q, v)
  local u=q.v or q
  local w=q.a or q.w
  assert(numeric.finite(w) and numeric.finite(u.x) and numeric.finite(u.y) and numeric.finite(u.z), "invalid quaternion")
  local norm=math.sqrt(w*w+dot(u,u)); assert(norm>0,"zero quaternion")
  local x,y,z=u.x/norm,u.y/norm,u.z/norm; w=w/norm
  local tx,ty,tz=2*(y*v.z-z*v.y),2*(z*v.x-x*v.z),2*(x*v.y-y*v.x)
  return {x=v.x+w*tx+y*tz-z*ty,y=v.y+w*ty+z*tx-x*tz,z=v.z+w*tz+x*ty-y*tx}
end

function M.axes(forward_axis)
  local known = {
    ["+x"] = { x = 1, y = 0, z = 0 },
    ["-x"] = { x = -1, y = 0, z = 0 },
    ["+z"] = { x = 0, y = 0, z = 1 },
    ["-z"] = { x = 0, y = 0, z = -1 },
  }
  local f = known[forward_axis]
  if f == nil then
    error("forward_axis must be +x, -x, +z or -z")
  end
  return {
    forward = f,
    right = { x = -f.z, y = 0, z = f.x },
    up = { x = 0, y = 1, z = 0 },
  }
end

local function valid_vector(v)
  return type(v) == "table" and numeric.finite(v.x) and numeric.finite(v.y) and numeric.finite(v.z)
end

function M.sample(pos, vel, q, prev, dt, forward_axis)
  local u = type(q) == "table" and (q.v or q) or nil
  local w = type(q) == "table" and (q.a or q.w) or nil
  if not valid_vector(pos) or not valid_vector(vel) or type(u) ~= "table"
      or not numeric.finite(u.x) or not numeric.finite(u.y) or not numeric.finite(u.z)
      or not numeric.finite(w) or not numeric.finite(dt) or dt <= 0 then
    error("invalid ship telemetry")
  end
  local axes = M.axes(forward_axis)
  local f = M.rotate(q, axes.forward)
  local r = M.rotate(q, axes.right)
  local heading = numeric.atan2(f.x, -f.z)
  local pitch = math.asin(numeric.clamp(f.y, -1, 1))
  local roll = -math.asin(numeric.clamp(r.y, -1, 1))
  local pitch_rate, roll_rate, yaw_rate = 0, 0, 0
  if prev ~= nil then
    if not numeric.finite(prev.pitch) or not numeric.finite(prev.roll) or not numeric.finite(prev.heading) then
      error("invalid ship telemetry")
    end
    pitch_rate = (pitch - prev.pitch) / dt
    roll_rate = (roll - prev.roll) / dt
    yaw_rate = numeric.wrap(heading - prev.heading) / dt
  end
  local sample = {
    x = pos.x, y = pos.y, z = pos.z,
    vx = vel.x, vy = vel.y, vz = vel.z,
    forward_speed = dot(vel, f),
    side_speed = dot(vel, r),
    heading = heading,
    pitch = pitch,
    roll = roll,
    pitch_rate = pitch_rate,
    roll_rate = roll_rate,
    yaw_rate = yaw_rate,
    dt = dt,
  }
  for _, value in pairs(sample) do
    if type(value) == "number" and not numeric.finite(value) then
      error("invalid ship telemetry")
    end
  end
  return sample
end

return M
