-- Mission supervisor. Runs offline; the link can come and go.
-- Dispatches to the role-specific module based on bus.role.
local util = require("lib.util")
local state = require("lib.state")
local hal = require("lib.hal")
local miner = require("lib.miner")
local station_builder = require("lib.station_builder")
local hauler = require("lib.hauler")

local M = {}

function M.run(identity, bus)
  local role = bus.role or "unassigned"
  util.log("supervisor: role is", role)

  -- For miner roles, load any existing mission state.
  if role == "miner" then
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
    -- Re-read role each loop so an assignRole command from the console can
    -- switch runtimes without rebooting.
    role = bus.role or "unassigned"

    if role == "unassigned" then
      -- Wait for the console to assign a role via the assignRole command.
      bus.state = "unassigned"
      os.sleep(0.25)

    elseif role == "station_builder" then
      bus.state = "building"
      local result, err = station_builder.run(identity, bus)
      util.log("supervisor: station_builder", result or "stopped", err or "")
      if result == "transition_to_hauler" then
        -- Builder finished the station; switch to hauler runtime.
        bus.role = "hauler"
        bus.state = "hauling"
        util.log("supervisor: transitioning station_builder -> hauler")
      end

    elseif role == "hauler" then
      bus.state = "hauling"
      local result, err = hauler.run(identity, bus)
      util.log("supervisor: hauler", result or "stopped", err or "")

    elseif role == "miner" then
      local mission = bus.mission
      if mission then
        local commandId = bus.commandId
        bus.running = mission.id
        bus.state = "mining"
        util.log("supervisor: mission", mission.id)
        local result, err = miner.run(mission, bus)

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
          bus.blocked = false
          bus.state = "queued"
        end
      else
        os.sleep(0.25)
      end

    else
      bus.state = "unknown_role"
      os.sleep(0.25)
    end
  end
end

return M