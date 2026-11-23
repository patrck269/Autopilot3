-- Autopilot 3.0 installer. In game:
--   wget run https://raw.githubusercontent.com/patrck269/Autopilot3/master/install.lua [commit]
-- Installs the latest commit (or the one given), pinned by SHA so every file
-- comes from the same revision, and reboots.
local REPO = "patrck269/Autopilot3"
local FILES = {
  "startup.lua",
  "ap3/actuators.lua",
  "ap3/altitude.lua",
  "ap3/autopilot.lua",
  "ap3/bombbay.lua",
  "ap3/bombs.lua",
  "ap3/canvas.lua",
  "ap3/checks.lua",
  "ap3/cmdline.lua",
  "ap3/command.lua",
  "ap3/config.lua",
  "ap3/flight.lua",
  "ap3/heading.lua",
  "ap3/level.lua",
  "ap3/link.lua",
  "ap3/mfd.lua",
  "ap3/motion.lua",
  "ap3/nav.lua",
  "ap3/pages.lua",
  "ap3/rcscheck.lua",
  "ap3/recorder.lua",
  "ap3/rls.lua",
  "ap3/speed.lua",
  "ap3/station.lua",
  "ap3/store.lua",
  "ap3/telemetry.lua",
  "ap3/util.lua",
}

local commit = ...

if not http then
  printError("HTTP is disabled in the ComputerCraft server config.")
  return
end

local function get(url)
  local h, err = http.get(url, nil, true)
  if not h then return nil, err end
  local body = h.readAll()
  h.close()
  return body
end

if not commit then
  write("Finding latest version... ")
  local body, err = get("https://api.github.com/repos/" .. REPO .. "/commits/master")
  local info = body and textutils.unserialiseJSON(body)
  commit = info and info.sha
  if not commit then
    print("failed")
    printError(tostring(err or "no commit in the GitHub reply"))
    return
  end
  print(commit:sub(1, 7))
end

-- Download everything before touching the disk, so a failed download leaves
-- the current install as it was.
local base = "https://raw.githubusercontent.com/" .. REPO .. "/" .. commit .. "/"
local got = {}
for i, file in ipairs(FILES) do
  write(string.format("[%2d/%d] %s ", i, #FILES, file))
  local body, err = get(base .. file)
  if not body then
    print("failed")
    printError(tostring(err))
    printError("Nothing was changed.")
    return
  end
  got[file] = body
  print("ok")
end

local function backup(path)
  if fs.exists(path) then
    local old = fs.open(path, "rb")
    local text = old.readAll()
    old.close()
    if text ~= got[path:sub(2)] then
      if fs.exists(path .. ".bak") then fs.delete(path .. ".bak") end
      fs.copy(path, path .. ".bak")
      print("Kept the old " .. path:sub(2) .. " as " .. path:sub(2) .. ".bak")
    end
  end
end
backup("/startup.lua")
backup("/ap3/config.lua")

for _, file in ipairs(FILES) do
  local path = "/" .. file
  fs.makeDir(fs.getDir(path))
  local h = fs.open(path, "wb")
  h.write(got[file])
  h.close()
end
local v = fs.open("/ap3/VERSION", "w")
v.write(commit .. "\n")
v.close()

print("Autopilot 3.0 " .. commit:sub(1, 7) .. " installed.")
print("Peripheral names are in ap3/config.lua.")
print("Rebooting in 3 seconds...")
sleep(3)
os.reboot()
