-- Simple forwarder: read write outbox events and apply to AO ingest.
-- Usage:
-- LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;../blackcat-darkmesh-ao/?.lua;../blackcat-darkmesh-ao/?/init.lua" \
--   WRITE_OUTBOX_PATH=../blackcat-darkmesh-write/dev/outbox.json \
--   lua scripts/bridge/outbox_apply.lua

local ingest = require "ao.ingest.apply"
local storage = require "ao.shared.storage"
local path = os.getenv "WRITE_OUTBOX_PATH" or "dev/outbox.json"

local ok = storage.load(path)
if not ok then
  io.stderr:write("outbox not found: " .. path .. "\n")
  os.exit(1)
end

local outbox = storage.get("outbox_queue") or storage.get("outbox") or {}
local applied = 0
for _, entry in ipairs(outbox) do
  local ev = entry.event or entry
  local ok_apply, err = ingest.apply(ev)
  if not ok_apply then
    io.stderr:write(string.format("apply failed for %s: %s\n", ev.action or "?", err or "?"))
  else
    applied = applied + 1
  end
end

print(string.format("Applied %d events from %s", applied, path))
