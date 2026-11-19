local program = shell.getRunningProgram()
local dir = fs.getDir(program)
package.path = fs.combine(dir, "src") .. "/?.lua;" .. package.path

local app = require("app")
local config = require("config")

if ship == nil then
  error("cc_vs ship API missing: computer-9 must be on the ship", 0)
end

local cfg = config.default()
local a = app.new(app.cc_env(), cfg)
a:start()
parallel.waitForAny(
  function()
    while true do
      a:control_tick()
      sleep(cfg.tick)
    end
  end,
  function()
    while true do
      a:handle_event(os.pullEvent())
    end
  end)
