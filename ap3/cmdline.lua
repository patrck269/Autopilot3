-- Typed commands for the terminal.
local nav = require("ap3.nav")
local M = {}

M.HELP = {
  "alt <Y>     target altitude (world Y)",
  "brg <deg>   target bearing (0=N 90=E)",
  "spd <m/s>   target speed -35..35 (negative: astern)",
  "hover       hold altitude, position and heading",
  "cruise      altitude + bearing + speed",
  "stby        autopilot off (lift left as is)",
  "kill        cut every motor to 0",
  "debug       every prop at +15 RPM (drops!)",
  "sync        targets = current alt/heading",
  "recal       forget the hover calibration",
  "rcs check   find each RCS corner (HOVER)",
  "rcs apply   use the layout it found",
  "rcs reset   forget the learned RCS strength",
  "doors open|close  bomb bay doors",
  "salvo <1|3|5|10|all>  bombs per drop",
  "drop        drop one salvo (Y>=200, doors open)",
  "reload      mark every bomb loaded",
  "rcs off|on  release RCS to the helm / take it back",
  "goto X Z [Y] [BRG]  fly there and hold (or <name>)",
  "wp save|del <name>, wp list  named waypoints",
  "route add X Z [Y] [BRG]|<name>  add leg (BRG: stop)",
  "route go|clear|list  fly / empty / show the route",
  "rec on|off  flight recorder (/ap3_rec.csv)",
  "dock fwd|aft|port|stbd|up|down N, turn N, here",
}

-- The help lines that fit a view of size rows starting at line top, with top
-- clamped so the view never runs past the end. Returns the lines, the
-- clamped top, the page shown and the page count.
function M.help_view(top, size)
  size = math.max(1, size)
  local n = #M.HELP
  top = math.max(1, math.min(math.floor(top or 1), math.max(1, n - size + 1)))
  local lines = {}
  for i = top, math.min(n, top + size - 1) do lines[#lines + 1] = M.HELP[i] end
  local pages = math.ceil(n / size)
  local page = top + size - 1 >= n and pages or math.floor((top - 1) / size) + 1
  return lines, top, page, pages
end

local MODES = { hover = "HOVER", h = "HOVER", cruise = "CRUISE", c = "CRUISE", stby = "STBY", standby = "STBY", off = "STBY", kill = "KILL", debug = "DEBUG" }
local VALUES = { alt = "alt", a = "alt", y = "alt", brg = "brg", b = "brg", hdg = "brg", spd = "spd", s = "spd", speed = "spd" }

-- A destination from words[i..]: X Z [Y] [BRG] or a waypoint name.
-- Returns the operand or nil.
local function destination(words, i)
  local x, z = tonumber(words[i]), tonumber(words[i + 1])
  if x and z then
    local y, brg = words[i + 2], words[i + 3]
    local yn, bn = tonumber(y), tonumber(brg)
    if (y ~= nil and yn == nil) or (brg ~= nil and bn == nil) or words[i + 4] ~= nil then return nil end
    return { x = x, z = z, y = yn, brg = bn }
  end
  if words[i] ~= nil and words[i + 1] == nil and tonumber(words[i]) == nil then
    return { name = words[i] }
  end
  return nil
end

-- Returns a command { c =, v = }, or nil and an error, or "help" and the
-- page asked for (or nil).
function M.parse(line)
  local words = {}
  for w in string.gmatch(string.lower(line or ""), "%S+") do words[#words + 1] = w end
  local head = words[1]
  if head == nil then return nil, "" end
  if head == "help" or head == "?" then return "help", tonumber(words[2]) end
  if MODES[head] then return { c = "mode", v = MODES[head] } end
  if head == "sync" or head == "recal" or head == "drop" or head == "reload" then return { c = head } end
  if head == "rcs" then
    if words[2] == nil or words[2] == "check" then return { c = "rcs_check" } end
    if words[2] == "apply" then return { c = "rcs_apply" } end
    if words[2] == "off" then return { c = "rcs_off" } end
    if words[2] == "on" then return { c = "rcs_on" } end
    if words[2] == "reset" then return { c = "rcs_reset" } end
    return nil, "rcs check | rcs apply | rcs reset | rcs off | rcs on"
  end
  if head == "goto" then
    local v = destination(words, 2)
    if v == nil then return nil, "goto X Z [Y] [BRG] | goto <name>" end
    return { c = "goto", v = v }
  end
  if head == "route" then
    local sub = words[2]
    if sub == nil or sub == "list" then return { c = "route_list" } end
    if sub == "add" then
      local v = destination(words, 3)
      if v == nil then return nil, "route add X Z [Y] [BRG] | route add <name>" end
      return { c = "route_add", v = v }
    end
    if sub == "clear" then return { c = "route_clear" } end
    if sub == "go" then return { c = "route_go" } end
    return nil, "route add | route clear | route go | route list"
  end
  if head == "wp" then
    local sub, name = words[2], words[3]
    if sub == "list" then return { c = "wp_list" } end
    if (sub == "save" or sub == "del") and name ~= nil then
      if not nav.valid_name(name) then return nil, nav.NAME_ERROR end
      return { c = "wp_" .. sub, v = name }
    end
    return nil, "wp save <name> | wp del <name> | wp list"
  end
  if head == "rec" then
    if words[2] == "on" or words[2] == "off" then return { c = "rec_" .. words[2] } end
    return nil, "rec on | rec off"
  end
  if head == "dock" then
    local move, n = words[2], tonumber(words[3])
    if move == "here" and words[3] == nil then return { c = "dock", v = { move = "here" } } end
    local moves = { fwd = true, aft = true, port = true, stbd = true, up = true, down = true, turn = true }
    if moves[move] and n ~= nil and words[4] == nil then return { c = "dock", v = { move = move, n = n } } end
    return nil, "dock fwd|aft|port|stbd|up|down <blocks> | dock turn <deg> | dock here"
  end
  if head == "doors" then
    if words[2] == "open" or words[2] == "close" then return { c = "doors", v = words[2] } end
    return nil, "doors open | doors close"
  end
  if head == "salvo" then
    if words[2] == nil then return nil, "salvo 1|3|5|10|all" end
    return { c = "salvo", v = tonumber(words[2]) or words[2] }
  end
  local c = VALUES[head]
  if c then
    local v = tonumber(words[2])
    if v == nil then return nil, head .. " needs a number" end
    return { c = c, v = v }
  end
  return nil, "unknown command '" .. head .. "' (type help)"
end

-- A one-line text prompt driven by os.pullEvent events, so the caller's event
-- loop never blocks in read().
function M.prompt()
  local p = { text = "" }
  -- Returns the submitted line when Enter is pressed, else nil.
  function p.handle(ev)
    if ev[1] == "char" then
      p.text = p.text .. ev[2]
    elseif ev[1] == "paste" then
      p.text = p.text .. ev[2]
    elseif ev[1] == "key" then
      if ev[2] == keys.backspace then
        p.text = p.text:sub(1, -2)
      elseif ev[2] == keys.enter or ev[2] == keys.numPadEnter then
        local line = p.text
        p.text = ""
        return line
      end
    end
    return nil
  end
  return p
end

return M
