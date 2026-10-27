-- cc-util turtle runtime entry point.
package.path = "/ccutil/?.lua;/ccutil/?/init.lua;" .. package.path

local util = require("lib.util")
local identity = require("lib.identity")

local id = identity.load()
if not id then
  print("cc-util is not installed on this computer.")
  print("Run install.lua, or wget the installer from the tunnel-latest release.")
  return
end

util.log("cc-util", util.VERSION, "turtle", id.id, "role", id.role or "unassigned")

while true do
  local bus = { connected = false, outbox = {}, role = id.role or "unassigned", serverUrl = id.serverUrl, turtleId = id.id }
  local ok, err = pcall(function()
    parallel.waitForAll(
      function() require("lib.link").run(id, bus) end,
      function() require("lib.supervisor").run(id, bus) end
    )
  end)
  util.log("runtime stopped:", err or "no error")
  os.sleep(5)
end
