-- Rendezvous: the public tunnel address is published as a fixed-tag GitHub
-- release asset. Direct release downloads do not consume the GitHub API rate
-- limit, which matters because every turtle shares the MC server's IP.
local util = require("lib.util")

local M = {}

M.REPO = "Igidn/cc-util"
M.TAG = "tunnel-latest"
M.BASE = "https://github.com/" .. M.REPO .. "/releases/download/" .. M.TAG
M.CACHE = "/ccutil/tunnel.json"
M.TTL = 10 * 60 * 1000

local function get(url)
  if not http then return nil, "http is disabled" end
  local response, err = http.get(url, { ["User-Agent"] = "cc-util/" .. util.VERSION })
  if not response then return nil, err or "http.get failed" end
  local code = response.getResponseCode()
  local body = response.readAll()
  response.close()
  if code ~= 200 then
    return nil, ("http %d from %s"):format(code, url)
  end
  return body
end

function M.fetch()
  local body, err = get(M.BASE .. "/tunnel.json")
  if not body then return nil, err end
  local data = util.jsonDecode(body)
  if type(data) ~= "table" or type(data.url) ~= "string" or data.url == "" then
    return nil, "tunnel.json has no url"
  end
  local url = data.url:gsub("/+$", "")
  util.writeJson(M.CACHE, { url = url, fetchedAt = util.now() })
  return url
end

--- Cached URL if fresh, otherwise re-fetch. On failure, fall back to the last
-- known URL so a transient GitHub outage does not strand a working turtle.
function M.current()
  local cached = util.readJson(M.CACHE)
  if type(cached) == "table" and type(cached.url) == "string" then
    if util.now() - (cached.fetchedAt or 0) < M.TTL then
      return cached.url
    end
    local url, err = M.fetch()
    if url then return url end
    util.log("resolve: refresh failed:", err)
    return cached.url
  end
  return M.fetch()
end

function M.refresh()
  local url, err = M.fetch()
  if not url then
    util.log("resolve: refresh failed:", err)
    return nil, err
  end
  return url
end

function M.wsUrl(url)
  local base = url:gsub("/+$", "")
  if base:sub(1, 8) == "https://" then
    base = "wss://" .. base:sub(9)
  elseif base:sub(1, 7) == "http://" then
    base = "ws://" .. base:sub(8)
  end
  if base:sub(-3) ~= "/ws" then base = base .. "/ws" end
  return base
end

return M
