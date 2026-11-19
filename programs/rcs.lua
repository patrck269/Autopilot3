local program = shell.getRunningProgram()
local dir = fs.getDir(program)
package.path = fs.combine(dir, "src") .. "/?.lua;" .. package.path

local config = require("config")
local path = config.default().rcs_disable_file
local disabled
if fs.exists(path) then
  fs.delete(path)
  disabled = false
else
  local handle = assert(fs.open(path, "w"), "cannot write " .. path)
  handle.write("disabled\n")
  handle.close()
  disabled = true
end
os.queueEvent("autopilot_rcs_changed")
print(disabled and "RCS thrusters disabled" or "RCS thrusters enabled")
