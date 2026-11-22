-- Runs inside CraftOS-PC (see tests/cc/run.py). Installs ten fake electric
-- motors, 47 fake redstone relays, a wired modem and four monitors into the
-- real CC peripheral API, flies tests/world.lua in a coroutine, starts the
-- real /ap3_start.lua (the repo's startup.lua) and drives the MFDs through
-- monitor_touch events and the terminal through char/key events.
-- Writes /report.txt and shuts the computer down.
package.path = "/?.lua;/?/init.lua;" .. package.path

local scenario = "both"
if fs.exists("/scenario.txt") then
  local h = fs.open("/scenario.txt", "r")
  scenario = h.readAll():gsub("%s", "")
  h.close()
end

local cfg = dofile("/ap3/config.lua")
local W = dofile("/tests/world.lua")
local mfd = require("ap3.mfd")
local w = W.new(cfg.motors, { hover_rpm_sea = 900 }, cfg.gravity)
_G.ship = w.ship
_G.aero = w.aero

-- Fault injection: physics velocity accumulates while displayed world motion is
-- independently stationary, forward or reverse.
local motion_speed, motion_x, motion_at = 0, 100, os.clock()
local function set_motion(speed)
  local now = os.clock()
  motion_x = motion_x + motion_speed * (now - motion_at)
  motion_at, motion_speed = now, speed
end
if scenario == "velocity" then
  ship.getWorldspacePosition = function()
    return { x = motion_x + motion_speed * (os.clock() - motion_at), y = 200, z = 300 }
  end
  ship.getVelocity = function() return { x = 20 + 2 * os.clock(), y = 0, z = 0 } end
  ship.getQuaternion = function() return { v = { x = 0, y = 0, z = 0 }, a = 1 } end
end
if scenario == "nav" then
  -- NAV needs a confirmed bow axis: start from a saved calibration.
  local h = fs.open("/ap3_cal.dat", "w")
  h.write(textutils.serialize({ k = 10 / (W.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } }))
  h.close()
end

local report = {}
local failures = 0
local function check(cond, label, detail)
  if not cond then failures = failures + 1 end
  report[#report + 1] = (cond and "ok    " or "FAIL  ") .. label .. (detail and ("  (" .. tostring(detail) .. ")") or "")
end

-- Fake monitor: records text written by blit/write.
local monitors = {}
local function fake_monitor(name, mw, mh)
  local m = { rows = {}, x = 1, y = 1 }
  local function blank()
    for y = 1, mh do m.rows[y] = string.rep(" ", mw) end
  end
  blank()
  local function put(text)
    local row = m.rows[m.y]
    if not row then return end
    local before = row:sub(1, m.x - 1)
    local after = row:sub(m.x + #text)
    m.rows[m.y] = (before .. text .. after):sub(1, mw)
    m.x = m.x + #text
  end
  m.obj = {
    setTextScale = function() end, getTextScale = function() return 0.5 end,
    getSize = function() return mw, mh end,
    setBackgroundColor = function() end, setTextColor = function() end,
    setBackgroundColour = function() end, setTextColour = function() end,
    clear = blank, setCursorBlink = function() end,
    setCursorPos = function(x, y) m.x, m.y = x, y end,
    getCursorPos = function() return m.x, m.y end,
    write = function(t) put(tostring(t)) end,
    blit = function(t) put(t) end,
    isColor = function() return true end, isColour = function() return true end,
  }
  m.w, m.h = mw, mh
  monitors[name] = m
  return m
end
fake_monitor("monitor_4", 57, 24)
fake_monitor("monitor_5", 57, 24)
fake_monitor("monitor_6", 36, 24)
fake_monitor("monitor_7", 36, 24)

local function screen(name)
  return table.concat(monitors[name].rows, "\n")
end
local function shows(name, text)
  return screen(name):find(text, 1, true) ~= nil
end

local modem = {
  isWireless = function() return false end,
  getNamesRemote = function() return {} end,
}

local fake = {}
for id, c in pairs(cfg.motors) do
  fake[c.name] = { "electric_motor", w.devices[id] }
end
-- Relays log every output change: relay_log[id] = { { t, side, value }, ... }
local relay_log = {}
for id = 13, 59 do
  relay_log[id] = {}
  fake[cfg.bombs.relay_prefix .. id] = { "redstone_relay", {
    setOutput = function(side, value)
      local log = relay_log[id]
      log[#log + 1] = { os.clock(), side, value }
    end,
  } }
end
fake.back = { "modem", modem }
for name, m in pairs(monitors) do fake[name] = { "monitor", m.obj } end
-- monitor_4 also reached under a second name, like a monitor touching the
-- computer that is also wired to a modem: it must carry one MFD, not two.
fake.monitor_9 = { "monitor", monitors.monitor_4.obj }

local held_back = {}
if scenario == "missing" then
  held_back[cfg.motors.lift_bow_port.name] = true
  held_back.back = true -- the wired modem
end

local function visible(name)
  return fake[name] ~= nil and not held_back[name]
end
peripheral.getNames = function()
  local list = {}
  for name in pairs(fake) do if visible(name) then list[#list + 1] = name end end
  table.sort(list)
  return list
end
peripheral.isPresent = function(name) return visible(name) end
peripheral.getType = function(name)
  if visible(name) then return fake[name][1] end
  return nil
end
peripheral.hasType = function(name, t)
  if not visible(name) then return nil end
  return fake[name][1] == t
end
peripheral.wrap = function(name)
  if visible(name) then return fake[name][2] end
  return nil
end
peripheral.call = function(name, method, ...)
  if not visible(name) then error("No peripheral attached: " .. tostring(name)) end
  return fake[name][2][method](...)
end

-- Press the centre of an OSB on a monitor.
local function press(name, pos)
  local m = monitors[name]
  local r = mfd.layout(m.w, m.h).osb[pos]
  os.queueEvent("monitor_touch", name, r.x + math.floor(r.w / 2), r.y + math.floor(r.h / 2))
  sleep(0.3)
end

local function type_line(text)
  for i = 1, #text do
    os.queueEvent("char", text:sub(i, i))
  end
  os.queueEvent("key", keys.enter, false)
  sleep(0.5)
end

-- Keypad digits on the UFC page (same grid as ap3/pages.lua).
local KEYS = { { "7", "8", "9" }, { "4", "5", "6" }, { "1", "2", "3" }, { "-", "0", "." } }
local function keypad(name, digits)
  local m = monitors[name]
  local a = mfd.layout(m.w, m.h).content
  local top = a.y + 3
  local kh = math.max(1, math.floor((a.y + a.h - top) / 4) - 1)
  local kw = math.max(3, math.floor(a.w / 3) - 1)
  for i = 1, #digits do
    local d = digits:sub(i, i)
    for r, row in ipairs(KEYS) do
      for col, k in ipairs(row) do
        if k == d then
          os.queueEvent("monitor_touch", name, a.x + (col - 1) * (kw + 1) + 1, top + (r - 1) * (kh + 1))
          sleep(0.2)
        end
      end
    end
  end
end

-- In game os.clock() counts server ticks, so the autopilot's pacing and the
-- physics share one clock. CraftOS-PC's os.clock is wall time, so the world
-- steps once per 0.05 s of os.clock (catching up after a stall) instead of
-- once per wake-up.
local steps, start_clock = 0, os.clock()
local function physics()
  while true do
    sleep(0.05)
    local due = math.floor((os.clock() - start_clock) / 0.05)
    while steps < due do
      w.step(0.05)
      steps = steps + 1
    end
  end
end

local function dump(title)
  report[#report + 1] = "---- " .. title
  for _, name in ipairs({ "monitor_4", "monitor_5", "monitor_6", "monitor_7" }) do
    report[#report + 1] = "[" .. name .. "]"
    report[#report + 1] = screen(name)
  end
end

local function wait_y(target, seconds)
  local t0 = os.clock()
  while os.clock() - t0 < seconds do
    if math.abs(w.y - target) < 1 and math.abs(w.vy) < 0.3 then return os.clock() - t0 end
    sleep(0.5)
  end
  return nil
end

-- Did any trigger relay (13..58) get an output turned on?
local function any_trigger_on()
  for id = 13, 58 do
    for _, e in ipairs(relay_log[id]) do
      if e[3] == true then return id end
    end
  end
  return nil
end

-- Output changes of relay id to value since index from: list of times, sides.
local function changes(id, value, from)
  local times, sides = {}, {}
  for i = from or 1, #relay_log[id] do
    local e = relay_log[id][i]
    if e[3] == value then
      times[#times + 1] = e[1]
      sides[e[2]] = true
    end
  end
  local n = 0
  for _ in pairs(sides) do n = n + 1 end
  return times, n
end

local function all_motors(value)
  for _, v in pairs(w.cmd) do if v ~= value then return false end end
  return true
end

-- PFD-only, HSI-only text (button labels carry page ids, so page ids alone
-- do not prove which page is shown).
local PFD, HSI = "PITCH ", "DRIFT "

local function both_script()
  sleep(2)
  check(shows("monitor_4", PFD) and shows("monitor_4", "MENU") and shows("monitor_4", "SWAP"),
    "monitor_4 shows PFD with MENU/SWAP buttons")
  check(shows("monitor_5", "BOMB BAY"), "monitor_5 shows BOMB")
  check(shows("monitor_6", HSI), "monitor_6 shows HSI")
  check(shows("monitor_7", "ENGINE"), "monitor_7 shows ENG")
  check(shows("monitor_7", "LFT BP"), "ENG lists the lift motors")
  check(shows("monitor_5", "LOADED 46/46"), "BOMB shows a full bay")
  check(not shows("monitor_4", "SYSTEM"), "monitor_4 reached under two names carries one MFD")
  dump("boot")

  press("monitor_4", "B5") -- SWAP 4 <-> 5
  check(shows("monitor_4", "BOMB BAY") and shows("monitor_5", PFD), "SWAP exchanges monitor_4 and monitor_5")

  press("monitor_6", "B1") -- MENU
  check(shows("monitor_6", "FORMAT MENU"), "MENU opens the format menu")
  press("monitor_6", "T1") -- first page in the list: PFD (shown on monitor_5)
  check(shows("monitor_6", PFD) and shows("monitor_5", HSI),
    "choosing PFD moves it to monitor_6 and sends HSI to monitor_5")

  press("monitor_4", "B3") -- monitor_4 holds display 2's formats: BOMB, HSI, ENG
  check(shows("monitor_4", HSI) and shows("monitor_5", "BOMB BAY"),
    "format button B3 shows HSI on monitor_4 and moves BOMB to monitor_5")

  press("monitor_5", "B4") -- monitor_5 formats: BOMB, AP, UFC -> UFC
  check(shows("monitor_5", "KEYPAD"), "monitor_5 shows the keypad")
  keypad("monitor_5", "120")
  check(shows("monitor_5", "> 120_"), "keypad scratchpad reads 120", screen("monitor_5"):match("> [^\n]*"))
  press("monitor_5", "L1") -- ALT SET
  sleep(0.6)
  check(shows("monitor_6", "TGT   120"), "ALT SET from the keypad reaches the flight loop")

  type_line("hover")
  sleep(1)
  check(shows("monitor_6", " HOVER "), "typed 'hover' engages HOVER")
  local reached = wait_y(120, 70)
  check(reached ~= nil, "ship lifts off and holds Y 120", string.format("y %.2f after %s s", w.y, tostring(reached)))
  sleep(5)
  local band = 1.0
  check(math.abs(w.y - 120) < band, "still at 120 five seconds later (within the hold band)", string.format("y %.2f", w.y))

  press("monitor_5", "B2") -- BOMB
  check(shows("monitor_5", "BOMB BAY"), "monitor_5 back on BOMB")
  type_line("doors open")
  sleep(1.2) -- one-second door lockout, plus command delivery
  check(#changes(59, false) > 0, "doors relay 59 switched off to open")
  type_line("drop")
  sleep(0.6)
  check(shows("monitor_5", "below 200"), "drop at Y 120 refused: below 200")
  check(any_trigger_on() == nil, "no trigger relay fired below 200", tostring(any_trigger_on()))
  dump("drop refused")

  type_line("alt 210")
  reached = wait_y(210, 60)
  check(reached ~= nil, "typed 'alt 210' climbs to and holds 210", string.format("y %.2f", w.y))
  local mark = #relay_log[25]
  local door_mark = #relay_log[59]
  type_line("drop")
  sleep(1.5)
  local on, on_sides = changes(25, true, mark + 1)
  local off, off_sides = changes(25, false, mark + 1)
  check(on_sides == 6, "drop at Y 210 fires relay 25 on all six sides", on_sides .. " sides")
  local pulse = (#on > 0 and #off > 0) and (off[1] - on[1]) or -1
  check(off_sides == 6 and pulse > 0.3 and pulse < 1.0, "relay 25 off again after about 0.5 s",
    string.format("%.2f s, %d sides", pulse, off_sides))
  check(any_trigger_on() == 25, "only the planned bomb fired", tostring(any_trigger_on()))
  check(shows("monitor_5", "LOADED 45/46"), "BOMB shows 45/46 loaded")
  check(fs.exists("/ap3_bombs.dat"), "used bombs saved")
  sleep(11)
  local closed = changes(59, true, door_mark + 1)
  local close_after = (#closed > 0 and #off > 0) and (closed[1] - off[1]) or -1
  check(close_after > 9 and close_after < 11.5, "doors close about 10 s after the pulse",
    string.format("%.2f s", close_after))
  check(shows("monitor_5", "DOORS CLOSED"), "BOMB shows the doors closed")
  dump("after drop")

  type_line("brg 90")
  type_line("spd 20")
  check(shows("monitor_6", "BRG 090") and shows("monitor_6", "TGT   20"),
    "terminal commands set bearing 90 and speed 20")
  type_line("cruise")
  sleep(50) -- a 90 deg turn at the station-keeping turn rate, plus the speed ramp
  local hdg_err = math.abs(((w.psi - 90 + 180) % 360) - 180)
  local speed = math.sqrt(w.vx * w.vx + w.vz * w.vz)
  check(hdg_err < 2, "CRUISE turns to bearing 90", string.format("hdg %.2f", w.psi))
  check(math.abs(speed - 20) < 1.5, "CRUISE holds 20 m/s", string.format("%.2f", speed))
  check(math.abs(w.y - 210) < 2, "CRUISE holds altitude", string.format("y %.2f", w.y))
  check(w.cmd.thrust_port == w.cmd.thrust_stbd, "pushers equal", w.cmd.thrust_port .. "/" .. w.cmd.thrust_stbd)
  dump("cruise")

  type_line("rcs off")
  sleep(2)
  check(w.cmd.thrust_port > 0 and w.cmd.thrust_stbd > 0, "RCS off keeps nonzero CRUISE propulsion")
  type_line("hover")
  sleep(4)
  check(w.cmd.thrust_port == 0 and w.cmd.thrust_stbd == 0, "RCS off releases station-keeping pushers")
  check(math.abs(w.y - 210) < 2, "RCS-off handoff keeps altitude hold")
  type_line("rcs on")
  sleep(3)
  check(w.cmd.thrust_port < 0 and w.cmd.thrust_stbd < 0, "RCS on resumes fore/aft braking")

  press("monitor_5", "B3") -- AP
  check(shows("monitor_5", "AUTOPILOT") and shows("monitor_5", "SPD 0"), "AP shows speed zero beside the speed steps")
  type_line("spd -5")
  type_line("cruise")
  sleep(25)
  local a = math.rad(w.psi)
  local reverse_speed = w.vx * math.sin(a) - w.vz * math.cos(a)
  check(math.abs(reverse_speed + 5) < 1, "typed negative speed cruises astern", string.format("%.2f m/s", reverse_speed))
  press("monitor_7", "B1") -- MENU
  press("monitor_7", "T2") -- AP on the narrow display; ENG moves to monitor_5
  check(shows("monitor_7", "AUTOPILOT") and shows("monitor_7", "SPD 0"), "narrow AP displays the speed-zero button")
  dump("reverse AP")
  press("monitor_7", "R0")
  sleep(20)
  local stopped = math.sqrt(w.vx * w.vx + w.vz * w.vz)
  check(stopped < 0.8 and w.cmd.thrust_port == 0 and w.cmd.thrust_stbd == 0,
    "AP speed-zero button stops reverse travel and rests pushers", string.format("%.2f m/s", stopped))
  check(math.abs(w.y - 210) < 2, "AP speed-zero preserves altitude hold")
  dump("AP speed zero")

  press("monitor_7", "B4") -- AP, CAL, SYS -> SYS
  check(shows("monitor_7", "SYSTEM"), "monitor_7 shows SYS")
  press("monitor_7", "T3") -- DEBUG (arm)
  check(shows("monitor_7", "CONF") and not shows("monitor_6", " DEBUG "), "first DEBUG press only arms")
  press("monitor_7", "T3") -- confirm
  sleep(6) -- the lift steps down to 15 RPM through the slew limit
  check(all_motors(15), "confirmed DEBUG puts all ten motors at +15 RPM")
  check(shows("monitor_6", " DEBUG "), "mode shows DEBUG")
  press("monitor_7", "T5") -- KILL (arm)
  check(shows("monitor_7", "CONF"), "first KILL press arms the confirm")
  press("monitor_7", "T5") -- confirm
  sleep(1)
  check(all_motors(0), "confirmed KILL zeroes all ten motors")
  check(shows("monitor_6", " KILL "), "mode shows KILL")
  check(fs.exists("/ap3_mfd.dat"), "MFD layout saved")
  dump("after kill")
end

local function missing_script()
  sleep(3)
  local function either(text) return shows("monitor_4", text) or shows("monitor_5", text) end
  check(either("START-UP FAILED"), "monitors show the flight start-up failure")
  check(either("No wired modem"), "the missing wired modem is reported")
  check(either("Missing E7 LIFT BOW PORT"), "the missing lift motor is named")
  check(w.writes == 0, "nothing is written to the motors", w.writes)
  dump("missing")
  held_back = {}
  os.queueEvent("peripheral", "back")
  os.queueEvent("peripheral", cfg.motors.lift_bow_port.name)
  sleep(3)
  check(shows("monitor_4", PFD) and not shows("monitor_4", "START-UP FAILED"),
    "after attaching it the flight loop starts")
  dump("attached")
end

local function velocity_script()
  local function reading(name, label)
    return tonumber(screen(name):match(label .. "%s*(%-?%d+%.?%d*)"))
  end
  local function near(name, label, expected)
    local value = reading(name, label)
    check(value ~= nil and math.abs(value - expected) < 0.15,
      name .. " " .. label .. " follows world movement", tostring(value) .. " expected " .. expected)
  end
  sleep(2)
  near("monitor_4", "FWD", 0)
  near("monitor_4", "GS", 0)
  type_line("spd 20")
  type_line("cruise")
  press("monitor_4", "B3") -- AP
  sleep(1)
  near("monitor_4", "FWD", 0)
  local ref = reading("monitor_4", "REF")
  check(ref ~= nil and ref > 0 and math.abs(reading("monitor_4", "FWD") or math.huge) < 0.15,
    "command reference can ramp while measured speed stays zero", ref)
  dump("stationary with accumulating physics velocity")
  set_motion(3)
  sleep(1)
  near("monitor_4", "FWD", 3)
  near("monitor_6", "GS", 3)
  set_motion(-2.5)
  sleep(1)
  near("monitor_4", "FWD", -2.5)
  near("monitor_6", "GS", 2.5)
  dump("reverse world movement with positive physics velocity")
  set_motion(0)
  sleep(1)
  near("monitor_4", "FWD", 0)
  near("monitor_6", "GS", 0)
end

local function nav_script()
  sleep(2)
  type_line("alt 200")
  type_line("hover")
  local reached = wait_y(200, 90)
  check(reached ~= nil, "lifts off and holds Y 200", string.format("y %.2f", w.y))
  type_line("wp save home")
  check(fs.exists("/ap3_nav.dat"), "wp save writes /ap3_nav.dat")
  local tx, tz = math.floor(w.x + 40 + 0.5), math.floor(w.z + 0.5)
  type_line(string.format("goto %d %d 200 90", tx, tz))
  press("monitor_7", "B1") -- MENU
  press("monitor_7", "T4") -- the fourth page: NAV
  check(shows("monitor_7", "LEG 1/1"), "MENU -> NAV shows the active leg")
  -- Up to the transit floor (min_transit_alt), 40 blocks east, back down to 200.
  local t0, arrived, top = os.clock(), nil, 0
  while os.clock() - t0 < 300 do
    top = math.max(top, w.y)
    if shows("monitor_7", "ARRIVED") then arrived = os.clock() - t0; break end
    sleep(0.5)
  end
  check(arrived ~= nil, "NAV page shows ARRIVED within 300 s", tostring(arrived))
  check(top >= cfg.nav.min_transit_alt - 2, "climbed to the transit floor on the way", string.format("top %.1f", top))
  local d = math.sqrt((w.x - tx) ^ 2 + (w.z - tz) ^ 2)
  local herr = math.abs(((w.psi - 90 + 180) % 360) - 180)
  check(d <= 2, "holds within 2 blocks of the point", string.format("%.2f blocks", d))
  check(herr <= cfg.heading.hover_deadzone + 0.5, "points at bearing 90", string.format("hdg %.2f", w.psi))
  check(math.abs(w.y - 200) < 1.5, "at Y 200", string.format("y %.2f", w.y))
  dump("nav arrived")

  type_line("rec on")
  sleep(3)
  type_line("rec off")
  local rows, header = 0, nil
  if fs.exists("/ap3_rec.csv") then
    local h = fs.open("/ap3_rec.csv", "r")
    header = h.readLine()
    while h.readLine() do rows = rows + 1 end
    h.close()
  end
  check(header == require("ap3.recorder").HEADER, "recording has the CSV header", tostring(header))
  check(rows >= 10, "3 s of recording holds at least 10 rows", rows .. " rows")

  -- DOCK page: STEP 5, then STBD 5. Facing east, starboard is +Z.
  press("monitor_7", "B1") -- MENU
  press("monitor_7", "T5") -- the fifth page: DOCK
  sleep(0.5)
  check(shows("monitor_7", "NAV HOLD ARRIVED"), "MENU -> DOCK shows the NAV hold it moves from")
  press("monitor_7", "T3") -- STEP 5
  check(shows("monitor_7", "STEP 5 blocks"), "STEP 5 is selected")
  press("monitor_7", "L4") -- STBD 5
  sleep(1)
  check(shows("monitor_7", "dock stbd 5") and shows("monitor_7", "DOCK HOLD"), "STBD 5 is accepted and becomes a dock hold",
    screen("monitor_7"):match("dock[^\n]*"))
  sleep(40)
  local dd = math.sqrt((w.x - tx) ^ 2 + (w.z - (tz + 5)) ^ 2)
  check(dd <= 2, "the ship holds 5 blocks to starboard", string.format("%.2f blocks off", dd))
  dump("dock stbd 5")

  -- Host inbox: a command file written from outside is run and answered.
  local h = fs.open("/ap3_host.in", "w")
  h.write("wp list\ngoto 10\n")
  h.close()
  sleep(2.5)
  local log = ""
  if fs.exists("/ap3_host.log") then
    local lh = fs.open("/ap3_host.log", "r")
    log = lh.readAll()
    lh.close()
  end
  check(not fs.exists("/ap3_host.in") and log:find("wp list -> OK waypoints: home", 1, true) ~= nil
    and log:find("goto 10 -> REJECTED goto X Z", 1, true) ~= nil, "host inbox commands are run and answered", log)
  check(fs.exists("/ap3_host.status"), "host inbox keeps a status snapshot")
end

local scripts = { both = both_script, missing = missing_script, velocity = velocity_script, nav = nav_script }
local ok, err = pcall(parallel.waitForAny,
  physics,
  function() shell.run("/ap3_start.lua") end,
  scripts[scenario])
if not ok then
  failures = failures + 1
  report[#report + 1] = "FAIL  harness error: " .. tostring(err)
end
report[#report + 1] = failures == 0 and "ALL CC CHECKS PASSED" or (failures .. " CC CHECK(S) FAILED")
local h = fs.open("/report.txt", "w")
h.write(table.concat(report, "\n"))
h.close()
os.shutdown()
