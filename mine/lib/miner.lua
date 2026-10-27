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
local gps = require("lib.gps")
local shaft = require("lib.shaft")

local M = {}

local HARD = { maxRadius = 128, maxDepth = 200 }
local SAVE_EVERY = 8

local function send(bus, msg)
  if bus and bus.send then bus.send(msg) end
end

-- Fetch chest positions for a station from the console.
-- Returns array of chest tables, or nil on failure.
local function getStationChests(tunnel, stationId)
  local response, err = http.get(tunnel .. "/api/chests?stationId=" .. stationId, {
    ["User-Agent"] = "cc-util/0.1.0",
  })
  if not response then return nil end
  local code = response.getResponseCode()
  local text = response.readAll()
  response.close()
  if code ~= 200 then return nil end
  local data = util.jsonDecode(text)
  if not data or type(data.chests) ~= "table" then return nil end
  return data.chests
end

-- Find the nearest storage chest to the current pose.
local function findNearestStorageChest(navInstance, chests)
  local best, bestDist = nil, math.huge
  for _, chest in ipairs(chests) do
    if chest.kind == "storage" and chest.pose then
      local dx = chest.pose.x - navInstance.pose.x
      local dy = chest.pose.y - navInstance.pose.y
      local dz = chest.pose.z - navInstance.pose.z
      local dist = dx * dx + dy * dy + dz * dz
      if dist < bestDist then
        bestDist = dist
        best = chest
      end
    end
  end
  return best
end

-- Find the refueling chest.
local function findRefuelChest(chests)
  for _, chest in ipairs(chests) do
    if chest.kind == "refuel" and chest.pose then return chest end
  end
  return nil
end

-- Navigate to a target position using Manhattan moves. Updates the tape.
local function navigateTo(navInstance, targetX, targetY, targetZ)
  local dy = targetY - navInstance.pose.y
  if dy > 0 then
    for _ = 1, dy do
      local ok, err = nav.up(navInstance, 1)
      if not ok then return nil, "up failed: " .. tostring(err) end
    end
  elseif dy < 0 then
    for _ = 1, -dy do
      local ok, err = nav.down(navInstance, 1)
      if not ok then return nil, "down failed: " .. tostring(err) end
    end
  end
  local dx = targetX - navInstance.pose.x
  if dx > 0 then
    nav.face(navInstance, 1)
    for _ = 1, dx do
      local ok, err = nav.step(navInstance, "forward")
      if not ok then return nil, "east failed: " .. tostring(err) end
    end
  elseif dx < 0 then
    nav.face(navInstance, 3)
    for _ = 1, -dx do
      local ok, err = nav.step(navInstance, "forward")
      if not ok then return nil, "west failed: " .. tostring(err) end
    end
  end
  local dz = targetZ - navInstance.pose.z
  if dz > 0 then
    nav.face(navInstance, 2)
    for _ = 1, dz do
      local ok, err = nav.step(navInstance, "forward")
      if not ok then return nil, "south failed: " .. tostring(err) end
    end
  elseif dz < 0 then
    nav.face(navInstance, 0)
    for _ = 1, -dz do
      local ok, err = nav.step(navInstance, "forward")
      if not ok then return nil, "north failed: " .. tostring(err) end
    end
  end
  return true
end

-- Drop every inventory slot into the chest directly below the turtle.
local function depositItemsDown()
  local dropped = 0
  for slot = 1, 16 do
    local item = hal.itemDetail(slot)
    if item then
      hal.select(slot)
      if hal.dropDown() then dropped = dropped + 1 end
    end
  end
  return dropped
end

-- Suck lava buckets from the chest directly above the turtle, then refuel.
local function refuelFromAbove()
  for _ = 1, 16 do
    if not hal.suckUp() then break end
  end
  return hal.refuelFromInventory()
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
  local shaftTapeLen
  for i = 1, progress.leg - 1 do
    local leg = legs[i]
    local ok, err = executeLeg(trip, leg, leg.length, false, bus, dummy)
    if not ok then return nil, err end
    if i == 2 then shaftTapeLen = tape.length(trip.tape) end
  end
  if progress.leg <= #legs then
    local leg = legs[progress.leg]
    local ok, err = executeLeg(trip, leg, progress.offset, false, bus, dummy)
    if not ok then return nil, err end
    if progress.leg == 2 then shaftTapeLen = tape.length(trip.tape) end
  end
  return true, nil, shaftTapeLen
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

local function recover(snap, mission, bus, useGps)
  if not snap.tripActive then return true end

  if tape.length(snap.tape) > 0 then
    util.log("miner: recovering interrupted trip,", tape.length(snap.tape), "ops")
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
  local valid, verr = plan.validate(spec, HARD)
  if not valid then return nil, "invalid mission spec: " .. tostring(verr) end
  spec.maxTripBlocks = math.min(spec.maxTripBlocks, 2000)
  spec.maxVeinBlocks = math.min(spec.maxVeinBlocks, 64)
  spec.reserve = math.max(spec.reserve, 16)

  -- Station context from the console welcome message.
  local stationId = bus.station and bus.station.id or "s0"
  local tunnel = bus.serverUrl
  local id = bus.turtleId or ""

  -- Fetch chest positions for this station.
  local chests = {}
  if tunnel then
    local fetched = getStationChests(tunnel, stationId)
    if fetched then chests = fetched end
    util.log("miner: loaded", #chests, "chests for station", stationId)
  end

  -- Check GPS availability at startup
  local useGps = gps.available(1)
  if useGps then
    util.log("miner: GPS available, using absolute positioning")
    local initPose = pose.copy(spec.base)
    local ok, err = gps.syncPose(initPose, hal, true)
    if ok then
      util.log(("miner: GPS position: x=%d y=%d z=%d f=%d"):format(initPose.x, initPose.y, initPose.z, initPose.f))
      spec.base = initPose
    else
      util.log("miner: GPS sync failed (" .. tostring(err) .. "), using spec base")
    end
  else
    util.log("miner: GPS unavailable, using dead reckoning with dock zeroing")
  end

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

  local rok, rerr = recover(snap, mission, bus, useGps)
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

    -- Dock zero at the surface dock.
    local base, derr = dock.zero(hal, spec.base)
    if not base then return nil, "dock zero failed: " .. tostring(derr) end
    util.log(("miner: dock zero at x=%d y=%d z=%d f=%d"):format(base.x, base.y, base.z, base.f))

    -- Acquire the shaft lock before descending. Blocks until granted.
    -- Skipped when there is no tunnel (single-turtle / test mode).
    local acquired = true
    if tunnel then
      acquired = shaft.acquire(tunnel, stationId, id, "mining")
    end
    if not acquired then
      util.log("miner: could not acquire shaft lock, aborting trip")
      return nil, "shaft lock unavailable"
    end

    local trip = nav.new(hal, tape.new(), spec.reserve, base, useGps)
    snap.tripActive = true
    snap.pose = base
    snap.tape = trip.tape
    save(snap, mission, trip, true)

    -- Travel to the frontier (replays plan including shaft descent).
    -- travelTo also returns the tape length at shaft bottom (after legs 1-2:
    -- staging + down), which includes turn ops from nav.face(). This is needed
    -- for retraceTo() to return to the exact shaft-bottom position.
    local tok, terr, shaftTapeLen = travelTo(trip, legs, snap.progress, bus)
    if not shaftTapeLen then
      -- Fresh mission: travelTo didn't replay legs 1-2. Compute tape length at
      -- shaft bottom analytically from legs 1-2 (staging + down), including
      -- turn ops from nav.face().
      shaftTapeLen = 0
      if #legs >= 2 then
        local f = base.f
        local leg1 = legs[1]
        if leg1.kind == "line" then
          shaftTapeLen = shaftTapeLen + #pose.turnOps(f, leg1.dir) + leg1.length
          f = leg1.dir
        end
        local leg2 = legs[2]
        if leg2.kind == "down" then
          shaftTapeLen = shaftTapeLen + leg2.length
        end
      end
    end

    if not tok then
      -- Failed underground: return to surface and release lock.
      local homeOK, homeErr = nav.retraceAll(trip)
      if homeOK then
        dock.zero(hal, spec.base)
      end
      if tunnel then shaft.release(tunnel, stationId, id) end
      if not homeOK then
        return nil, "travel failed: " .. tostring(terr) .. "; return failed: " .. tostring(homeErr)
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

    -- Release the shaft lock now that we are at the room level (not in the shaft column).
    if tunnel then shaft.release(tunnel, stationId, id) end

    -- Mine blocks at the frontier.
    local mined, merr = mine(trip, legs, snap.progress, snap, mission, spec.maxTripBlocks, bus)
    if not mined then
      -- Return to shaft bottom, deposit/refuel, then ascend and release lock.
      local retOK, retErr = nav.retraceTo(trip, shaftTapeLen)
      if retOK then
        depositItemsDown()
        refuelFromAbove()
        -- Ascend to surface.
        local upBlocks = -spec.startY
        for _ = 1, upBlocks do nav.up(trip, 1) end
        nav.face(trip, 2)
        nav.step(trip, "forward")
        dock.zero(hal, spec.base)
      end
      if tunnel then shaft.release(tunnel, stationId, id) end
      tape.clear(trip.tape)
      snap.tape = tape.new()
      snap.tripActive = false
      save(snap, mission, nil, false)
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

    -- Return to shaft bottom (retrace all mining moves, keep shaft descent on tape).
    local retOK, retErr = nav.retraceTo(trip, shaftTapeLen)
    if retOK then
      -- Deposit all carried items into the storage chest below.
      local dropped = depositItemsDown()
      if dropped > 0 then
        util.log("miner: deposited", dropped, "item stacks into storage chest at shaft bottom")
      end
      -- Refuel from the refueling chest above.
      local fuelOK, fuelErr = refuelFromAbove()
      if fuelOK then
        util.log("miner: refueled from refuel chest at shaft bottom")
      else
        util.log("miner: refuel from chest failed:", fuelErr or "unknown")
      end
    else
      util.log("miner: retrace to shaft bottom failed:", retErr or "unknown")
    end

    -- Acquire the shaft lock for the ascent.
    local acqOK = true
    if tunnel then
      acqOK = shaft.acquire(tunnel, stationId, id, "ascent")
    end
    if not acqOK then
      util.log("miner: could not re-acquire shaft lock for ascent")
      -- Still try to ascend without lock (best effort).
    end

    -- Ascend to surface: go up from room level, then south back to dock.
    local upBlocks = -spec.startY
    for _ = 1, upBlocks do
      local ok, err = nav.up(trip, 1)
      if not ok then
        util.log("miner: ascent failed at block", _, ":", err or "unknown")
        break
      end
    end
    nav.face(trip, 2)
    nav.step(trip, "forward")
    -- Face north so dock.zero's physical fixture ends with correct facing.
    nav.face(trip, 0)

    -- Release the shaft lock.
    if tunnel then shaft.release(tunnel, stationId, id) end

    -- Re-zero at the surface dock and clear the trip tape.
    dock.zero(hal, spec.base)
    tape.clear(trip.tape)
    snap.tape = tape.new()
    snap.tripActive = false
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
