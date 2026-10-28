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

-- Each miner parks on its own cell between trips so the shared dock stays
-- free for the other miner. One miner per station needs no parking.
local function parkingCell(spec)
  local lane = tonumber(spec.lane) or 0
  local lanes = tonumber(spec.laneCount) or 1
  if lanes < 2 then return nil end
  return spec.base.x, spec.base.y, spec.base.z + 2 + lane * 2
end

-- Walk across the room without digging. Retries so a turtle standing in the
-- way only delays the move instead of failing the mission.
local function walkInRoom(snap, x, y, z, attempts)
  local lastErr
  attempts = attempts or 1
  for attempt = 1, attempts do
    local trip = nav.new(hal, tape.new(), 0, pose.copy(snap.pose), false)
    local ok, err = navigateTo(trip, x, y, z)
    snap.pose = pose.copy(trip.pose)
    if ok then return true end
    lastErr = err
    if attempt < attempts then os.sleep(1) end
  end
  return false, lastErr
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

local function mine(trip, legs, progress, snap, mission, budget, bus, gate)
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
    if gate then gate.maybeRelease(progress) end

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

local function shaftColumn(spec)
  -- The plan's staging leg fixes the direction (north) and length (usually 1)
  -- from the room dock into the shaft column.
  local dx, dz = pose.vec(0)
  local n = spec.staging or 1
  return spec.base.x + dx * n, spec.base.z + dz * n
end

-- The plan legs that belong to the shaft: the staging step into the column
-- and the descent to the first mining level. `outLeg` is the first leg that
-- leaves the shaft (one step of it is enough).
local function shaftPlan(legs)
  local staging = legs[1] and legs[1].length or 0
  local down = 0
  if legs[2] and legs[2].kind == "down" then down = legs[2].length end
  local outLeg = staging > 0 and (2 + (down > 0 and 1 or 0)) or 1
  return staging + down, outLeg
end

-- Shaft lock for one mining trip. The lock is held only while the miner is in
-- the shaft column: it is released as soon as the miner steps into the sector
-- and taken again at the shaft bottom on the way home. That keeps a second
-- miner and the hauler moving while this one mines.
local function newShaftGate(tunnel, stationId, id, legs)
  local tapeLen, outLeg = shaftPlan(legs)
  local gate = { held = false, tapeLen = tapeLen, outLeg = outLeg }

  function gate.acquire()
    if gate.held then return true end
    if tunnel and not shaft.acquire(tunnel, stationId, id, "mining trip") then
      return nil
    end
    gate.held = true
    return true
  end

  function gate.release()
    if not gate.held then return true end
    gate.held = false
    if tunnel then shaft.release(tunnel, stationId, id) end
    return true
  end

  function gate.maybeRelease(progress)
    if not gate.held then return true end
    if progress.leg > gate.outLeg
      or (progress.leg == gate.outLeg and (progress.offset or 0) >= 1) then
      return gate.release()
    end
    return true
  end

  return gate
end

-- Retrace the trip. The shaft lock is taken when the tape reaches the shaft
-- bottom, so the walk back through the sector does not block the station.
local function retraceTrip(trip, gate, bus)
  while true do
    local len = tape.length(trip.tape)
    if len == 0 then break end
    if not gate.held and len <= gate.tapeLen + 1 then
      if not gate.acquire() then return nil, "shaft lock unavailable for ascent" end
      if bus then bus.state = "ascending" end
    end
    local ok, err = nav.retraceOne(trip)
    if not ok then
      if gate.held then gate.release() end
      return nil, err
    end
  end
  if gate.held then gate.release() end
  return true
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
    snap.pose = pose.copy(trip.pose)
  elseif useGps then
    gps.syncPose(snap.pose, hal, false)
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

-- The world Y the miner must return to on ascent. The station's shaft top is
-- authoritative, but a station built from the wrong level can report a shaft
-- that is only a couple of blocks tall; in that case trust where the miner
-- actually started its descent.
local function stationSurfaceY(bus, dockY, fallbackY)
  local reported = bus.station and bus.station.shaftPose and bus.station.shaftPose.y
  if type(reported) == "number" and reported > dockY + 1 then return reported end
  return fallbackY
end

-- Descend the station's main shaft from the surface to the room dock, then
-- release the shaft lock. This is a one-time transit; mining trips start and
-- end at the room, not at the surface.
local function transitToRoom(spec, mission, snap, bus, useGps, stationId, id, tunnel)
  local p = pose.copy(spec.base)
  local gok, gerr = gps.syncPose(p, hal, false)
  if not gok then
    return nil, "GPS required to find the shaft: " .. tostring(gerr)
  end

  local sx, sz = shaftColumn(spec)
  if bus.station and bus.station.shaftPose then
    sx, sz = bus.station.shaftPose.x, bus.station.shaftPose.z
  end
  local dockX, dockY, dockZ = spec.base.x, spec.base.y, spec.base.z

  -- Already on the room dock.
  if p.x == dockX and p.y == dockY and p.z == dockZ then
    snap.pose = p
    snap.atRoom = true
    if type(snap.surfaceY) ~= "number" then
      snap.surfaceY = stationSurfaceY(bus, dockY, p.y)
    end
    return true
  end

  if p.y < dockY then
    return nil, ("miner is below the station room at Y%d; move it to the shaft top"):format(p.y)
  end

  -- Walk to the shaft column when the miner is standing on the open surface.
  -- This is non-digging: a blocked path fails with a clear error instead of
  -- carving through the landscape.
  local shaftTopY = bus.station and bus.station.shaftPose and bus.station.shaftPose.y
  if p.y == shaftTopY and (p.x ~= sx or p.z ~= sz) then
    local walk = nav.new(hal, tape.new(), spec.reserve, p, useGps)
    local function walkAxis(dx, dz)
      if dx ~= 0 then
        local ok, err = nav.face(walk, dx > 0 and 1 or 3)
        if not ok then return nil, err end
        for _ = 1, math.abs(dx) do
          local sok, serr = nav.step(walk, "forward")
          if not sok then return nil, serr end
        end
      end
      if dz ~= 0 then
        local ok, err = nav.face(walk, dz > 0 and 2 or 0)
        if not ok then return nil, err end
        for _ = 1, math.abs(dz) do
          local sok, serr = nav.step(walk, "forward")
          if not sok then return nil, serr end
        end
      end
      return true
    end
    local ok, err = walkAxis(sx - p.x, sz - p.z)
    if not ok then
      nav.retraceAll(walk)
      return nil, ("could not walk to the shaft top at x=%d z=%d: %s"):format(sx, sz, tostring(err))
    end
    p = pose.copy(walk.pose)
    snap.pose = p
  end

  -- At the room's walking level but not on the dock: the room is open, so
  -- walk across instead of demanding exact placement.
  if p.y == dockY and (p.x ~= dockX or p.z ~= dockZ) then
    local walk = nav.new(hal, tape.new(), spec.reserve, p, useGps)
    local dx, dz = dockX - p.x, dockZ - p.z
    local ok, err = true, nil
    if dx ~= 0 then
      ok, err = nav.face(walk, dx > 0 and 1 or 3)
      if ok then
        for _ = 1, math.abs(dx) do
          ok, err = nav.step(walk, "forward")
          if not ok then break end
        end
      end
    end
    if ok and dz ~= 0 then
      ok, err = nav.face(walk, dz > 0 and 2 or 0)
      if ok then
        for _ = 1, math.abs(dz) do
          ok, err = nav.step(walk, "forward")
          if not ok then break end
        end
      end
    end
    if not ok then
      nav.retraceAll(walk)
      return nil, "could not walk to the room dock: " .. tostring(err)
    end
    snap.pose = pose.copy(walk.pose)
    snap.atRoom = true
    if type(snap.surfaceY) ~= "number" then
      snap.surfaceY = stationSurfaceY(bus, dockY, walk.pose.y)
    end
    save(snap, mission, nil, false)
    progressMsg(bus, mission, snap, nil, "idle")
    util.log(("miner: walked to the room dock at x=%d y=%d z=%d"):format(walk.pose.x, walk.pose.y, walk.pose.z))
    return true
  end

  if p.x ~= sx or p.z ~= sz then
    return nil, ("miner must be placed on the shaft top at x=%d z=%d (currently x=%d z=%d)"):format(
      sx, sz, p.x, p.z
    )
  end

  local down = p.y - dockY
  local fuel = hal.fuel()
  if type(fuel) == "number" and fuel < down + spec.reserve then
    return nil, ("not enough fuel to descend: need %d, have %d"):format(down + spec.reserve, fuel)
  end

  if tunnel and not shaft.acquire(tunnel, stationId, id, "descent") then
    return nil, "shaft lock unavailable for descent"
  end

  snap.surfaceY = stationSurfaceY(bus, dockY, p.y)
  local trip = nav.new(hal, tape.new(), spec.reserve, p, useGps)
  snap.tripActive = true
  snap.pose = trip.pose
  snap.tape = trip.tape
  save(snap, mission, trip, true)

  for i = 1, down do
    local data = hal.inspectDown()
    if data and hal.hazard(data) then
      nav.retraceAll(trip)
      if tunnel then shaft.release(tunnel, stationId, id) end
      return nil, ("hazard at Y%d in the shaft; refusing to descend"):format(trip.pose.y - 1)
    end
    if data and not hal.passable(data) then
      local dok, derr = hal.digDown()
      if not dok then
        nav.retraceAll(trip)
        if tunnel then shaft.release(tunnel, stationId, id) end
        return nil, ("shaft blocked at Y%d: %s"):format(trip.pose.y - 1, tostring(derr))
      end
    end
    local mok, merr = nav.down(trip, 1)
    if not mok then
      nav.retraceAll(trip)
      if tunnel then shaft.release(tunnel, stationId, id) end
      return nil, ("descent failed at Y%d: %s"):format(trip.pose.y, tostring(merr))
    end
    if i % 32 == 0 then
      save(snap, mission, trip, true)
      progressMsg(bus, mission, snap, trip, "descending")
    end
  end

  -- Step off the shaft column onto the dock (south, opposite the staging leg).
  -- Another miner may be parked there between trips, so wait for the cell to
  -- clear instead of failing the whole transit. The wait is bounded: holding
  -- the shaft lock must not block an ascent for long.
  local fok, ferr = nav.face(trip, 2)
  if fok then fok, ferr = nav.step(trip, "forward") end
  local waited = 0
  while not fok and waited < 20 and not tostring(ferr):find("fuel", 1, true) do
    local blocker = hal.inspect()
    util.log("miner: room dock blocked by", blocker and blocker.name or "unknown", "- waiting")
    os.sleep(1)
    waited = waited + 1
    fok, ferr = nav.step(trip, "forward")
  end
  if not fok then
    nav.retraceAll(trip)
    if tunnel then shaft.release(tunnel, stationId, id) end
    return nil, "could not step into the room: " .. tostring(ferr)
  end
  nav.face(trip, 0)

  if tunnel then shaft.release(tunnel, stationId, id) end

  spec.base = pose.copy(trip.pose)
  snap.pose = pose.copy(trip.pose)
  snap.tripActive = false
  snap.tape = tape.new()
  snap.atRoom = true
  save(snap, mission, nil, false)
  progressMsg(bus, mission, snap, nil, "idle")
  util.log(("miner: reached room dock at x=%d y=%d z=%d"):format(trip.pose.x, trip.pose.y, trip.pose.z))
  return true
end

-- Drop mined items into the nearest storage chest. The dock itself sits on
-- storage chest 01, so the common case is a zero-distance walk.
local function depositIntoRoom(trip, chests)
  if #chests == 0 then
    util.log("miner: no registered chests; leaving items in inventory")
    return 0
  end
  local chest = findNearestStorageChest(trip, chests)
  if not chest then return 0 end
  local entry = tape.length(trip.tape)
  local savedReserve = trip.reserve
  trip.reserve = 0
  local ok, err = navigateTo(trip, chest.pose.x, chest.pose.y + 1, chest.pose.z)
  local dropped = 0
  if ok then
    dropped = depositItemsDown()
  else
    util.log("miner: could not reach storage chest:", err or "unknown")
  end
  nav.retraceTo(trip, entry)
  trip.reserve = savedReserve
  return dropped
end

-- Pull fuel from the refueling chest (stand on it and suck down).
local function refuelInRoom(trip, chests)
  local chest = findRefuelChest(chests)
  if not chest then return false, "no registered refuel chest" end
  local entry = tape.length(trip.tape)
  local savedReserve = trip.reserve
  trip.reserve = 0
  local ok, err = navigateTo(trip, chest.pose.x, chest.pose.y + 1, chest.pose.z)
  if not ok then
    trip.reserve = savedReserve
    return false, err
  end
  for _ = 1, 16 do
    if not hal.suckDown() then break end
  end
  local fuelOK, fuelErr = hal.refuelFromInventory()
  nav.retraceTo(trip, entry)
  trip.reserve = savedReserve
  return fuelOK, fuelErr
end

-- Climb the main shaft back to the surface (recall, pause, abort, or mission
-- complete). Best effort: if fuel or the lock is missing, stay in the room.
local function ascendToSurface(spec, mission, snap, bus, stationId, id, tunnel, useGps)
  if not snap.atRoom then return true end
  local surfaceY = snap.surfaceY
  if type(surfaceY) ~= "number" then
    return nil, "surface Y unknown; cannot ascend"
  end
  if snap.pose.y >= surfaceY then
    snap.atRoom = false
    return true
  end

  if tunnel and not shaft.acquire(tunnel, stationId, id, "ascent") then
    return nil, "shaft lock unavailable for ascent"
  end

  local trip = nav.new(hal, tape.new(), 0, pose.copy(snap.pose), useGps)
  local sx, sz = shaftColumn(spec)
  if trip.pose.x ~= sx or trip.pose.z ~= sz then
    local ok, err = nav.face(trip, 0)
    if ok then ok, err = nav.step(trip, "forward") end
    if not ok then
      if tunnel then shaft.release(tunnel, stationId, id) end
      return nil, "could not enter shaft column: " .. tostring(err)
    end
  end

  local up = surfaceY - trip.pose.y
  local fuel = hal.fuel()
  if type(fuel) == "number" and fuel < up then
    if tunnel then shaft.release(tunnel, stationId, id) end
    return nil, ("not enough fuel to ascend: need %d, have %d"):format(up, fuel)
  end

  for i = 1, up do
    local data = hal.inspectUp()
    if data and hal.hazard(data) then
      if tunnel then shaft.release(tunnel, stationId, id) end
      return nil, ("hazard at Y%d in the shaft; refusing to ascend"):format(trip.pose.y + 1)
    end
    if data and not hal.passable(data) then
      local dok, derr = hal.digUp()
      if not dok then
        if tunnel then shaft.release(tunnel, stationId, id) end
        return nil, ("ascent blocked at Y%d: %s"):format(trip.pose.y + 1, tostring(derr))
      end
    end
    local ok, err = nav.up(trip, 1)
    if not ok then
      if tunnel then shaft.release(tunnel, stationId, id) end
      return nil, "ascent failed: " .. tostring(err)
    end
    if i % 32 == 0 then
      snap.pose = pose.copy(trip.pose)
      save(snap, mission, nil, false)
      progressMsg(bus, mission, snap, trip, "ascending")
    end
  end

  if tunnel then shaft.release(tunnel, stationId, id) end
  snap.pose = pose.copy(trip.pose)
  snap.atRoom = false
  snap.tripActive = false
  snap.tape = tape.new()
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

  -- Specs from before the room-as-base change carry a surface base and cannot
  -- be trusted (they would dig beside the shaft). Wait for the console to
  -- reissue the mission with the room dock instead of starting the old spec.
  if tunnel and spec.baseVersion ~= 2 then
    util.log("miner: outdated mission spec; waiting for the console to reissue it")
    if bus then bus.state = "idle" end
    for _ = 1, 120 do
      local candidate = bus.mission
      if candidate and candidate ~= mission and candidate.spec and candidate.spec.baseVersion == 2 then
        return "reload"
      end
      if bus.abort then return nil, "aborted" end
      os.sleep(0.5)
    end
    return nil, "outdated mission spec; reissue the mission from the console"
  end

  -- Fetch chest positions for this station.
  local chests = {}
  if tunnel then
    local fetched = getStationChests(tunnel, stationId)
    if fetched then chests = fetched end
    util.log("miner: loaded", #chests, "chests for station", stationId)
  end

  local useGps = gps.available(1)
  if useGps then
    util.log("miner: GPS available, using absolute positioning")
  else
    util.log("miner: GPS unavailable; single-turtle/test mode")
  end

  local snap = state.load(hal.fuel)
  if not snap then
    snap = {
      progress = plan.copyProgress(mission.progress or { leg = 1, offset = 0, layer = 0, strip = 0 }),
      stats = { blocks = 0, ores = 0, trips = 0 },
      tripActive = false,
      pose = pose.copy(spec.base),
      tape = tape.new(),
      seq = 0,
      atRoom = false,
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
    snap.atRoom = false
    snap.surfaceY = nil
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

  -- A mission created by the console for a station has a real dock pose. Tests
  -- (and hand-built specs) use the origin to mean "dock here", which keeps the
  -- old in-place behaviour.
  local roomBased = spec.base.x ~= 0 or spec.base.y ~= 0 or spec.base.z ~= 0
  if roomBased then
    -- After a reboot in the room there is no GPS underground, so resume from
    -- the saved room pose instead of trying to fly down the shaft again. The
    -- miner may be parked on its own cell: keep the spec base on the dock and
    -- let the trip loop walk back to it.
    local resumedInRoom = snap.atRoom
      and not snap.tripActive
      and snap.pose.y == spec.base.y

    if resumedInRoom then
      util.log(("miner: resuming in the station room at x=%d y=%d z=%d"):format(
        snap.pose.x, snap.pose.y, snap.pose.z
      ))
    else
      if not useGps then
        return nil, "GPS is required to find the station shaft; fix GPS before mining"
      end
      local tok, terr = transitToRoom(spec, mission, snap, bus, useGps, stationId, id, tunnel)
      if not tok then return nil, terr end
    end
  else
    util.log("miner: using spec base as the dock")
    snap.atRoom = false
  end

  local legs = plan.build(spec)
  if #legs == 0 then return nil, "empty plan" end

  local gate = newShaftGate(tunnel, stationId, id, legs)

  if bus then
    bus.pose = snap.pose
    bus.progress = snap.progress
    bus.stats = snap.stats
  end

  local function goHome()
    local hok, herr = ascendToSurface(spec, mission, snap, bus, stationId, id, tunnel, useGps)
    if not hok then
      util.log("miner: could not ascend to surface:", herr or "unknown")
    end
    return hok, herr
  end

  if plan.normalize(legs, snap.progress) then
    goHome()
    return "done"
  end
  progressMsg(bus, mission, snap, nil, "idle")

  while true do
    if bus.abort then
      goHome()
      snap.halted = true
      save(snap, mission, nil, false)
      return nil, "aborted"
    end
    if bus.returnHome then
      goHome()
      snap.paused = true
      save(snap, mission, nil, false)
      return "paused"
    end

    -- Trips start at the shared room dock. Walk back to it first, waiting out
    -- the other miner if it is standing there.
    if snap.atRoom then
      local ok, derr = walkInRoom(snap, spec.base.x, spec.base.y, spec.base.z, 120)
      if not ok then
        return nil, "could not reach the room dock: " .. tostring(derr)
      end
    end

    -- Trips start and end at the room dock. Keep enough fuel to walk across
    -- the room and still climb the shaft on the way out, so the miner never
    -- strands itself underground.
    local ascentReserve = 0
    if snap.atRoom and type(snap.surfaceY) == "number" then
      ascentReserve = math.max(0, snap.surfaceY - spec.base.y)
    end
    local tripReserve = spec.reserve + 32 + ascentReserve
    local trip = nav.new(hal, tape.new(), tripReserve, pose.copy(spec.base), useGps)
    snap.tripActive = true
    snap.pose = trip.pose
    snap.tape = trip.tape
    save(snap, mission, trip, true)

    if snap.atRoom then
      -- Every trip replays the route from the dock through the shaft to the
      -- frontier, so the shaft must be free before the first step.
      if not gate.acquire() then
        snap.tripActive = false
        save(snap, mission, nil, false)
        return nil, "shaft lock unavailable for the trip"
      end
    end

    local tok, terr = travelTo(trip, legs, snap.progress, bus)
    if gate.held then gate.maybeRelease(snap.progress) end
    if not tok then
      local homeOK, homeErr = retraceTrip(trip, gate, bus)
      snap.tripActive = false
      snap.tape = tape.new()
      snap.pose = pose.copy(trip.pose)
      save(snap, mission, nil, false)
      if not homeOK then
        return nil, "travel failed: " .. tostring(terr) .. "; return failed: " .. tostring(homeErr)
      end
      if bus.abort then
        goHome()
        snap.halted = true
        save(snap, mission, nil, false)
        return nil, "aborted"
      end
      if bus.returnHome then
        goHome()
        snap.paused = true
        save(snap, mission, nil, false)
        return "paused"
      end
      return nil, "travel failed: " .. tostring(terr)
    end

    local mined, merr = mine(trip, legs, snap.progress, snap, mission, spec.maxTripBlocks, bus, gate)

    -- Pop the whole trip tape: back to the room dock, including the staging
    -- and descent legs.
    local retOK, retErr = retraceTrip(trip, gate, bus)
    if retOK then
      local dropped = depositIntoRoom(trip, chests)
      if dropped > 0 then
        util.log("miner: deposited", dropped, "item stacks into a storage chest")
      end
      local fuelOK, fuelErr = refuelInRoom(trip, chests)
      if fuelOK then
        util.log("miner: refueled from the room's refuel chest")
      elseif fuelErr then
        util.log("miner: refuel failed:", fuelErr)
      end
    else
      util.log("miner: retrace to the room failed:", retErr or "unknown")
    end

    tape.clear(trip.tape)
    snap.tape = tape.new()
    snap.tripActive = false
    snap.pose = pose.copy(trip.pose)
    snap.stats.trips = snap.stats.trips + 1

    -- Clear the dock so the other miner can start its trip.
    if retOK and snap.atRoom then
      local px, py, pz = parkingCell(spec)
      if px then
        local pok, perr = walkInRoom(snap, px, py, pz, 3)
        if not pok then
          util.log("miner: could not reach the parking spot:", perr or "unknown")
        end
      end
    end

    save(snap, mission, nil, false)
    progressMsg(bus, mission, snap, nil, "idle")

    if plan.normalize(legs, snap.progress) then
      goHome()
      return "done"
    end
    if not mined then
      if bus.abort then
        goHome()
        snap.halted = true
        save(snap, mission, nil, false)
        return nil, "aborted"
      end
      if bus.returnHome then
        goHome()
        snap.paused = true
        save(snap, mission, nil, false)
        return "paused"
      end
      util.log("miner: mine failed; staying in the station room:", merr or "unknown")
      return nil, "mine failed: " .. tostring(merr)
    end
    if mined == 0 then
      util.log("miner: no progress this trip; staying in the station room")
      return nil, "no progress this trip (fuel or inventory)"
    end
    if bus.abort then
      goHome()
      snap.halted = true
      save(snap, mission, nil, false)
      return nil, "aborted"
    end
    if bus.returnHome then
      goHome()
      snap.paused = true
      save(snap, mission, nil, false)
      return "paused"
    end
  end
end

return M
