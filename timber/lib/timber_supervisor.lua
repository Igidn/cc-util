-- Timber mission supervisor. Runs offline; the link can come and go.
local util = require("lib.util")
local state = require("lib.state")
local hal = require("lib.hal")
local timber = require("lib.timber")
local nav = require("lib.nav")
local pose = require("lib.pose")

local M = {}

function M.run(identity, bus)
  local snap = state.load(hal.fuel)
  if snap and snap.mission then
    bus.pose = snap.pose
    bus.progress = snap.progress
    bus.stats = snap.stats
    if snap.paused or snap.halted then
      bus.blocked = true
      bus.mission = nil
      bus.state = snap.paused and "paused" or "halted"
      util.log("supervisor: local mission is", snap.paused and "paused" or "halted", "; waiting for start")
    else
      bus.mission = {
        id = snap.mission.id,
        spec = snap.mission.spec,
        progress = snap.progress,
      }
      util.log("supervisor: resuming mission", snap.mission.id)
    end
  end

  bus.status = function()
    return {
      pose = bus.pose,
      fuel = hal.fuel(),
      inventory = hal.inventory(),
      state = bus.state or "idle",
      missionId = bus.running or (bus.mission and bus.mission.id) or nil,
      progress = bus.progress,
    }
  end

  while true do
    local mission = bus.mission
    if mission then
      local commandId = bus.commandId
      bus.running = mission.id
      bus.state = "timber"
      util.log("supervisor: mission", mission.id)
      local result, err = timber.run(mission, bus)

      local status = "failed"
      if result == "done" then
        status = "done"
      elseif result == "paused" then
        status = "paused"
      end

      if bus.send then
        bus.send({
          type = "result",
          id = commandId,
          missionId = mission.id,
          status = status,
          error = err,
          stats = bus.stats,
          progress = bus.progress,
        })
      end
      util.log("supervisor: mission", status, err or "")

      bus.running = nil
      if bus.mission == mission then
        bus.mission = nil
        bus.commandId = nil
        bus.abort = false
        bus.returnHome = false
        if status == "paused" then
          bus.blocked = true
          bus.state = "paused"
        elseif status == "done" then
          bus.blocked = false
          bus.state = "idle"
        else
          bus.blocked = true
          bus.state = "halted"
        end
      else
        -- A start command arrived while the previous mission was winding
        -- down. Keep it queued instead of dropping it.
        bus.blocked = false
        bus.state = "queued"
      end
    else
      os.sleep(0.25)
    end
  end
end

return M