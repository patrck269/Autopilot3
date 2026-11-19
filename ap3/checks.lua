-- Start-up checks: every modem and peripheral the autopilot depends on.
-- Each function returns errors (fatal: the program will not fly)
-- and warnings (shown, but the program runs).
local actuators = require("ap3.actuators")

local M = {}

local TYPES = {
  motor = "electric_motor",
  relay = "redstone_relay",
}

local function has_type(P, name, wanted)
  if P.hasType then
    local ok, yes = pcall(P.hasType, name, wanted)
    if ok and yes ~= nil then return yes end
  end
  local types = { P.getType(name) }
  for _, t in ipairs(types) do
    if t == wanted then return true end
  end
  return false
end

-- Lists attached modems: { wired = {names}, wireless = {names} }
function M.modems(P)
  local found = { wired = {}, wireless = {} }
  for _, name in ipairs(P.getNames()) do
    if has_type(P, name, "modem") then
      local m = P.wrap(name)
      if m and m.isWireless and m.isWireless() then
        found.wireless[#found.wireless + 1] = name
      else
        found.wired[#found.wired + 1] = name
      end
    end
  end
  return found
end

local function device(P, errors, label, name, wanted)
  if not P.isPresent(name) then
    errors[#errors + 1] = "Missing " .. label .. " (" .. name .. ")"
  elseif not has_type(P, name, wanted) then
    errors[#errors + 1] = label .. " (" .. name .. ") is a " .. tostring(P.getType(name)) .. ", expected " .. wanted
  end
end

-- env = { peripheral = P, ship = ship API or nil, aero = aero API or nil }
function M.flight(cfg, env)
  local P = env.peripheral
  local errors, warnings = {}, {}
  if env.ship == nil then
    errors[#errors + 1] = "No CC:VS ship API: this computer is not on a Valkyrien Skies ship"
  end
  if env.aero == nil then
    warnings[#warnings + 1] = "No CC:VS aero API: hover calibration will not scale with air density"
  end
  local modems = M.modems(P)
  if #modems.wired == 0 then
    errors[#errors + 1] = "No wired modem: the motors and relays are reached over a wired modem"
  end
  for _, id in ipairs(actuators.ORDER) do
    local c = cfg.motors[id]
    device(P, errors, c.label, c.name, TYPES.motor)
  end
  -- The bomb bay never blocks flight: missing relays are warnings.
  local b = cfg.bombs
  local function relay_present(id)
    local name = b.relay_prefix .. id
    return P.isPresent(name) and has_type(P, name, TYPES.relay)
  end
  if not relay_present(b.door_relay) then
    warnings[#warnings + 1] = "Missing bomb door relay " .. b.relay_prefix .. b.door_relay .. ": drops refused"
  end
  local missing = {}
  for id = 13, 58 do
    if not relay_present(id) then missing[#missing + 1] = id end
  end
  if #missing > 0 then
    warnings[#warnings + 1] = "Missing bomb relays: " .. table.concat(missing, ",")
  end
  return errors, warnings
end

-- Returns errors, warnings, list of monitor names to use.
function M.command(cfg, env)
  local P = env.peripheral
  local errors, warnings = {}, {}
  local names = {}
  local wanted = cfg.monitors or {}
  if #wanted == 0 then
    for _, name in ipairs(P.getNames()) do
      if has_type(P, name, "monitor") then names[#names + 1] = name end
    end
    table.sort(names)
  else
    for _, name in ipairs(wanted) do
      if P.isPresent(name) and has_type(P, name, "monitor") then
        names[#names + 1] = name
      else
        warnings[#warnings + 1] = "Missing MFD monitor " .. name
      end
    end
  end
  for _, name in ipairs(names) do
    local m = P.wrap(name)
    if m and m.isColor and not m.isColor() then
      warnings[#warnings + 1] = name .. " is not an advanced monitor: no touch or colour"
    end
  end
  if #names == 0 then
    errors[#errors + 1] = "No MFD monitors found"
  end
  return errors, warnings, names
end

return M
