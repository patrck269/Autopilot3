local attitude = require("attitude")
local bombs_module = require("bombs")
local canvas = require("canvas")
local config_module = require("config")
local flight = require("flight")
local mfd = require("mfd")
local numeric = require("numeric")

local M = {}
local App = {}
App.__index = App
local SIDES = { "top", "bottom", "left", "right", "front", "back" }
local MOTOR_ROLES = {
  "elev_pb", "elev_ps", "elev_sb", "elev_ss",
  "rcs_pb", "rcs_ps", "rcs_sb", "rcs_ss",
  "push_port", "push_stbd",
}

local function copy_array(values)
  local result = {}
  for index, value in ipairs(values or {}) do result[index] = value end
  return result
end

local function valid_number_or_nil(value)
  return value == nil or numeric.finite(value)
end

local function relay_ok(dev)
  return type(dev) == "table" and type(dev.setOutput) == "function"
end

local function set_relay(dev, value)
  if not relay_ok(dev) then return end
  for _, side in ipairs(SIDES) do dev.setOutput(side, value) end
end

function M.new(env, cfg)
  local self = setmetatable({}, App)
  self.env = env
  self.cfg = cfg
  self.flight = flight.new_state(cfg)
  self.bombs = bombs_module.new()
  self.pages = {}
  self.motors = {}
  self.relays = {}
  self.monitors = {}
  self.motor_cache = {}
  self.monitor_frames = {}
  self.layouts = {}
  self.logs = {}
  self.last_message = ""
  self.alert = ""
  self.control_error = false
  self.rcs_disabled = false
  self.prev_sample = nil
  self.sample = nil
  self.last_control_at = nil
  self.last_persist_at = env.clock()
  self.confirm = nil
  self.preview_cache = {}
  self.redraw_timer = nil
  self.bomb_timer = nil
  self.bomb_timer_deadline = nil
  self.kb = { field=nil, buffer="", pressed={}, order=0 }
  return self
end

function App:log(message)
  message = tostring(message)
  self.logs[#self.logs + 1] = message
  while #self.logs > 8 do table.remove(self.logs, 1) end
  self.last_message = message
end

function App:monitor_names()
  local names = {}
  for name in pairs(self.monitors) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function App:scan()
  local old_motors = self.motors
  local motors, relays, monitors = {}, {}, {}
  local names = copy_array(self.env.peripheral.getNames())
  table.sort(names)
  for _, name in ipairs(names) do
    local kind = self.env.peripheral.getType(name)
    local dev = self.env.peripheral.wrap(name)
    if kind == "electric_motor" then
      for role, id in pairs(self.cfg.motors) do
        if name == config_module.motor_name(id) then motors[role] = dev end
      end
    elseif kind == "redstone_relay" and relay_ok(dev) then
      local id = tonumber(name:match("^redstone_relay_(%d+)$"))
      if id ~= nil then relays[id] = dev end
    elseif kind == "monitor" then
      monitors[name] = dev
      if type(dev.setTextScale) == "function" then dev.setTextScale(0.5) end
    end
  end
  for _, role in ipairs(MOTOR_ROLES) do
    if old_motors[role] ~= motors[role] then self.motor_cache[role] = nil end
  end
  self.motors, self.relays, self.monitors = motors, relays, monitors
  self.pages = mfd.assign(self:monitor_names(), self.pages)
  self.preview_cache = {}
end

function App:persisted_state()
  local f = self.flight
  return {
    flight = {
      mode=f.mode, emergency=f.emergency, alt_target=f.alt_target,
      bearing_target=f.bearing_target, speed_target=f.speed_target,
      waypoint_x=f.waypoint_x, waypoint_z=f.waypoint_z, profile=f.profile,
      phase=f.phase, cruise_alt=f.cruise_alt, hover_rpm=f.hover_rpm,
      trim_pitch=f.trim_pitch, trim_roll=f.trim_roll, push_i=f.push_i,
    },
    bombs = { used=self.bombs.used, size=self.bombs.size },
    pages = self.pages,
  }
end

function App:save()
  local path, temp = self.cfg.state_file, self.cfg.state_file .. ".tmp"
  local ok, err = pcall(function()
    local handle = assert(self.env.fs.open(temp, "w"), "cannot open state temp file")
    handle.write(self.env.textutils.serialize(self:persisted_state()))
    handle.close()
    if self.env.fs.exists(path) then self.env.fs.delete(path) end
    self.env.fs.move(temp, path)
  end)
  if not ok then
    self:log("state save failed: " .. tostring(err))
    return false
  end
  self.last_persist_at = self.env.clock()
  return true
end

local function state_valid(saved)
  if type(saved) ~= "table" or type(saved.flight) ~= "table"
      or type(saved.bombs) ~= "table" or type(saved.pages) ~= "table" then return false end
  local f = saved.flight
  if type(f.mode) ~= "string" or type(f.emergency) ~= "boolean"
      or not valid_number_or_nil(f.alt_target) or not valid_number_or_nil(f.bearing_target)
      or not valid_number_or_nil(f.speed_target) or not valid_number_or_nil(f.waypoint_x)
      or not valid_number_or_nil(f.waypoint_z) or type(f.profile) ~= "string"
      or not valid_number_or_nil(f.cruise_alt) or not numeric.finite(f.hover_rpm)
      or not numeric.finite(f.trim_pitch) or not numeric.finite(f.trim_roll)
      or not numeric.finite(f.push_i) then return false end
  if type(saved.bombs.used) ~= "table" then return false end
  local size_ok = saved.bombs.size == "all" or type(saved.bombs.size) == "number"
  if not size_ok then return false end
  for id, used in pairs(saved.bombs.used) do
    if type(id) ~= "number" or id < 13 or id > 58 or used ~= true then return false end
  end
  for name, page in pairs(saved.pages) do
    if type(name) ~= "string" or type(page) ~= "string" then return false end
  end
  return true
end

function App:load()
  local path = self.cfg.state_file
  if not self.env.fs.exists(path) then return end
  local ok, saved = pcall(function()
    local handle = assert(self.env.fs.open(path, "r"), "cannot open state file")
    local body = handle.readAll()
    handle.close()
    return self.env.textutils.unserialize(body)
  end)
  if not ok or not state_valid(saved) then
    self:log("state file ignored")
    self.flight = flight.new_state(self.cfg)
    self.bombs = bombs_module.new()
    self.pages = {}
    return
  end
  local fresh = flight.new_state(self.cfg)
  for key, value in pairs(saved.flight) do fresh[key] = value end
  fresh.ramp = fresh.speed_target or 0
  fresh.ramp_rate = 0
  fresh.stick = {x=0,y=0,z=0}
  self.flight = fresh
  self.bombs = bombs_module.new()
  self.bombs.used = saved.bombs.used
  self.bombs.size = saved.bombs.size
  self.pages = saved.pages
end

function App:refresh_rcs_disabled(log_change)
  local disabled = self.env.fs.exists(self.cfg.rcs_disable_file)
  if log_change and disabled ~= self.rcs_disabled then
    self:log(disabled and "RCS thrusters disabled" or "RCS thrusters enabled")
  end
  self.rcs_disabled = disabled
end

function App:start()
  self:scan()
  self:load()
  self:refresh_rcs_disabled(false)
  self.pages = mfd.assign(self:monitor_names(), self.pages)
  self.kb.profile = self.flight.profile
  self.kb.bomb_size = self.bombs.size
  for id = self.cfg.bomb_first, self.cfg.bomb_last do set_relay(self.relays[id], false) end
  set_relay(self.relays[self.cfg.door_relay], false)
  self.bombs.doors_open = false
  self.bombs.opened_at = nil
  self.redraw_timer = self.env.start_timer(self.cfg.redraw)
end

function App:missing_motors()
  local missing = {}
  for _, role in ipairs(MOTOR_ROLES) do
    if self.motors[role] == nil then
      missing[#missing + 1] = config_module.motor_name(self.cfg.motors[role])
    end
  end
  table.sort(missing)
  return missing
end

local function round(value)
  return math.floor(value + 0.5)
end

function App:motors_apply(wanted)
  local writes = {}
  for _, role in ipairs(MOTOR_ROLES) do
    local is_rcs = role:match("^rcs_") ~= nil
    local cap = role:match("^elev_") and self.cfg.elev_max
      or (is_rcs and self.cfg.rcs_max or self.cfg.push_max)
    local requested = is_rcs and self.rcs_disabled and 0 or (wanted[role] or 0)
    local rpm = round(numeric.clamp(requested, -cap, cap) * self.cfg.motor_sign[role])
    local cached = self.motor_cache[role]
    local sign_changed = cached ~= nil and ((rpm < 0 and cached >= 0) or (rpm > 0 and cached <= 0))
    local should_write = cached == nil or math.abs(rpm - cached) >= self.cfg.write_deadband
      or ((rpm == 0) ~= (cached == 0)) or sign_changed
    local dev = self.motors[role]
    if dev ~= nil and should_write then
      writes[#writes + 1] = function()
        local ok, err = pcall(dev.setSpeed, rpm)
        if ok then
          self.motor_cache[role] = rpm
        else
          self:log(role .. " write failed: " .. tostring(err))
        end
      end
    end
  end
  if #writes > 0 then self.env.run_all(writes) end
end

function App:control_tick()
  local now = self.env.clock()
  local dt = self.last_control_at and now - self.last_control_at or self.cfg.tick
  if not numeric.finite(dt) or dt <= 0 then dt = self.cfg.tick end
  self.last_control_at = now
  local ok, sample_or_error = pcall(function()
    local pos = self.env.ship.getWorldspacePosition()
    local vel = self.env.ship.getVelocity()
    local q = self.env.ship.getQuaternion()
    return attitude.sample(pos, vel, q, self.prev_sample, dt, self.cfg.forward_axis)
  end)
  if not ok then
    self.alert = "no ship data"
    return
  end
  local sample = sample_or_error
  self.prev_sample, self.sample = sample, sample
  local missing = self:missing_motors()
  if #missing > 0 then
    self.alert = "MISSING " .. table.concat(missing, " ")
    return
  end
  local stepped, output = pcall(flight.step, self.flight, sample, self.cfg)
  if not stepped then
    self.control_error = true
    self.alert = "control error: " .. tostring(output)
    self:log(self.alert)
    return
  end
  self.control_error = false
  self.alert = ""
  if output ~= nil then self:motors_apply(output) end
  if self.flight.mode ~= "standby" and now - self.last_persist_at >= self.cfg.persist_every then
    self:save()
  end
end

function App:all_missing()
  local missing = self:missing_motors()
  for id = self.cfg.bomb_first, self.cfg.bomb_last do
    if self.relays[id] == nil then missing[#missing+1] = config_module.relay_name(id) end
  end
  if self.relays[self.cfg.door_relay] == nil then
    missing[#missing+1] = config_module.relay_name(self.cfg.door_relay)
  end
  table.sort(missing)
  return missing
end

function App:bomb_preview()
  local used = {}
  for id = self.cfg.bomb_first, self.cfg.bomb_last do
    if self.bombs.used[id] then used[#used+1] = id end
  end
  local key = tostring(self.bombs.size) .. ":" .. table.concat(used, ",")
  local cached = self.preview_cache[key]
  if cached ~= nil then return cached.ids, cached.reason end
  local ids, reason = bombs_module.select(bombs_module.available(self.bombs, self.relays), self.bombs.size)
  self.preview_cache[key] = {ids=ids, reason=reason}
  return ids, reason
end

function App:view()
  local s, f = self.sample or {}, self.flight
  local available = bombs_module.available(self.bombs, self.relays)
  local preview, preview_reason = self:bomb_preview()
  local bomb_reason = bombs_module.check(self.bombs, self.env.clock(), s.y,
    relay_ok(self.relays[self.cfg.door_relay]), self.cfg) or preview_reason
  local motor_states = {}
  for _, role in ipairs(MOTOR_ROLES) do
    local dev = self.motors[role]
    local rpm = self.motor_cache[role]
    motor_states[role] = {present=dev~=nil,rpm=rpm or 0}
  end
  local distance, waypoint_bearing
  if f.waypoint_x ~= nil and f.waypoint_z ~= nil and s.x ~= nil then
    local dx, dz = f.waypoint_x-s.x, f.waypoint_z-s.z
    distance = math.sqrt(dx*dx+dz*dz)
    waypoint_bearing = numeric.atan2(dx,-dz)
  end
  local present = {}
  for id = self.cfg.bomb_first, self.cfg.bomb_last do present[id] = relay_ok(self.relays[id]) end
  local display_alert = self.alert
  if self.rcs_disabled and display_alert == "" then display_alert = "RCS OFF" end
  return {
    colors=self.env.colors, now=self.env.clock(), mode=f.mode, emergency=f.emergency,
    y=s.y, vy=s.vy, heading=s.heading, yaw_rate=s.yaw_rate,
    forward_speed=s.forward_speed, side_speed=s.side_speed,
    pitch=s.pitch, roll=s.roll, alt_target=f.alt_target,
    bearing_target=f.bearing_target, speed_target=f.speed_target, ramp=f.ramp,
    waypoint_x=f.waypoint_x, waypoint_z=f.waypoint_z, profile=f.profile,
    phase=f.phase, distance=distance, waypoint_bearing=waypoint_bearing,
    hover_rpm=f.hover_rpm, trim_pitch=f.trim_pitch, trim_roll=f.trim_roll, push_i=f.push_i,
    bombs=self.bombs, bomb_sizes=self.cfg.bomb_sizes, bomb_relays=present,
    bombs_left=#available, bomb_preview=preview, bomb_reason=bomb_reason,
    missing=self:all_missing(), motor_states=motor_states,
    monitor_count=#self:monitor_names(), logs=self.logs, last_message=self.last_message,
    alert=display_alert, control_error=self.control_error, confirm=self.confirm,
    rcs_disabled=self.rcs_disabled,
  }
end

function App:redraw_monitor(name)
  local mon = self.monitors[name]
  if mon == nil then return end
  local w, h = mon.getSize()
  local page = self.pages[name] or mfd.PAGES[1]
  local view = self:view()
  local layout = mfd.layout(page, w, h, view)
  local c = canvas.new(w, h, self.env.colors)
  mfd.draw(c, page, view, layout)
  canvas.flush(self.monitor_frames, name, mon, c)
  self.layouts[name] = layout
end
function App:draw_terminal()
  local term = self.env.term
  if type(term) ~= "table" or type(term.setCursorPos) ~= "function"
      or type(term.write) ~= "function" or type(term.clear) ~= "function" then return end
  local colors = self.env.colors
  local width = 51
  if type(term.getSize) == "function" then width = select(1, term.getSize()) end
  local function line(row, text, foreground, background)
    text = tostring(text or "")
    if #text < width then text = text .. string.rep(" ", width - #text) end
    foreground = foreground or colors.white
    background = background or colors.black
    if type(term.setTextColor) == "function" then term.setTextColor(foreground) end
    if type(term.setBackgroundColor) == "function" then term.setBackgroundColor(background) end
    term.setCursorPos(1, row)
    term.write(text:sub(1, width))
  end
  if type(term.setBackgroundColor) == "function" then term.setBackgroundColor(colors.black) end
  if type(term.setTextColor) == "function" then term.setTextColor(colors.white) end
  term.clear()
  local view = self:view()
  local danger = view.emergency or #view.missing > 0 or view.control_error
  local banner = string.format("AUTOPILOT 3.0 %s%s ALT %s HDG %s SPD %s %s",
    string.upper(view.mode or "standby"), view.emergency and " EMERG" or "",
    view.y and string.format("%.1f", view.y) or "--",
    view.heading and string.format("%.0f", math.deg(view.heading) % 360) or "--",
    view.forward_speed and string.format("%.1f", view.forward_speed) or "--",
    view.alert or "")
  line(1, banner, colors.black, danger and colors.red or colors.lightBlue)
  line(3, "M Manual  S Semi  U Auto  T Standby", colors.white, colors.black)
  line(4, "Arrows move  Space/LeftShift vertical")
  line(5, "Y altitude  B bearing  V speed")
  line(6, "X/Z waypoint  W cruise/warp")
  line(7, "O/P doors  F drop  [/] salvo size")
  line(8, "E emergency stop  C clear emergency")
  local fields = {
    {"altitude", "Y Altitude", self.flight.alt_target},
    {"bearing", "B Bearing", math.deg(self.flight.bearing_target or 0) % 360},
    {"speed", "V Speed", self.flight.speed_target},
    {"waypoint_x", "X Waypoint", self.flight.waypoint_x},
    {"waypoint_z", "Z Waypoint", self.flight.waypoint_z},
  }
  for index, item in ipairs(fields) do
    local value = self.kb.field == item[1] and (self.kb.buffer .. "_")
      or (item[3] == nil and "--" or string.format("%.1f", item[3]))
    line(9 + index, item[2] .. ": " .. value)
  end
  local missing = view.missing
  line(16, #missing == 0 and "Missing: none" or ("Missing: " .. table.concat(missing, " ")),
    #missing == 0 and colors.white or colors.red)
  line(18, "Last: " .. (self.last_message or ""))
end


function App:redraw_all()
  for _, name in ipairs(self:monitor_names()) do self:redraw_monitor(name) end
  if self.draw_terminal ~= nil then self:draw_terminal() end
end

local function mode_name(mode)
  return string.upper(mode or "standby")
end

function App:apply(action)
  local now = self.env.clock()
  if action.type ~= "page" and action.type ~= "confirm" then self.confirm = nil end
  local message
  if action.type == "mode" then
    local reason = flight.enter(self.flight, action.mode, self.sample, self.cfg)
    message = reason or ("mode " .. mode_name(action.mode))
  elseif action.type == "emergency" then
    self.flight.emergency = true
    message = "EMERGENCY STOP"
  elseif action.type == "clear_emergency" then
    self.flight.emergency = false
    self.flight.mode = "standby"
    message = "emergency cleared; STANDBY"
  elseif action.type == "alt_nudge" then
    if self.flight.mode == "manual" or self.flight.mode == "semi" then
      self.flight.alt_target = self.flight.alt_target + action.delta
      message = "altitude " .. self.flight.alt_target
    else message = "altitude not adjustable in " .. mode_name(self.flight.mode) end
  elseif action.type == "hdg_nudge" then
    if self.flight.mode == "manual" or self.flight.mode == "semi" then
      self.flight.bearing_target = (self.flight.bearing_target + math.rad(action.delta)) % (2*math.pi)
      message = "bearing " .. math.floor(math.deg(self.flight.bearing_target)+0.5)
    else message = "bearing not adjustable in " .. mode_name(self.flight.mode) end
  elseif action.type == "spd_nudge" then
    if self.flight.mode == "semi" then
      flight.set_speed(self.flight, self.flight.speed_target + action.delta, self.cfg)
      message = "speed " .. self.flight.speed_target
    else message = "speed not adjustable in " .. mode_name(self.flight.mode) end
  elseif action.type == "altitude" then
    self.flight.alt_target = action.value
    message = "altitude " .. action.value
  elseif action.type == "bearing" then
    self.flight.bearing_target = action.value
    message = "bearing " .. math.floor(math.deg(action.value)+0.5)
  elseif action.type == "speed" then
    if self.flight.mode == "semi" then
      flight.set_speed(self.flight, action.value, self.cfg)
      message = "speed " .. self.flight.speed_target
    else message = "speed not adjustable in " .. mode_name(self.flight.mode) end
  elseif action.type == "waypoint_x" or action.type == "waypoint_z" then
    self.flight[action.type] = action.value
    message = action.type:gsub("_", " ") .. " " .. action.value
  elseif action.type == "profile" then
    self.flight.profile = action.profile
    self.kb.profile = action.profile
    message = "profile " .. string.upper(action.profile)
  elseif action.type == "stick" then
    if self.flight.mode == "manual" then
      self.flight.stick = {x=action.x,y=action.y,z=action.z}
      message = string.format("stick %d %d %d", action.x, action.y, action.z)
    else message = "stick not adjustable in " .. mode_name(self.flight.mode) end
  elseif action.type == "bomb_size" then
    self.bombs.size = action.size
    self.kb.bomb_size = action.size
    self.preview_cache = {}
    message = "bomb size " .. tostring(action.size)
  elseif action.type == "doors" then
    local door = self.relays[self.cfg.door_relay]
    if not relay_ok(door) then message = "doors relay missing"
    elseif action.open then bombs_module.open_doors(self.bombs, now, door); message = "doors opened"
    else
      local _, reason = bombs_module.close_doors(self.bombs, door)
      message = reason or "doors closed"
    end
  elseif action.type == "drop" then
    local ids, reason = bombs_module.drop(self.bombs, now, self.sample and self.sample.y,
      self.relays, self.cfg, function() self:save() end)
    if ids then
      self.preview_cache = {}
      message = "dropped " .. table.concat(ids, ",")
    else message = reason end
  elseif action.type == "confirm" then
    if self.confirm and self.confirm.action == action.action and self.confirm["until"] >= now then
      self.confirm = nil
      if action.action == "emergency" then
        self.flight.emergency = true
        message = "EMERGENCY STOP"
      elseif action.action == "reload" then
        local _, reason = bombs_module.reload(self.bombs)
        self.preview_cache = {}
        message = reason or "bombs reloaded"
      end
    else
      self.confirm = {action=action.action,["until"]=now+3}
      message = "confirm " .. action.action
    end
  elseif action.type == "page" then
    mfd.select(self.pages, action.name, action.page)
    message = "page " .. action.page
  else
    message = "unknown action"
  end
  self:log(message)
  self:save()
  self:schedule_bomb_timer()
  return message
end

function App:schedule_bomb_timer()
  local deadline = bombs_module.deadline(self.bombs)
  if deadline == nil then
    self.bomb_timer, self.bomb_timer_deadline = nil, nil
    return
  end
  if self.bomb_timer_deadline ~= deadline then
    self.bomb_timer_deadline = deadline
    self.bomb_timer = self.env.start_timer(math.max(0, deadline - self.env.clock()))
  end
end

function App:handle_event(event, a, b, c)
  if event == "monitor_touch" then
    local name, x, y = a, b, c
    if self.monitors[name] ~= nil then
      local layout = self.layouts[name]
      if layout == nil then
        local w, h = self.monitors[name].getSize()
        layout = mfd.layout(self.pages[name], w, h, self:view())
        self.layouts[name] = layout
      end
      local action = mfd.hit(layout, layout.tabs, x, y)
      if action ~= nil then
        action.name = name
        self:apply(action)
      end
      self:redraw_monitor(name)
    end
  elseif event == "key" or event == "key_up" or event == "char" then
    self.kb.profile = self.flight.profile
    self.kb.bomb_size = self.bombs.size
    local action = require("keys").handle(self.kb, event, a, b, self.env.keys.getName)
    if action ~= nil then
      if action.type == "message" then self:log(action.message) else self:apply(action) end
    end
    self:redraw_all()
  elseif event == "timer" then
    if a == self.bomb_timer then
      self.bomb_timer, self.bomb_timer_deadline = nil, nil
    end
    bombs_module.update(self.bombs, self.env.clock(), self.relays,
      self.relays[self.cfg.door_relay], self.cfg)
    self:schedule_bomb_timer()
    if a == self.redraw_timer then
      self:redraw_all()
      self.redraw_timer = self.env.start_timer(self.cfg.redraw)
    end
  elseif event == "peripheral" or event == "peripheral_detach" or event == "monitor_resize" then
    self:scan()
    self:redraw_all()
  elseif event == "autopilot_rcs_changed" then
    self:refresh_rcs_disabled(true)
    self:redraw_all()
  elseif event == "term_resize" then
    self:redraw_all()
  end
end

function M.cc_env()
  return {
    peripheral=peripheral,
    ship=ship,
    clock=os.clock,
    start_timer=os.startTimer,
    run_all=function(fns) parallel.waitForAll(table.unpack(fns)) end,
    term=term,
    colors=colors,
    keys=keys,
    fs=fs,
    textutils=textutils,
  }
end

return M
