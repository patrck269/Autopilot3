-- Autopilot 3.0 entry point. Runs at boot: the flight loop and the command
-- center (MFDs and terminal) side by side on this computer.
package.path = "/?.lua;/?/init.lua;" .. package.path
local cfg = require("ap3.config")
local link = require("ap3.link").new()
parallel.waitForAny(
  function() require("ap3.flight").run(cfg, { link = link }) end,
  function() require("ap3.command").run(cfg, { link = link }) end
)
