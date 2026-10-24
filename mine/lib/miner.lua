-- Trip executor.
--
-- The plan is the durable route. Each trip:
--   1. re-zero at the dock,
--   2. replay the plan (already-mined tunnels) to the frontier,
--   3. mine up to MAX_TRIP_BLOCKS, with bounded ore detours,
--   4. pop the trip tape all the way home,
--   5. unload and refuel.
--
-- A reboot mid-trip is recovered by replaying the journal and retracing the
-- tape; the plan progress is the last checkpointed block.
local util = require("lib.util")
local pose = require("lib.pose")
local tape = require("lib.tape")
local plan = require("lib.plan")
local state = require("lib.state")
local hal = require("lib.hal")
local nav = require("lib.nav")
local dock = require("lib.dock")

local M = {}

local HARD = { maxRadius = 128, maxDepth = 200 }
local SAVE_EVERY = 8

local function send(bus, msg)
  if bus and bus.send then bus.send(msg) end
end

local function progressMsg(bus, mission, snap, trip, stateName)
  if bus then
    bus.pose = trip and trip.pose or snap.pose
    bus.progress = snap.progress
    bus.stats = snap.stats
    bus.state = stateName or "mining"
  end
  send(bus, {
    type = "progress",
    missionId = mission.id,
    progress = snap.progress,
    pose = trip and trip.pose or snap.pose,
    fuel = hal.fuel(),
    inventory = hal.inventory(),
    state = stateName or "mining",
    stats = snap.stats,
  })
end

local function oreEvent(bus, p, name)
  send(bus, {
    type = "event",
    kind = "ore",
    data = { x = p.x, y = p.y, z = p.z, name = name },
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

local function inspectDir(trip, dir)
  if dir == "up" then return hal.inspectUp() end
  if dir == "down" then return hal.inspectDown() end
  if dir == trip.pose.f then return hal.inspect() end
  local original = trip.pose.f
  local ok = nav.face(trip, dir)
  if not ok then return nil end
  local data = hal.inspect()
  nav.face(trip, original)
  return data
end

local function targetPose(trip, dir)
  if dir == "up" then return trip.pose.x, trip.pose.y + 1, trip.pose.z end
  if dir == "down" then return trip.pose.x, trip.pose.y - 1, trip.pose.z end
  local dx, dz = pose.vec(dir)
  return trip.pose.x + dx, trip.pose.y, trip.pose.z + dz
end

local function moveInto(trip, dir)
  if dir == "up" then
    local ok, err = hal.digUp()
    if not ok then return nil, err or "digUp failed" end
    return nav.up(trip, 1)
  elseif dir == "down" then
    local ok, err = hal.digDown()
    if not ok then return nil, err or "digDown failed" end
    return nav.down(trip, 1)
  else
    local ok, err = nav.face(trip, dir)
    if not ok then return nil, err end
    ok, err = hal.dig()
    if not ok then return nil, err or "dig failed" end
    return nav.step(trip, "forward")
  end
end

-- Depth-first, bounded vein mining. Every recursive call returns to its entry
-- cell, so the main trip tape is left untouched (and then truncated to base).
local function veinMine(trip, dir, ctx, spec, stats, bus)
  if bus.abort or bus.returnHome then return nil, "stopped" end
  if ctx.count >= spec.maxVeinBlocks then return true end

  local x, y, z = targetPose(trip, dir)
  local key = ("%d,%d,%d"):format(x, y, z)
  if ctx.visited[key] then return true end

  local data = inspectDir(trip, dir)
  if not hal.ore(data) then return true end
  if nav.shouldEnd(trip, 8) then return nil, "fuel reserve" end

  ctx.visited[key] = true
  ctx.count = ctx.count + 1
  local entry = tape.length(trip.tape)

  local ok, err = moveInto(trip, dir)
  if not ok then
    if err == "fuel reserve" then return nil, err end
    local rok, rerr = nav.retraceTo(trip, entry)
    if not rok then return nil, rerr end
    return true
  end

  stats.ores = stats.ores + 1
  oreEvent(bus, trip.pose, data.name)

  local dirs = { 0, 1, 2, 3, "up", "down" }
  for i = 1, #dirs do
    local sok, serr = veinMine(trip, dirs[i], ctx, spec, stats, bus)
    if not sok then return nil, serr end
    local rok, rerr = nav.retraceTo(trip, entry)
    if not rok then return nil, rerr end
  end
  return true
end

local function scanVeins(trip, spec, stats, bus)
  if spec.maxVeinBlocks <= 0 then return true end
  local base = tape.length(trip.tape)
  local ctx = { visited = {}, count = 0 }
  local dirs = { 0, 1, 2, 3, "up", "down" }
  for i = 1, #dirs do
    local ok, err = veinMine(trip, dirs[i], ctx, spec, stats, bus)
    if not ok then return nil, err end
    local rok, rerr = nav.retraceTo(trip, base)
    if not rok then return nil, rerr end
  end
  return true
end

local function moveOne(trip, mining, bus, stats)
  local data = hal.inspect()
  if hal.hazard(data) then return nil, "lava ahead" end
  local wasOre = mining and hal.ore(data)
  local oreName = wasOre and data.name or nil
  if not hal.passable(data) then
    local ok, err = hal.dig()
    if not ok then return nil, "dig failed: " .. tostring(err) end
  end
  local ok, err = nav.step(trip, "forward")
  if not ok then return nil, err end
  if wasOre then
    stats.ores = stats.ores + 1
    oreEvent(bus, trip.pose, oreName)
  end
  return true
end

local function moveDownOne(trip, mining, bus, stats)
  local data = hal.inspectDown()
  if hal.hazard(data) then return nil, "lava below" end
  local wasOre = mining and hal.ore(data)
  local oreName = wasOre and data.name or nil
  if not hal.passable(data) then
    local ok, err = hal.digDown()
    if not ok then return nil, "digDown failed: " .. tostring(err) end
  end
  local ok, err = nav.down(trip, 1)
  if not ok then return nil, err end
  if wasOre then
    stats.ores = stats.ores + 1
    oreEvent(bus, trip.pose, oreName)
  end
  return true
end

local function executeLeg(trip, leg, count, mining, bus, stats)
  if count <= 0 then return true end
  if leg.kind == "down" then
    for _ = 1, count do
      if bus.abort or bus.returnHome then return nil, "stopped" end
      local ok, err = moveDownOne(trip, mining, bus, stats)
      if not ok then return nil, err end
    end
  else
    local ok, err = nav.face(trip, leg.dir)
    if not ok then return nil, err end
    for _ = 1, count do
      if bus.abort or bus.returnHome then return nil, "stopped" end
      ok, err = moveOne(trip, mining, bus, stats)
      if not ok then return nil, err end
    end
  end
  return true
end

local function travelTo(trip, legs, progress, bus)
  local dummy = { ores = 0 }
  for i = 1, progress.leg - 1 do
    local leg = legs[i]
    local ok, err = executeLeg(trip, leg, leg.length, false, bus, dummy)
    if not ok then return nil, err end
  end
  if progress.leg <= #legs then
    local leg = legs[progress.leg]
    local ok, err = executeLeg(trip, leg, progress.offset, false, bus, dummy)
    if not ok then return nil, err end
  end
  return true
end

local function mine(trip, legs, progress, snap, mission, budget, bus)
  local spec = mission.spec
  local mined = 0
  local sinceSave = 0

  while mined < budget do
    if bus.abort or bus.returnHome then break end
    if nav.shouldEnd(trip, 4) then break end
    if mined % 4 == 0 and hal.usedSlots() >= 15 then break end
    if plan.normalize(legs, progress) then break end

    local leg = legs[progress.leg]
    local ok, err
    if leg.kind == "down" then
      ok, err = moveDownOne(trip, true, bus, snap.stats)
    else
      ok, err = nav.face(trip, leg.dir)
      if ok then ok, err = moveOne(trip, true, bus, snap.stats) end
    end
    if not ok then return nil, err end

    progress.offset = progress.offset + 1
    mined = mined + 1
    snap.stats.blocks = snap.stats.blocks + 1
    bus.progress = progress
    bus.pose = trip.pose
    bus.stats = snap.stats

    local sok, serr = scanVeins(trip, spec, snap.stats, bus)
    if not sok then return nil, serr end

    sinceSave = sinceSave + 1
    if sinceSave >= SAVE_EVERY then
      save(snap, mission, trip, true)
      progressMsg(bus, mission, snap, trip, "mining")
      sinceSave = 0
    end
  end

  return mined
end

local function returnHome(trip, snap, mission, bus)
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

  local keep = hal.findFuelSlot() or 16
  hal.unload(keep)
  -- Pull a stack of fuel from the chest above the dock, then refuel.
  for _ = 1, 16 do
    if not hal.suckUp() then break end
  end
  hal.refuelFromInventory()
  return true
end

local function recover(snap, mission, bus)
  if not snap.tripActive then return true end

  if tape.length(snap.tape) > 0 then
    util.log("miner: recovering interrupted trip,", tape.length(snap.tape), "ops")
    local trip = nav.new(hal, snap.tape, mission.spec.reserve, snap.pose)
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
  local valid, verr = plan.validate(spec, HARD)
  if not valid then return nil, "invalid mission spec: " .. tostring(verr) end
  spec.maxTripBlocks = math.min(spec.maxTripBlocks, 2000)
  spec.maxVeinBlocks = math.min(spec.maxVeinBlocks, 64)
  spec.reserve = math.max(spec.reserve, 16)

  local legs = plan.build(spec)
  if #legs == 0 then return nil, "empty plan" end

  local snap = state.load(hal.fuel)
  if not snap then
    snap = {
      progress = plan.copyProgress(mission.progress or { leg = 1, offset = 0, layer = 0, strip = 0 }),
      stats = { blocks = 0, ores = 0, trips = 0 },
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
      util.log("miner: boot recovery was uncertain; attempting tape retrace")
    end
  else
    snap.mission = { id = mission.id, spec = spec }
    snap.progress = plan.copyProgress(mission.progress or { leg = 1, offset = 0, layer = 0, strip = 0 })
    snap.stats = { blocks = 0, ores = 0, trips = 0 }
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

  local rok, rerr = recover(snap, mission, bus)
  if not rok then return nil, rerr end

  if bus then
    bus.pose = snap.pose
    bus.progress = snap.progress
    bus.stats = snap.stats
  end
  if plan.normalize(legs, snap.progress) then return "done" end
  progressMsg(bus, mission, snap, nil, "idle")

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

    local base, derr = dock.zero(hal, spec.base)
    if not base then return nil, "dock zero failed: " .. tostring(derr) end

    local trip = nav.new(hal, tape.new(), spec.reserve, base)
    snap.tripActive = true
    snap.pose = base
    snap.tape = trip.tape
    save(snap, mission, trip, true)

    local tok, terr = travelTo(trip, legs, snap.progress, bus)
    if not tok then
      local home, herr = returnHome(trip, snap, mission, bus)
      if not home then
        return nil, "travel failed: " .. tostring(terr) .. "; return failed: " .. tostring(herr)
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
      return nil, "travel failed: " .. tostring(terr)
    end

    local mined, merr = mine(trip, legs, snap.progress, snap, mission, spec.maxTripBlocks, bus)
    if not mined then
      local home, herr = returnHome(trip, snap, mission, bus)
      if not home then
        return nil, "mine failed: " .. tostring(merr) .. "; return failed: " .. tostring(herr)
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
      return nil, "mine failed: " .. tostring(merr)
    end

    local home, herr = returnHome(trip, snap, mission, bus)
    if not home then return nil, "return failed: " .. tostring(herr) end

    snap.stats.trips = snap.stats.trips + 1
    save(snap, mission, trip, false)
    progressMsg(bus, mission, snap, trip, "idle")

    if plan.normalize(legs, snap.progress) then return "done" end
    if mined == 0 then return nil, "no progress this trip (fuel or inventory)" end
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
