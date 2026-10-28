-- Offline tests for the pure modules, journal recovery, and a full small
-- mission against a mock turtle. Run from the repo root:
--
--   lua mine/test/test.lua
--
-- The mock patches lib.util's file functions, so nothing here touches the
-- host filesystem or the CC turtle API.
package.path = "mine/?.lua;mine/?/init.lua;" .. package.path

local failures = 0
local tests = 0

local function fail(name, message)
  failures = failures + 1
  print(("FAIL %s: %s"):format(name, message))
end

local function test(name, fn)
  tests = tests + 1
  local ok, err = pcall(fn)
  if not ok then fail(name, err) end
end

local function eq(name, actual, expected)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(name, tostring(expected), tostring(actual)), 2)
  end
end

local function eqPose(name, p, x, y, z, f)
  eq(name .. ".x", p.x, x)
  eq(name .. ".y", p.y, y)
  eq(name .. ".z", p.z, z)
  eq(name .. ".f", p.f, f)
end

-- ---------------------------------------------------------------------------
-- Pose
-- ---------------------------------------------------------------------------
local pose = require("lib.pose")

test("pose translations and turns", function()
  local p = pose.new(0, 0, 0, 0)
  pose.apply(p, "forward")
  eqPose("north", p, 0, 0, -1, 0)
  pose.apply(p, "turnRight")
  pose.apply(p, "forward")
  eqPose("east", p, 1, 0, -1, 1)
  pose.apply(p, "up")
  pose.apply(p, "down")
  pose.apply(p, "back")
  eqPose("back", p, 0, 0, -1, 1)
end)

test("pose turnOps", function()
  eq("#turnOps(0,3)", #pose.turnOps(0, 3), 1)
  eq("turnOps(0,3)[1]", pose.turnOps(0, 3)[1], "turnLeft")
  eq("#turnOps(0,2)", #pose.turnOps(0, 2), 2)
  eq("#turnOps(2,2)", #pose.turnOps(2, 2), 0)
end)

test("pose inverse", function()
  eq("inverse forward", pose.inverse("forward"), "back")
  eq("inverse turnLeft", pose.inverse("turnLeft"), "turnRight")
end)

-- ---------------------------------------------------------------------------
-- Tape
-- ---------------------------------------------------------------------------
local tape = require("lib.tape")

test("tape stack and translation cost", function()
  local t = tape.new()
  tape.push(t, "forward")
  tape.push(t, "turnLeft")
  tape.push(t, "up")
  eq("cost", tape.cost(t), 2)
  eq("peek", tape.peek(t), "up")
  eq("pop", tape.pop(t), "up")
  eq("cost after up", tape.cost(t), 1)
  eq("pop turn", tape.pop(t), "turnLeft")
  eq("cost after turn", tape.cost(t), 1)
  eq("pop forward", tape.pop(t), "forward")
  eq("cost empty", tape.cost(t), 0)
end)

test("tape serialize round trip", function()
  local t = tape.new()
  tape.push(t, "forward")
  tape.push(t, "turnRight")
  local copy = tape.deserialize(tape.serialize(t))
  eq("length", tape.length(copy), 2)
  eq("cost", tape.cost(copy), 1)
  eq("last", tape.peek(copy), "turnRight")
end)

-- ---------------------------------------------------------------------------
-- Plan
-- ---------------------------------------------------------------------------
local plan = require("lib.plan")

local function smallSpec()
  return {
    kind = "branchMine",
    base = { x = 0, y = 0, z = 0, f = 0 },
    staging = 1,
    sector = { x0 = -4, z0 = -5, x1 = 4, z1 = 1 },
    startY = -2,
    endY = -2,
    layerStep = 2,
    spacing = 3,
    maxRadius = 4,
    maxTripBlocks = 100,
    maxVeinBlocks = 0,
    reserve = 16,
  }
end

test("plan geometry is deterministic and continuous", function()
  local spec = smallSpec()
  local legs = plan.build(spec)
  -- staging north 1, down 2, west 4, north 4, 3 strips of 8 + 2 connectors of 3
  eq("leg count", #legs, 4 + 3 + 2)
  eq("leg1 kind", legs[1].kind, "line")
  eq("leg1 dir", legs[1].dir, 0)
  eq("leg1 length", legs[1].length, 1)
  eq("leg2 kind", legs[2].kind, "down")
  eq("leg2 length", legs[2].length, 2)
  eq("leg3 dir", legs[3].dir, 3)
  eq("leg3 length", legs[3].length, 4)
  eq("leg4 dir", legs[4].dir, 0)
  eq("leg4 length", legs[4].length, 4)

  -- Walk the legs on a pose and check every leg starts where the previous ended.
  local p = pose.new(0, 0, 0, 0)
  local function walk(leg)
    if leg.kind == "down" then
      p.y = p.y - leg.length
    else
      eq("line dir", p.f, leg.dir)
      for _ = 1, leg.length do pose.apply(p, "forward") end
    end
  end
  pose.apply(p, "forward") -- staging
  eqPose("shaft top", p, 0, 0, -1, 0)
  for i = 2, #legs do
    local leg = legs[i]
    if leg.kind == "line" then
      local ops = pose.turnOps(p.f, leg.dir)
      for _, op in ipairs(ops) do pose.apply(p, op) end
    end
    walk(leg)
  end
  eqPose("end of plan", p, 4, -2, 1, 1)
  eq("total", plan.total(legs), 1 + 2 + 4 + 4 + 24 + 6)
end)

test("plan normalize and completion", function()
  local legs = plan.build(smallSpec())
  local progress = { leg = 1, offset = 0, layer = 0, strip = 0 }
  eq("not complete", plan.normalize(legs, progress), false)
  progress.offset = legs[1].length
  eq("advance", plan.normalize(legs, progress), false)
  eq("leg after advance", progress.leg, 2)
  eq("offset reset", progress.offset, 0)
  progress.leg = #legs
  progress.offset = legs[#legs].length
  eq("complete", plan.normalize(legs, progress), true)
  eq("past end", progress.leg, #legs + 1)
end)

test("plan validate rejects unsafe specs", function()
  local hard = { maxRadius = 128, maxDepth = 200 }
  local ok = plan.validate(smallSpec(), hard)
  eq("small spec ok", ok, true)

  local spec = smallSpec()
  spec.maxRadius = 129
  local valid, err = plan.validate(spec, hard)
  eq("radius invalid", valid, nil)
  eq("radius error", err, "maxRadius exceeds local cap")

  spec = smallSpec()
  spec.endY = -1
  valid, err = plan.validate(spec, hard)
  eq("y invalid", valid, nil)
  eq("y error", err, "endY must be at or below startY")

  spec = smallSpec()
  spec.staging = 9
  valid, err = plan.validate(spec, hard)
  eq("staging invalid", valid, nil)
  eq("staging error", err, "staging must be 0..4")
end)

-- ---------------------------------------------------------------------------
-- Fuel safety
-- ---------------------------------------------------------------------------
local safety = require("lib.safety")

test("fuel invariant", function()
  local t = tape.new()
  eq("turn at reserve", safety.canTurn(0, t, 0), true)
  eq("step needs two fuel", safety.canStep(1, t, 0), false)
  eq("step with two fuel", safety.canStep(2, t, 0), true)

  tape.push(t, "forward")
  eq("retrace at one fuel", safety.canRetrace(1, t, 0), true)
  eq("turn at one fuel", safety.canTurn(1, t, 0), true)
  eq("step needs three fuel", safety.canStep(2, t, 0), false)
  eq("step with three fuel", safety.canStep(3, t, 0), true)

  eq("end trip at reserve", safety.shouldEndTrip(1, t, 0, 0), true)
  eq("not end trip above reserve", safety.shouldEndTrip(2, t, 0, 0), false)
  eq("unlimited never ends", safety.shouldEndTrip("unlimited", t, 0, 0), false)
end)

-- ---------------------------------------------------------------------------
-- Journal recovery
-- ---------------------------------------------------------------------------
local util = require("lib.util")
local state = require("lib.state")

local files = {}
local snapshots = {}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end

util.readFile = function(path) return files[path] end
util.writeFile = function(path, data) files[path] = data; return true end
util.append = function(path, data) files[path] = (files[path] or "") .. data; return true end
util.readJson = function(path)
  if path == state.STATE then return copy(snapshots[path]) end
  return nil
end
util.writeJson = function(path, value) snapshots[path] = copy(value); return true end
util.now = function() return 1000 end

local function resetStore(snapshot, journal)
  files = {}
  snapshots = {}
  if snapshot then snapshots[state.STATE] = snapshot end
  if journal then files[state.JOURNAL] = journal end
  state.resetJournal()
  if snapshot then snapshots[state.STATE] = snapshot end
  if journal then files[state.JOURNAL] = journal end
end

local function baseSnapshot(overrides)
  local snap = {
    pose = { x = 0, y = 0, z = 0, f = 0 },
    tape = {},
    seq = 0,
    progress = { leg = 1, offset = 0, layer = 0, strip = 0 },
    stats = { blocks = 0, ores = 0, trips = 0 },
    tripActive = true,
    mission = { id = "m1", spec = smallSpec() },
  }
  for k, v in pairs(overrides or {}) do snap[k] = v end
  return snap
end

test("journal replays a committed move", function()
  resetStore(baseSnapshot({ tape = { "forward" }, seq = 1, pose = { x = 0, y = 0, z = -1, f = 0 } }),
    "I 2 move forward 100\nC 2 forward\n")
  local loaded = state.load(function() return 99 end)
  eq("ops", #loaded.tape.ops, 2)
  eq("pose z", loaded.pose.z, -2)
  eq("seq", loaded.seq, 2)
  eq("uncertain", loaded.uncertain, false)
end)

test("journal resolves an interrupted failed move", function()
  resetStore(baseSnapshot({}), "I 1 move forward 100\n")
  local loaded = state.load(function() return 100 end)
  eq("ops", #loaded.tape.ops, 0)
  eq("pose z", loaded.pose.z, 0)
  eq("uncertain", loaded.uncertain, false)
end)

test("journal resolves an interrupted successful move", function()
  resetStore(baseSnapshot({}), "I 1 move forward 100\n")
  local loaded = state.load(function() return 99 end)
  eq("ops", #loaded.tape.ops, 1)
  eq("pose z", loaded.pose.z, -1)
  eq("uncertain", loaded.uncertain, false)
end)

test("journal replays a retrace", function()
  resetStore(baseSnapshot({ tape = { "forward" }, seq = 1, pose = { x = 0, y = 0, z = -1, f = 0 } }),
    "I 2 retrace back 99\nR 2 back\n")
  local loaded = state.load(function() return 98 end)
  eq("ops", #loaded.tape.ops, 0)
  eq("pose z", loaded.pose.z, 0)
  eq("seq", loaded.seq, 2)
end)

test("journal ignores lines already in the checkpoint", function()
  resetStore(baseSnapshot({ seq = 5 }), "C 3 forward\n")
  local loaded = state.load(function() return 100 end)
  eq("ops", #loaded.tape.ops, 0)
  eq("pose z", loaded.pose.z, 0)
end)

test("interrupted turn is assumed complete and marked uncertain", function()
  resetStore(baseSnapshot({}), "I 1 move turnLeft 100\n")
  local loaded = state.load(function() return 100 end)
  eq("ops", #loaded.tape.ops, 1)
  eq("pose f", loaded.pose.f, 3)
  eq("uncertain", loaded.uncertain, true)
end)

test("interrupted retrace turn is assumed complete", function()
  resetStore(
    baseSnapshot({ tape = { "turnLeft" }, pose = { x = 0, y = 0, z = 0, f = 3 } }),
    "I 2 retrace turnRight 100\n"
  )
  local loaded = state.load(function() return 100 end)
  eq("ops", #loaded.tape.ops, 0)
  eq("pose f", loaded.pose.f, 0)
  eq("uncertain", loaded.uncertain, true)
end)

test("intent, commit, checkpoint and reload", function()
  resetStore(baseSnapshot({ tripActive = false }), "")
  state.resetJournal()
  local snap = {
    pose = { x = 0, y = 0, z = 0, f = 0 },
    tape = tape.new(),
    progress = { leg = 1, offset = 0, layer = 0, strip = 0 },
    stats = { blocks = 0, ores = 0, trips = 0 },
    mission = { id = "m1", spec = smallSpec() },
  }
  local seq = state.intent("forward", 100)
  eq("intent seq", seq, 1)
  eq("journal intent", files[state.JOURNAL], "I 1 move forward 100\n")
  snap.pose.z = -1
  tape.push(snap.tape, "forward")
  state.commit("forward")
  eq("journal commit", files[state.JOURNAL], "I 1 move forward 100\nC 1 forward\n")
  snap.tripActive = false
  state.save(snap)
  eq("journal truncated", files[state.JOURNAL], "")
  eq("snapshot seq", snapshots[state.STATE].seq, 1)
  eq("snapshot tape", #snapshots[state.STATE].tape, 1)

  local loaded = state.load(function() return 99 end)
  eq("reloaded ops", #loaded.tape.ops, 1)
  eq("reloaded pose", loaded.pose.z, -1)
  eq("reloaded seq", loaded.seq, 1)
end)

-- ---------------------------------------------------------------------------
-- Mock turtle: one complete small mission
-- ---------------------------------------------------------------------------
local hal = require("lib.hal")
local miner = require("lib.miner")

local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = -1, 0, 1, 0 }

local function key(x, y, z)
  return ("%d,%d,%d"):format(x, y, z)
end

local function newTurtle()
  local t = {
    x = 0, y = 0, z = 0, f = 0,
    fuel = 1000,
    selected = 1,
    inventory = {},
    air = {},
    ores = {},
  }
  t.air[key(0, 0, 0)] = true -- the turtle's dock cell
  t.air[key(0, 0, -1)] = true -- shaft top, north of the dock
  t.inventory[16] = { name = "minecraft:coal", count = 8 }
  return t
end

local function target(t, op)
  if op == "up" then return t.x, t.y + 1, t.z end
  if op == "down" then return t.x, t.y - 1, t.z end
  local sign = op == "back" and -1 or 1
  return t.x + DX[t.f] * sign, t.y, t.z + DZ[t.f] * sign
end

local function blockAt(t, x, y, z)
  local k = key(x, y, z)
  if t.air[k] then return nil end
  return { name = t.ores[k] or "minecraft:stone" }
end

local function frontBlock(t)
  return blockAt(t, t.x + DX[t.f], t.y, t.z + DZ[t.f])
end

local mock = {}

function mock.getFuelLevel() return mock.turtle.fuel end
function mock.getFuelLimit() return 100000 end

function mock.forward() return mock.move("forward") end
function mock.back() return mock.move("back") end
function mock.up() return mock.move("up") end
function mock.down() return mock.move("down") end

function mock.move(op)
  local t = mock.turtle
  local x, y, z = target(t, op)
  if blockAt(t, x, y, z) then return false, "Movement blocked" end
  t.x, t.y, t.z = x, y, z
  t.fuel = t.fuel - 1
  return true
end

function mock.turnLeft()
  mock.turtle.f = (mock.turtle.f + 3) % 4
  return true
end

function mock.turnRight()
  mock.turtle.f = (mock.turtle.f + 1) % 4
  return true
end

function mock.dig()
  local t = mock.turtle
  local data = frontBlock(t)
  if not data then return false, "Nothing to dig" end
  local x, y, z = t.x + DX[t.f], t.y, t.z + DZ[t.f]
  t.air[key(x, y, z)] = true
  return true
end

function mock.digUp()
  local t = mock.turtle
  if not blockAt(t, t.x, t.y + 1, t.z) then return false, "Nothing to dig" end
  t.air[key(t.x, t.y + 1, t.z)] = true
  return true
end

function mock.digDown()
  local t = mock.turtle
  if not blockAt(t, t.x, t.y - 1, t.z) then return false, "Nothing to dig" end
  t.air[key(t.x, t.y - 1, t.z)] = true
  return true
end

function mock.inspect()
  local data = frontBlock(mock.turtle)
  if not data then return false, "No block" end
  return true, data
end

function mock.inspectUp()
  local t = mock.turtle
  local data = blockAt(t, t.x, t.y + 1, t.z)
  if not data then return false, "No block" end
  return true, data
end

function mock.inspectDown()
  local t = mock.turtle
  local data = blockAt(t, t.x, t.y - 1, t.z)
  if not data then return false, "No block" end
  return true, data
end

function mock.select(slot)
  mock.turtle.selected = slot
  return true
end

function mock.getSelectedSlot()
  return mock.turtle.selected
end

function mock.getItemDetail(slot)
  local item = mock.turtle.inventory[slot]
  if not item then return false, nil end
  return true, { name = item.name, count = item.count }
end

function mock.dropDown()
  local slot = mock.turtle.selected
  if mock.turtle.inventory[slot] then
    mock.turtle.inventory[slot] = nil
    return true
  end
  return false, "Nothing to drop"
end

function mock.suckUp()
  return false, "No chest above"
end

function mock.refuel()
  local slot = mock.turtle.selected
  local item = mock.turtle.inventory[slot]
  if not item or item.name ~= "minecraft:coal" then return false, "Not fuel" end
  item.count = item.count - 1
  if item.count <= 0 then mock.turtle.inventory[slot] = nil end
  mock.turtle.fuel = mock.turtle.fuel + 100
  return true
end

test("mock turtle completes a small branch mission", function()
  resetStore(nil, nil)
  snapshots = {}
  files = {}
  state.resetJournal()

  local t = newTurtle()
  mock.turtle = t
  hal.setBackend(mock)

  local spec = smallSpec()
  local mission = {
    id = "mission-test-1",
    spec = spec,
    progress = { leg = 1, offset = 0, layer = 0, strip = 0 },
  }
  local messages = {}
  local bus = {
    outbox = {},
    send = function(msg) messages[#messages + 1] = msg end,
    status = function() return {} end,
  }

  local result, err = miner.run(mission, bus)
  if result ~= "done" then print("miner error: " .. tostring(err)) end
  eq("mission result", result, "done")
  eq("mission error", err, nil)
  eq("final turtle pose", ("%d,%d,%d,%d"):format(t.x, t.y, t.z, t.f), "0,0,0,0")
  eq("turtle fuel left", t.fuel > 16, true)
  eq("journal empty", files[state.JOURNAL], "")

  local loaded = state.load(function() return t.fuel end)
  eq("state trip inactive", loaded.tripActive, false)
  eq("state tape empty", #loaded.tape.ops, 0)
  eq("state complete", plan.complete(plan.build(spec), loaded.progress), true)
  eq("state blocks", loaded.stats.blocks, plan.total(plan.build(spec)))
  eq("state trips", loaded.stats.trips, 1)
  eq("state not paused", loaded.paused, false)
  eq("state not halted", loaded.halted, false)

  -- Dock fixture stays solid; the shaft and first tunnel are air.
  eq("dock floor solid", blockAt(t, 0, -1, 0) ~= nil, true)
  eq("dock back wall solid", blockAt(t, 0, 0, 1) ~= nil, true)
  eq("dock left wall solid", blockAt(t, -1, 0, 0) ~= nil, true)
  eq("shaft top air", blockAt(t, 0, 0, -1), nil)
  eq("shaft first block air", blockAt(t, 0, -1, -1), nil)
  eq("shaft second block air", blockAt(t, 0, -2, -1), nil)
  eq("first branch air", blockAt(t, -1, -2, -1), nil)
  eq("last branch air", blockAt(t, 4, -2, 1), nil)

  -- A progress message was sent and a result is left to the supervisor.
  local sawProgress = false
  for _, msg in ipairs(messages) do
    if msg.type == "progress" then sawProgress = true end
  end
  eq("sent progress", sawProgress, true)
end)

test("returnHome before a trip pauses and persists", function()
  resetStore(nil, nil)
  snapshots = {}
  files = {}
  state.resetJournal()

  local t = newTurtle()
  mock.turtle = t
  hal.setBackend(mock)

  local mission = {
    id = "pause-test-1",
    spec = smallSpec(),
    progress = { leg = 1, offset = 0, layer = 0, strip = 0 },
  }
  local bus = {
    outbox = {},
    send = function() end,
    returnHome = true,
  }

  local result = miner.run(mission, bus)
  eq("pause result", result, "paused")
  local loaded = state.load(function() return t.fuel end)
  eq("pause flag", loaded.paused, true)
  eq("halt flag", loaded.halted, false)
  eq("pause mission", loaded.mission.id, "pause-test-1")
  eq("pause pose", loaded.pose.z, 0)
end)

test("abort before a trip halts and persists", function()
  resetStore(nil, nil)
  snapshots = {}
  files = {}
  state.resetJournal()

  local t = newTurtle()
  mock.turtle = t
  hal.setBackend(mock)

  local mission = {
    id = "halt-test-1",
    spec = smallSpec(),
    progress = { leg = 1, offset = 0, layer = 0, strip = 0 },
  }
  local bus = {
    outbox = {},
    send = function() end,
    abort = true,
  }

  local result, err = miner.run(mission, bus)
  eq("abort result", result, nil)
  eq("abort error", err, "aborted")
  local loaded = state.load(function() return t.fuel end)
  eq("halt flag", loaded.halted, true)
  eq("pause flag", loaded.paused, false)
  eq("halt mission", loaded.mission.id, "halt-test-1")
end)

test("miner descends the station shaft to the room and mines from there", function()
  resetStore(nil, nil)
  snapshots = {}
  files = {}
  state.resetJournal()

  local t = newTurtle()
  -- Surface above the shaft column (0,0); room dock at (0,10,1).
  t.x, t.y, t.z, t.f = 0, 20, 0, 0
  t.fuel = 1000
  mock.turtle = t
  hal.setBackend(mock)

  for y = 10, 20 do t.air[key(0, y, 0)] = true end
  t.air[key(0, 10, 1)] = true

  local savedGps = _G.gps
  -- Report the live mock position, the way a real GPS would, so the periodic
  -- pose resync does not drag the turtle back to its starting Y.
  _G.gps = { locate = function() return mock.turtle.x, mock.turtle.y, mock.turtle.z end }

  local mission = {
    id = "transit-test-1",
    spec = {
      kind = "branchMine",
      base = { x = 0, y = 10, z = 1, f = 0 },
      staging = 1,
      sector = { x0 = -4, z0 = -5, x1 = 4, z1 = 1 },
      startY = -4,
      endY = -4,
      layerStep = 2,
      spacing = 3,
      maxRadius = 4,
      maxTripBlocks = 30,
      maxVeinBlocks = 0,
      reserve = 16,
    },
    progress = { leg = 1, offset = 0, layer = 0, strip = 0 },
  }
  -- A station built from the wrong level reports the room itself as the
  -- shaft top. The miner must still remember the real surface it started from
  -- so it reserves fuel for the climb.
  local bus = {
    outbox = {},
    send = function() end,
    station = { id = "s0", shaftPose = { x = 0, y = 10, z = 0, f = 0 } },
  }
  local result, err = miner.run(mission, bus)
  _G.gps = savedGps
  if result ~= "done" then print("transit miner error: " .. tostring(err)) end
  eq("transit result", result, "done")
  eq("transit ends at the surface", t.y, 20)
  eq("transit ends on the shaft column", ("%d,%d"):format(t.x, t.z), "0,0")
  local loaded = state.load(function() return t.fuel end)
  eq("transit atRoom cleared", loaded.atRoom, false)
  eq("transit surface Y recorded", loaded.surfaceY, 20)
end)

test("miner walks to the shaft top from the surface before descending", function()
  resetStore(nil, nil)
  snapshots = {}
  files = {}
  state.resetJournal()

  local t = newTurtle()
  -- Three blocks east of the shaft column on the surface.
  t.x, t.y, t.z, t.f = 3, 20, 0, 0
  t.fuel = 1000
  mock.turtle = t
  hal.setBackend(mock)

  for y = 10, 20 do t.air[key(0, y, 0)] = true end
  t.air[key(0, 10, 1)] = true
  t.air[key(1, 20, 0)] = true
  t.air[key(2, 20, 0)] = true

  local savedGps = _G.gps
  _G.gps = { locate = function() return mock.turtle.x, mock.turtle.y, mock.turtle.z end }

  local mission = {
    id = "walk-test-1",
    spec = {
      kind = "branchMine",
      base = { x = 0, y = 10, z = 1, f = 0 },
      staging = 1,
      sector = { x0 = -4, z0 = -5, x1 = 4, z1 = 1 },
      startY = -4,
      endY = -4,
      layerStep = 2,
      spacing = 3,
      maxRadius = 4,
      maxTripBlocks = 30,
      maxVeinBlocks = 0,
      reserve = 16,
    },
    progress = { leg = 1, offset = 0, layer = 0, strip = 0 },
  }
  local bus = {
    outbox = {},
    send = function() end,
    station = { id = "s0", shaftPose = { x = 0, y = 20, z = 0, f = 0 } },
  }
  local result, err = miner.run(mission, bus)
  _G.gps = savedGps
  if result ~= "done" then print("walk miner error: " .. tostring(err)) end
  eq("walk transit result", result, "done")
  eq("walk transit ends on the shaft column", ("%d,%d"):format(t.x, t.z), "0,0")
  eq("walk transit descends to the room", t.y, 20)
end)

test("miner resumes in the room without GPS after a reboot", function()
  resetStore(nil, nil)
  snapshots = {}
  files = {}
  state.resetJournal()

  local t = newTurtle()
  -- Already docked in the room, with the shaft above at (0,10..20,0).
  t.x, t.y, t.z, t.f = 0, 10, 1, 0
  t.fuel = 1000
  mock.turtle = t
  hal.setBackend(mock)

  for y = 10, 20 do t.air[key(0, y, 0)] = true end
  t.air[key(0, 10, 1)] = true

  local savedGps = _G.gps
  _G.gps = nil -- underground: GPS is not available

  local spec = {
    kind = "branchMine",
    base = { x = 0, y = 10, z = 1, f = 0 },
    staging = 1,
    sector = { x0 = -4, z0 = -5, x1 = 4, z1 = 1 },
    startY = -4,
    endY = -4,
    layerStep = 2,
    spacing = 3,
    maxRadius = 4,
    maxTripBlocks = 30,
    maxVeinBlocks = 0,
    reserve = 16,
  }
  local mission = {
    id = "resume-room-1",
    spec = spec,
    progress = { leg = 1, offset = 0, layer = 0, strip = 0 },
  }
  snapshots[state.STATE] = {
    pose = { x = 0, y = 10, z = 1, f = 0 },
    tape = {},
    seq = 0,
    progress = { leg = 1, offset = 0, layer = 0, strip = 0 },
    stats = { blocks = 0, ores = 0, trips = 0 },
    tripActive = false,
    atRoom = true,
    surfaceY = 20,
    mission = { id = mission.id, spec = spec },
  }

  local bus = { outbox = {}, send = function() end }
  local result, err = miner.run(mission, bus)
  _G.gps = savedGps
  if result ~= "done" then print("resume miner error: " .. tostring(err)) end
  eq("resume result", result, "done")
  eq("resume ends at the surface", t.y, 20)
end)

test("legacy mission spec waits for the console reissue", function()
  resetStore(nil, nil)
  snapshots = {}
  files = {}
  state.resetJournal()

  local t = newTurtle()
  mock.turtle = t
  hal.setBackend(mock)

  local function spec(version)
    return {
      kind = "branchMine",
      base = { x = 0, y = 10, z = 1, f = 0 },
      baseVersion = version,
      staging = 1,
      sector = { x0 = -4, z0 = -5, x1 = 4, z1 = 1 },
      startY = -4,
      endY = -4,
      layerStep = 2,
      spacing = 3,
      maxRadius = 4,
      maxTripBlocks = 10,
      maxVeinBlocks = 0,
      reserve = 16,
    }
  end

  local legacy = { id = "legacy-1", spec = spec(nil) }
  local replacement = { id = "legacy-1", spec = spec(2) }
  local bus = {
    serverUrl = "http://console",
    mission = replacement,
    outbox = {},
    send = function() end,
  }

  local result = miner.run(legacy, bus)
  eq("legacy waits for a reissue", result, "reload")
  eq("legacy did not move", t.y, 0)
end)

-- ---------------------------------------------------------------------------
print(("%d tests, %d failures"):format(tests, failures))
if failures > 0 then os.exit(1) end
