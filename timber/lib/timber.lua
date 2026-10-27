-- Timber executor.
--
-- The timber turtle sits at a fixed position relative to a tree farm.
-- It waits for wood to appear (detected via inspect), then:
--   1. Moves to collect the wood (following a pattern)
--   2. Returns to starting position
--   3. Turns right to face the chest
--   4. Deposits wood into chest
--   5. Turns left to face back to tree
--   6. Plants a sapling at the tree position
--   7. Returns to wait position
--
-- A reboot mid-cycle is recovered by replaying the journal and retracing the
-- tape; the mission progress is the last checkpointed state.

local util = require("lib.util")
local pose = require("lib.pose")
local tape = require("lib.tape")
local state = require("lib.state")
local hal = require("lib.hal")
local nav = require("lib.nav")
local dock = require("lib.dock")
local gps = require("lib.gps")

local M = {}

local SAVE_EVERY = 4

local function send(bus, msg)
  if bus and bus.send then bus.send(msg) end
end

local function progressMsg(bus, mission, snap, trip, stateName)
  if bus then
    bus.pose = trip and trip.pose or snap.pose
    bus.progress = snap.progress
    bus.stats = snap.stats
    bus.state = stateName or "timber"
  end
  send(bus, {
    type = "progress",
    missionId = mission.id,
    progress = snap.progress,
    pose = trip and trip.pose or snap.pose,
    fuel = hal.fuel(),
    inventory = hal.inventory(),
    state = stateName or "timber",
    stats = snap.stats,
  })
end

local function save(snap, mission, trip, active)
  snap.mission = { id = mission.id, spec = mission.spec }
  snap.tripActive = active and true or false
  if trip then
    snap.pose = trip.pose
    snap.tape = trip.tape
  end
  return state.save(snap)
end

-- Check if there's a log/wood block in front
local function checkWood()
  local has_block, data = hal.inspect()
  if has_block and data then
    local name = data.name or ""
    -- Check for various wood/log types
    return name:find("log", 1, true) ~= nil
      or name:find("wood", 1, true) ~= nil
      or name:find("bamboo", 1, true) ~= nil
  end
  return false
end

-- Check if block in front is a sapling (for planting verification)
local function isSapling(data)
  if not data then return false end
  local name = data.name or ""
  return name:find("sapling", 1, true) ~= nil
end

-- Find a sapling in inventory
local function findSaplingSlot()
  for slot = 1, 16 do
    local item = hal.itemDetail(slot)
    if item and isSapling(item) then
      return slot
    end
  end
  return nil
end

-- Move to tree position and collect wood (the "move and suck" pattern)
local function collectWood(trip, bus, stats)
  util.log("timber: collecting wood")
  
  -- Forward 1 (to tree trunk position)
  local ok, err = nav.step(trip, "forward")
  if not ok then return nil, err end
  
  -- Suck wood from trunk
  hal.suck()
  
  -- Forward 1 more
  ok, err = nav.step(trip, "forward")
  if not ok then return nil, err end
  hal.suck()
  
  -- Turn left, forward, suck, back, turn right
  ok, err = nav.turn(trip, "turnLeft")
  if not ok then return nil, err end
  ok, err = nav.step(trip, "forward")
  if not ok then return nil, err end
  hal.suck()
  ok, err = nav.step(trip, "back")
  if not ok then return nil, err end
  ok, err = nav.turn(trip, "turnRight")
  if not ok then return nil, err end
  
  -- Back, suck
  ok, err = nav.step(trip, "back")
  if not ok then return nil, err end
  hal.suck()
  
  -- Turn left, forward, suck, back, turn right
  ok, err = nav.turn(trip, "turnLeft")
  if not ok then return nil, err end
  ok, err = nav.step(trip, "forward")
  if not ok then return nil, err end
  hal.suck()
  ok, err = nav.step(trip, "back")
  if not ok then return nil, err end
  ok, err = nav.turn(trip, "turnRight")
  if not ok then return nil, err end
  
  -- Back to starting position
  ok, err = nav.step(trip, "back")
  if not ok then return nil, err end
  
  stats.collected = stats.collected + 1
  return true
end

-- Turn right, deposit wood into chest (facing down/chest)
local function depositWood(trip, bus, stats)
  util.log("timber: depositing wood")
  
  -- Turn right to face chest
  local ok, err = nav.turn(trip, "turnRight")
  if not ok then return nil, err end
  
  -- Deposit all non-sapling, non-fuel items
  local keepSlot = hal.findFuelSlot() or 16
  local saplingSlot = findSaplingSlot()
  
  local previous = hal.selectedSlot()
  for slot = 1, 16 do
    if slot ~= keepSlot and slot ~= saplingSlot then
      if hal.select(slot) and hal.itemDetail(slot) then
        hal.dropDown()
      end
    end
  end
  pcall(hal.select, previous)
  
  stats.deposited = stats.deposited + 1
  return true
end

-- Turn left to face back to tree
local function faceTree(trip)
  util.log("timber: facing tree")
  return nav.turn(trip, "turnLeft")
end

-- Plant sapling at tree position
local function plantSapling(trip, bus, stats)
  util.log("timber: planting sapling")
  
  local saplingSlot = findSaplingSlot()
  if not saplingSlot then
    util.log("timber: no sapling in inventory!")
    return nil, "no sapling"
  end
  
  -- Move forward to tree position (1 block forward from wait position)
  local ok, err = nav.step(trip, "forward")
  if not ok then return nil, err end
  
  -- Place sapling down
  local previous = hal.selectedSlot()
  if hal.select(saplingSlot) then
    hal.digDown() -- Clear any existing block
    local placed, perr = hal.move("placeDown")
    if not placed then
      pcall(hal.select, previous)
      return nil, "placeDown failed: " .. tostring(perr)
    end
    stats.planted = stats.planted + 1
  end
  pcall(hal.select, previous)
  
  -- Move back to wait position
  ok, err = nav.step(trip, "back")
  if not ok then return nil, err end
  
  return true
end

-- Return home to dock (re-zero)
local function returnHome(trip, snap, mission, bus)
  util.log("timber: returning home")
  
  local ok, err = nav.retraceAll(trip)
  if not ok then return nil, err end

  local base, derr = dock.zero(hal, mission.spec.base)
  if not base then return nil, "dock zero failed: " .. tostring(derr) end

  trip.pose = base
  snap.tripActive = false
  snap.pose = base
  snap.tape = tape.new()
  save(snap, mission, trip, false)
  if bus then bus.pose = base; bus.stats = snap.stats end

  -- Refuel from chest above dock
  for _ = 1, 16 do
    if not hal.suckUp() then break end
  end
  hal.refuelFromInventory()
  return true
end

-- Recover from interrupted trip
local function recover(snap, mission, bus, useGps)
  if not snap.tripActive then return true end

  if tape.length(snap.tape) > 0 then
    util.log("timber: recovering interrupted trip,", tape.length(snap.tape), "ops")
    local trip = nav.new(hal, snap.tape, mission.spec.reserve, snap.pose, useGps)
    local ok, err = nav.retraceAll(trip)
    if not ok then
      send(bus, { type = "event", kind = "recovery_failed", data = { error = err } })
      return nil, "recovery failed: " .. tostring(err)
    end
    local base, derr = dock.zero(hal, mission.spec.base)
    if not base then return nil, "dock zero failed after recovery: " .. tostring(derr) end
    snap.pose = base
  else
    local base, derr = dock.zero(hal, mission.spec.base)
    if not base then return nil, "dock zero failed: " .. tostring(derr) end
    snap.pose = base
  end

  snap.tripActive = false
  snap.tape = tape.new()
  if bus then
    bus.pose = snap.pose
    bus.progress = snap.progress
    bus.stats = snap.stats
  end
  save(snap, mission, nil, false)
  return true
end

--- @return "done"|"paused"|nil, error
function M.run(mission, bus)
  local spec = mission.spec
  spec.reserve = math.max(spec.reserve or 16, 16)
  spec.maxCycles = spec.maxCycles or 0  -- 0 = infinite

  -- Check GPS availability at startup
  local useGps = gps.available(1)
  if useGps then
    util.log("timber: GPS available, using absolute positioning")
    -- Try to sync initial pose from GPS
    local initPose = pose.copy(spec.base)
    local ok, err = gps.syncPose(initPose, hal, true)
    if ok then
      util.log(("timber: GPS position: x=%d y=%d z=%d f=%d"):format(initPose.x, initPose.y, initPose.z, initPose.f))
      spec.base = initPose
    else
      util.log("timber: GPS sync failed (" .. tostring(err) .. "), using spec base")
    end
  else
    util.log("timber: GPS unavailable, using dead reckoning with dock zeroing")
  end

  local snap = state.load(hal.fuel)
  if not snap then
    snap = {
      progress = { cycles = 0 },
      stats = { blocks = 0, ores = 0, trips = 0, collected = 0, deposited = 0, planted = 0 },
      tripActive = false,
      pose = pose.copy(spec.base),
      tape = tape.new(),
      seq = 0,
    }
    state.resetJournal()
    save(snap, mission, nil, false)
  elseif snap.mission and snap.mission.id == mission.id then
    mission.progress = snap.progress
    if snap.uncertain then
      util.log("timber: boot recovery was uncertain; attempting tape retrace")
    end
  else
    snap.mission = { id = mission.id, spec = spec }
    snap.progress = { cycles = 0 }
    snap.stats = { blocks = 0, ores = 0, trips = 0, collected = 0, deposited = 0, planted = 0 }
    snap.tripActive = false
    snap.pose = pose.copy(spec.base)
    snap.tape = tape.new()
    state.resetJournal()
    save(snap, mission, nil, false)
  end

  -- A start command is the operator's explicit resume, so clear the local
  -- pause/halt flags before doing any work.
  snap.paused = false
  snap.halted = false
  save(snap, mission, nil, snap.tripActive and true or false)

  local rok, rerr = recover(snap, mission, bus, useGps)
  if not rok then return nil, rerr end

  if bus then
    bus.pose = snap.pose
    bus.progress = snap.progress
    bus.stats = snap.stats
  end
  progressMsg(bus, mission, snap, nil, "idle")

  local cycles = 0
  while true do
    if bus.abort then
      snap.halted = true
      save(snap, mission, nil, false)
      return nil, "aborted"
    end
    if bus.returnHome then
      snap.paused = true
      save(snap, mission, nil, false)
      return "paused"
    end

    -- Check fuel
    local fuel = hal.fuel()
    if fuel ~= "unlimited" and type(fuel) == "number" and fuel < spec.reserve then
      util.log("timber: low fuel (", fuel, "), returning home to refuel")
      local base, derr = dock.zero(hal, spec.base)
      if not base then return nil, "dock zero failed: " .. tostring(derr) end
      for _ = 1, 16 do if not hal.suckUp() then break end end
      hal.refuelFromInventory()
    end

    -- Re-zero at dock at start of each cycle
    local base, derr = dock.zero(hal, spec.base)
    if not base then return nil, "dock zero failed: " .. tostring(derr) end

    -- Log position after dock zero (which uses GPS if available)
    util.log(("timber: dock zero at x=%d y=%d z=%d f=%d"):format(base.x, base.y, base.z, base.f))

    local trip = nav.new(hal, tape.new(), spec.reserve, base, useGps)
    snap.tripActive = true
    snap.pose = base
    snap.tape = trip.tape
    save(snap, mission, trip, true)

    -- Wait for wood to appear
    util.log("timber: waiting for wood...")
    local woodDetected = false
    while not woodDetected do
      if bus.abort then
        snap.halted = true
        save(snap, mission, nil, false)
        return nil, "aborted"
      end
      if bus.returnHome then
        snap.paused = true
        save(snap, mission, nil, false)
        return "paused"
      end
      
      woodDetected = checkWood()
      if not woodDetected then
        os.sleep(1)
      end
      
      -- Periodic fuel check while waiting
      fuel = hal.fuel()
      if fuel ~= "unlimited" and type(fuel) == "number" and fuel < spec.reserve then
        util.log("timber: low fuel while waiting (", fuel, ")")
        local b, e = dock.zero(hal, spec.base)
        if b then
          for _ = 1, 16 do if not hal.suckUp() then break end end
          hal.refuelFromInventory()
        end
      end
    end

    util.log("timber: wood detected, collecting...")

    -- Collect wood
    local ok, err = collectWood(trip, bus, snap.stats)
    if not ok then
      local home, herr = returnHome(trip, snap, mission, bus)
      if not home then
        return nil, "collect failed: " .. tostring(err) .. "; return failed: " .. tostring(herr)
      end
      if bus.abort then
        snap.halted = true
        save(snap, mission, nil, false)
        return nil, "aborted"
      end
      if bus.returnHome then
        snap.paused = true
        save(snap, mission, nil, false)
        return "paused"
      end
      return nil, "collect failed: " .. tostring(err)
    end

    -- Deposit wood (turn right, drop down)
    ok, err = depositWood(trip, bus, snap.stats)
    if not ok then
      local home, herr = returnHome(trip, snap, mission, bus)
      if not home then
        return nil, "deposit failed: " .. tostring(err) .. "; return failed: " .. tostring(herr)
      end
      return nil, "deposit failed: " .. tostring(err)
    end

    -- Face tree (turn left)
    ok, err = faceTree(trip)
    if not ok then
      local home, herr = returnHome(trip, snap, mission, bus)
      if not home then
        return nil, "face tree failed: " .. tostring(err) .. "; return failed: " .. tostring(herr)
      end
      return nil, "face tree failed: " .. tostring(err)
    end

    -- Plant sapling
    ok, err = plantSapling(trip, bus, snap.stats)
    if not ok then
      local home, herr = returnHome(trip, snap, mission, bus)
      if not home then
        return nil, "plant failed: " .. tostring(err) .. "; return failed: " .. tostring(herr)
      end
      return nil, "plant failed: " .. tostring(err)
    end

    -- Return to wait position (already there after plantSapling moves back)
    -- Now return home to dock
    ok, err = returnHome(trip, snap, mission, bus)
    if not ok then return nil, err end

    snap.stats.trips = snap.stats.trips + 1
    snap.progress.cycles = snap.progress.cycles + 1
    cycles = cycles + 1
    save(snap, mission, trip, false)
    progressMsg(bus, mission, snap, trip, "idle")

    if spec.maxCycles > 0 and cycles >= spec.maxCycles then
      return "done"
    end

    if bus.abort then
      snap.halted = true
      save(snap, mission, nil, false)
      return nil, "aborted"
    end
    if bus.returnHome then
      snap.paused = true
      save(snap, mission, nil, false)
      return "paused"
    end
  end
end

return M