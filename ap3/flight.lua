-- Flight loop: checks peripherals, then runs the control loop, the motor
-- writer and the command receiver. The bomb bay runs here too. The command
-- center (ap3/command.lua) owns the terminal and the monitors.
local util = require("ap3.util")
local checks = require("ap3.checks")
local telemetry = require("ap3.telemetry")
local actuators = require("ap3.actuators")
local autopilot = require("ap3.autopilot")
local bombbay = require("ap3.bombbay")
local store = require("ap3.store")
local recorder = require("ap3.recorder")

local M = {}

-- Commands handled by the bomb bay instead of the autopilot.
local BAY = { doors = true, drop = true, salvo = true, reload = true }
-- Flight recorder commands.
local REC = { rec_on = true, rec_off = true }
-- Commands that change the saved waypoints or route.
local NAV_SAVE = { route_add = true, route_clear = true, wp_save = true, wp_del = true }

-- opts = { link = link object }
function M.run(cfg, opts)
  local P = peripheral
  local link = opts.link
  local env = { peripheral = P, ship = ship, aero = aero }
  local warnings

  -- An RCS layout found by an earlier RCS check overrides the config names.
  local saved = store.load(cfg.cal_file)
  if saved then actuators.apply_layout(cfg, saved.rcs_map) end

  -- 1. Required modems and peripherals. Nothing is driven until all are present.
  while true do
    local errors
    errors, warnings = checks.flight(cfg, env)
    if #errors == 0 then break end
    link:send_status({ errors = errors, warnings = warnings })
    local timer = os.startTimer(2)
    while true do
      local ev = os.pullEvent()
      if ev == "peripheral" or ev == "peripheral_detach" or ev == "timer" then break end
    end
    os.cancelTimer(timer)
  end

  local devices = {}
  for id, c in pairs(cfg.motors) do devices[id] = P.wrap(c.name) end
  local bank = actuators.new(cfg, devices)
  bank:seed()
  local bay = bombbay.new(cfg, P, store)
  bay:scan()
  bay:safe()
  local tel = telemetry.new(cfg, { ship = ship, aero = aero, clock = os.clock })
  local ap = autopilot.new(cfg, saved, tel.rho_at(62), tel,
    { rcs_off = fs.exists(cfg.rcs_off_file), nav = store.load(cfg.nav_file) })
  local rec = recorder.new(cfg)
  local slug = ship.getSlug and ship.getSlug() or "ship"

  local last_s = tel.read()
  -- A reboot in the air leaves the lift spinning: take over in HOVER at the
  -- current altitude instead of letting the hull drift.
  local lift = bank:effective("lift")
  if lift > 0 then
    if math.abs(last_s.vy) < 0.5 then ap.alt:seed_from_hover(lift, last_s.rho) end
    ap.tgt.alt = util.round(last_s.y)
    ap:engage("HOVER", last_s)
  end

  local faults = {}
  local message = "ready"
  local last_saved = ap:saved()
  local sent_at = -math.huge

  local function status(now)
    local s = last_s
    local a = ap.alt
    local alerts = ap:alerts(s, now)
    for _, f in pairs(faults) do alerts[#alerts + 1] = f end
    for _, a in ipairs(bank:alerts(now)) do alerts[#alerts + 1] = a end
    if rec.full then alerts[#alerts + 1] = "RECORDER FULL: " .. cfg.rec_file end
    if rec.h then alerts[#alerts + 1] = "RECORDING" end
    local names = ap.nav:names()
    while #names > 10 do table.remove(names) end
    local tgt_alt = ap.tgt.alt or s.y
    local rho_t = tel.rho_at(tgt_alt)
    return {
      slug = slug, t = now,
      mode = ap.mode,
      tgt = { alt = ap.tgt.alt, brg = ap.tgt.brg, spd = ap.tgt.spd },
      s = {
        x = s.x, y = s.y, z = s.z, vy = s.vy,
        gs = s.ground.gs, v_fwd = s.ground.v_fwd, v_side = s.ground.v_side,
        hdg = s.hdg, track = s.ground.track, pitch = s.pitch, roll = s.roll, yaw_rate = s.yaw_rate,
        rho = s.rho, mass = s.mass,
      },
      alt = {
        phase = autopilot.FLYING[ap.mode] and a.phase or "OFF",
        k = a.k, hover_now = a:hover_rpm(s.rho), hover_tgt = a:hover_rpm(rho_t), rho_tgt = rho_t,
        grounded = a.grounded, samples = a.samples, saturated = a.saturated, integ = a.integ,
      },
      spd = {
        phase = (ap.mode == "CRUISE" or ap.mode == "NAV") and ap.spd.phase or (ap.mode == "HOVER" and "STOP" or "OFF"),
        v_ref = ap.spd.v_ref, A = ap.spd.A, drag35 = ap.spd:drag(35), pitch_hold = ap.spd.pitch_hold,
      },
      hdg = {
        err = ap.hdg.err, r_cmd = ap.hdg.r_cmd,
        yaw_b = ap.hdg:authority(),
        sway_auth = ap.motion:sway_authority(), frame_ok = ap.motion.frame_ok or ap.bow_learned,
        sway_active = ap.hdg.sway_active, drift = ap.hdg.drift,
        bow = util.axis_name(tel.forward), bow_learned = ap.bow_learned,
        rcs_checking = ap.check ~= nil, rcs_found = ap.rcs_found ~= nil, rcs_layout = ap.rcs_map ~= nil,
      },
      level = { pitch = ap.level.trim_pitch, roll = ap.level.trim_roll },
      motors = bank:snapshot(now),
      bomb = bay:status(now, s.y),
      nav = {
        phase = ap.nav.phase,
        last = ap.nav.last,
        speed = ap.nav.speed,
        docking = ap.nav.docking,
        points = names,
        route_n = #ap.nav.route,
      },
      rec = { on = rec.h ~= nil, rows = rec.rows, full = rec.full },
      rcs_off = ap.rcs_off,
      alerts = alerts,
      warnings = warnings,
      events = ap.events,
      msg = message,
    }
  end

  local reboot_at = nil
  local function handle(msg)
    if type(msg) ~= "table" then return end
    local ok, text
    if BAY[msg.c] then
      ok, text = bay:command(msg.c, msg.v, last_s, os.clock())
    elseif REC[msg.c] then
      if msg.c == "rec_on" then
        ok, text = rec:start()
      else
        rec:stop()
        ok, text = true, "recording stopped (" .. rec.rows .. " rows)"
      end
    else
      ok, text = ap:command({ c = msg.c, v = msg.v }, last_s)
      if ok and NAV_SAVE[msg.c] then store.save(cfg.nav_file, ap.nav:saved()) end
      if ok and msg.c == "mode" and msg.v == "KILL" then bank:kill() end
      if ok and msg.c == "rcs_apply" then
        -- The layout picks which peripheral drives which corner: save it and
        -- restart so every motor is wrapped under its new corner. The lift
        -- keeps spinning, so the restarted program takes over in HOVER.
        store.save(cfg.cal_file, ap:saved())
        reboot_at = os.clock() + 1
      end
      -- The helm keeps steering after a reboot until 'rcs on'.
      if ok and msg.c == "rcs_off" then store.save(cfg.rcs_off_file, { off = true }) end
      if ok and msg.c == "rcs_on" and fs.exists(cfg.rcs_off_file) then fs.delete(cfg.rcs_off_file) end
      -- Save at once, so a restart cannot bring the old strength back.
      if ok and msg.c == "rcs_reset" then store.save(cfg.cal_file, ap:saved()) end
    end
    message = text
    link:reply({ ok = ok, text = text, seq = msg.seq })
    link:send_status(status(os.clock()))
    sent_at = os.clock()
    return ok, text
  end

  local function control()
    local period = cfg.loop_period
    local timer = os.startTimer(period)
    local last = os.clock()
    local save_at = os.clock() + 30
    while true do
      local ev, id = os.pullEvent("timer")
      if id == timer then
        timer = os.startTimer(period)
        local now = os.clock()
        local dt = util.clamp(now - last, 0.05, 0.5)
        last = now
        local ok, s = pcall(tel.read)
        if ok then
          faults.telemetry = nil
          last_s = s
          local out = ap:step(s, now, dt, bank)
          for _, ch in ipairs(actuators.ORDER) do bank:set(ch, out[ch]) end
          rec:sample(now, s, ap, bank)
        else
          faults.telemetry = "SHIP TELEMETRY: " .. tostring(s)
        end
        bay:update(now)
        if now - sent_at >= cfg.status_period then
          link:send_status(status(now))
          sent_at = now
        end
        if reboot_at and now >= reboot_at then os.reboot() end
        if now >= save_at then
          save_at = now + 30
          local cur = ap:saved()
          local function moved(a, b, tol)
            if a == nil or b == nil then return a ~= b end
            return math.abs(a - b) > tol * math.max(math.abs(b), 1e-9)
          end
          if moved(cur.k, last_saved.k, 0.005) or moved(cur.A, last_saved.A, 0.01)
            or moved(cur.yaw_b, last_saved.yaw_b, 0.05) or cur.rcs_cap ~= last_saved.rcs_cap
            or (cur.bow ~= nil) ~= (last_saved.bow ~= nil)
            or (cur.bow and last_saved.bow and util.dot(cur.bow, last_saved.bow) < 0.9) then
            store.save(cfg.cal_file, cur)
            last_saved = cur
          end
        end
      end
    end
  end

  local function writer()
    while true do
      if bank:service(os.clock()) == nil then sleep(0.05) end
    end
  end

  local function receiver()
    while true do
      local ev = { os.pullEvent() }
      local kind, msg = link:parse(ev)
      if kind == "cmd" then
        handle(msg)
      elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
        for id, c in pairs(cfg.motors) do
          local present = P.isPresent(c.name)
          if present and bank.ch[id].dev == nil then
            bank:set_device(id, P.wrap(c.name))
            bank:seed()
          elseif not present and bank.ch[id].dev ~= nil then
            bank:set_device(id, nil)
          end
        end
        bay:scan()
      end
    end
  end

  parallel.waitForAny(control, writer, receiver)
end

return M
