-- Typed commands for the terminal.
local M = {}

M.HELP = {
  "alt <Y>     target altitude (world Y)",
  "brg <deg>   target bearing (0=N 90=E)",
  "spd <m/s>   target speed (-35 to 35; negative backs up)",
  "hover       hold altitude, stop, hold heading",
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
}

local MODES = { hover = "HOVER", h = "HOVER", cruise = "CRUISE", c = "CRUISE", stby = "STBY", standby = "STBY", off = "STBY", kill = "KILL", debug = "DEBUG" }
local VALUES = { alt = "alt", a = "alt", y = "alt", brg = "brg", b = "brg", hdg = "brg", spd = "spd", s = "spd", speed = "spd" }

-- Returns a command { c =, v = }, or nil and an error, or "help".
function M.parse(line)
  local words = {}
  for w in string.gmatch(string.lower(line or ""), "%S+") do words[#words + 1] = w end
  local head = words[1]
  if head == nil then return nil, "" end
  if head == "help" or head == "?" then return "help" end
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
