-- Motor cadence and emergency behavior against the real motor bank.
package.path = "./?.lua;" .. package.path
local actuators = require("ap3.actuators")
local world = require("tests.world")
local cfg = dofile("ap3/config.lua")

local function fixture(delay)
  local now, calls = 0, {}
  local w = world.new(cfg.motors, { lift = 100 }, cfg.gravity)
  local devices = {}
  for id, dev in pairs(w.devices) do
    devices[id] = {
      getSpeed = dev.getSpeed,
      setSpeed = function(v)
        calls[#calls + 1] = { id = id, t = now, rpm = v }
        dev.setSpeed(v)
        now = now + (delay or 0)
      end,
    }
  end
  local bank = actuators.new(cfg, devices, function() return now end)
  bank:seed()
  return bank, w, calls, function(t) now = t end, function() return now end
end

-- A recently written partner cannot be dragged into another motor's batch.
for _, group in ipairs({ "lift", "rcs", "thrust" }) do
  local bank, _, calls, time = fixture()
  local ids = actuators.GROUPS[group]
  for i, id in ipairs(ids) do
    bank.ch[id].last_write = i == #ids and 0.9 or 0
    bank:set(id, 500)
  end
  time(1)
  assert(bank:service(1) == nil, group .. " batch rewrote a partner before its interval")
  assert(#calls == 0)
  time(2)
  assert(bank:service(2) == ids[1])
  local pinned = calls[1].rpm
  for _, id in ipairs(ids) do bank:set(id, 900) end
  for i = 2, #ids do
    local t = 2 + (i - 1) * 0.05
    time(t)
    assert(bank:service(t) == ids[i])
    assert(calls[i].rpm == pinned, "batch target changed halfway through")
  end
end

-- Repeated requests, mixed lift corners and RCS reversals cannot build an
-- unsafe downstream flicker score. Normal writes are spaced for each motor.
do
  local bank, w, calls, time = fixture()
  for tick = 1, 2400 do
    local t = tick * 0.05
    time(t)
    local high = math.floor(tick / 7) % 2 == 0
    for i, id in ipairs(actuators.ORDER) do
      local rpm = high and 1000 or 100
      if i <= 4 and i % 2 == 0 then rpm = high and 100 or 1000 end
      bank:set(id, rpm)
    end
    bank:service(t)
    w.step(0.05)
  end
  local last, seen = {}, {}
  for _, call in ipairs(calls) do
    local group = bank.ch[call.id].group
    if last[call.id] then
      assert(call.t - last[call.id] + 1e-6 >= cfg.actuator.min_interval[group],
        call.id .. " normal writes violated minimum interval")
    end
    last[call.id], seen[call.id] = call.t, true
  end
  for _, id in ipairs(actuators.ORDER) do assert(seen[id], id .. " starved of writes") end
  local score, id = w.peak_flicker()
  assert(score <= 20, tostring(id) .. " accumulated flicker: " .. score)
  assert(w.pusher_split_max <= 1, "pusher pair split across nonconsecutive ticks")
  print("Rapid requests: peak bearing flicker " .. score .. ", " .. #calls .. " writes")
end

-- Pace from completion of the yielding call. Emergency zero overrides this
-- wait and discards the remaining nonzero batch targets.
do
  local bank, _, calls, time, clock = fixture(0.2)
  bank:set("thrust_port", 400)
  time(1)
  bank:service(1)
  bank:set("thrust_port", 800)
  bank:set("thrust_stbd", 800)
  time(2.05)
  assert(bank:service(2.05) == nil, "next write paced from start, not completion")
  time(2.2)
  assert(bank:service(2.2) == "thrust_port", "eligible write was not released")
  bank:kill()
  local t = clock()
  assert(bank:service(t) == "lift_bow_port", "kill waited for normal pacing")
  for _ = 1, #actuators.ORDER do bank:service(clock()) end
  for _, c in pairs(bank.ch) do assert(c.applied == 0, c.id .. " not killed") end
  for i = 3, #calls do assert(calls[i].rpm == 0, "stale batch survived kill") end
end
print("ALL ACTUATOR CHECKS PASSED")
