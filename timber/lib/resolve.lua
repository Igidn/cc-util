-- Tunnel URL resolution with caching and refresh.
local util = require("lib.util")

local M = {}

M.CACHE = "/ccutil/tunnel.json"
M.TTL = 5 * 60 * 1000 -- 5 minutes

local cachedUrl = nil
local cachedAt = 0

function M.current()
  if cachedUrl and util.now() - cachedAt < M.TTL then
    return cachedUrl
  end
  local data = util.readJson(M.CACHE)
  if type(data) == "table" and type(data.url) == "string" then
    cachedUrl = data.url:gsub("/+$", "")
    cachedAt = util.now()
    return cachedUrl
  end
  return nil
end

function M.refresh()
  cachedUrl = nil
  cachedAt = 0
  return M.current()
end

function M.wsUrl(httpUrl)
  if httpUrl:sub(1, 5) == "https" then
    return "wss" .. httpUrl:sub(5)
  elseif httpUrl:sub(1, 4) == "http" then
    return "ws" .. httpUrl:sub(4)
  end
  return httpUrl
end

function M.save(url)
  local data = { url = url }
  util.writeJson(M.CACHE, data)
  cachedUrl = url:gsub("/+$", "")
  cachedAt = util.now()
end

return M