-- WebSocket link. Reconnects forever, refreshes the tunnel URL after repeated
-- failures, and queues outbound messages while offline. The supervisor and the
-- timber keep working across a link outage; the server re-offers the mission on
-- the next welcome.
local util = require("lib.util")
local resolve = require("lib.resolve")

local M = {}
M.VERSION = util.VERSION

local function decode(raw)
  return util.jsonDecode(raw)
end

function M.run(identity, bus)
  local ws = nil
  local backoff = 1
  local failures = 0

  bus.outbox = bus.outbox or {}

  -- The supervisor loads the checkpoint and sets bus.status. Wait for it so the
  -- hello carries the real state and a locally paused turtle is not re-offered.
  while not bus.status do os.sleep(0.1) end

  local function send(msg)
    if ws then
      local encoded = util.jsonEncode(msg)
      local ok, result = pcall(function() return ws.send(encoded) end)
      if ok and result ~= false then return true end
    end
    if #bus.outbox < 200 then
      bus.outbox[#bus.outbox + 1] = msg
    end
    return false
  end

  bus.send = send

  local function close()
    if ws then pcall(function() ws.close() end) end
    ws = nil
    bus.connected = false
  end

  local function handle(msg)
    if type(msg) ~= "table" then return end
    if msg.type == "welcome" then
      bus.connected = true
      bus.station = msg.station
      bus.config = msg.config or bus.config
      bus.serverTime = msg.serverTime
      bus.turtleId = msg.turtleId
      if msg.mission and not bus.mission and not bus.blocked then bus.mission = msg.mission end
      util.log("link: connected as", bus.turtleId or identity.id)
    elseif msg.type == "command" then
      local op = msg.op
      if op == "startMission" then
        if bus.mission and msg.mission and bus.mission.id == msg.mission.id then
          send({ type = "ack", id = msg.id, status = "already-running" })
        else
          bus.mission = msg.mission
          bus.commandId = msg.id
          bus.abort = false
          bus.returnHome = false
          bus.blocked = false
          send({ type = "ack", id = msg.id, status = "started" })
        end
      elseif op == "abort" then
        bus.abort = true
        send({ type = "ack", id = msg.id, status = "aborting" })
      elseif op == "returnHome" then
        bus.returnHome = true
        send({ type = "ack", id = msg.id, status = "returning" })
      elseif op == "ping" then
        send({ type = "pong", id = msg.id, seq = msg.seq })
      else
        send({ type = "ack", id = msg.id, status = "unknown-op" })
      end
    elseif msg.type == "error" then
      util.log("link: server error:", msg.error or "?")
    end
  end

  local function hello()
    local status = bus.status and bus.status() or {}
    local encoded = util.jsonEncode({
      v = 1,
      type = "hello",
      id = identity.id,
      secret = identity.secret,
      computerId = os.getComputerID(),
      label = os.getComputerLabel(),
      fw = M.VERSION,
      pose = status.pose,
      fuel = status.fuel,
      inventory = status.inventory,
      state = status.state,
      missionId = status.missionId,
    })
    local ok, result = pcall(function() return ws.send(encoded) end)
    return ok and result ~= false
  end

  local function flush()
    if not bus.connected then return end
    local out = bus.outbox
    bus.outbox = {}
    for i = 1, #out do
      if not send(out[i]) then
        for j = i + 1, #out do bus.outbox[#bus.outbox + 1] = out[j] end
        return
      end
    end
  end

  while true do
    local url, err = resolve.current()
    if not url then
      util.log("link: no tunnel address:", err)
      os.sleep(backoff)
      backoff = math.min(backoff * 2, 30)
    else
      util.log("link: connecting", resolve.wsUrl(url))
      local sock, werr = http.websocket(resolve.wsUrl(url), {
        ["User-Agent"] = "cc-util/" .. M.VERSION,
      })
      if not sock then
        util.log("link: websocket failed:", werr)
        failures = failures + 1
        if failures >= 3 then
          resolve.refresh()
          failures = 0
        end
        os.sleep(backoff)
        backoff = math.min(backoff * 2, 30)
      else
        ws = sock
        bus.connected = false
        if not hello() then
          close()
          os.sleep(backoff)
          backoff = math.min(backoff * 2, 30)
        else
        local raw = ws.receive(10)
        local welcome = raw and decode(raw) or nil
        if not welcome or welcome.type ~= "welcome" then
          util.log("link: no welcome", welcome and welcome.error or "")
          close()
          os.sleep(backoff)
          backoff = math.min(backoff * 2, 30)
        else
          handle(welcome)
          backoff = 1
          failures = 0
          flush()
          local lastBeat = util.now()
          while true do
            local incomingRaw = ws.receive(0.5)
            if incomingRaw then
              local incoming = decode(incomingRaw)
              if incoming then handle(incoming) end
            end
            local status = bus.status and bus.status() or {}
            local interval = (bus.config and bus.config.heartbeatMs) or 5000
            if util.now() - lastBeat >= interval then
              local ok = send({
                type = "heartbeat",
                pose = status.pose,
                fuel = status.fuel,
                inventory = status.inventory,
                state = status.state,
                missionId = status.missionId,
              })
              lastBeat = util.now()
              if not ok then break end
            end
          end
          close()
          util.log("link: disconnected")
          os.sleep(backoff)
          backoff = math.min(backoff * 2, 30)
        end
        end
      end
    end
  end
end

return M