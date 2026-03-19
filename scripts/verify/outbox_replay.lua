#!/usr/bin/env lua
-- Re-enqueue persisted outbox events into a fresh queue for re-forwarding.
-- Usage:
--   WRITE_OUTBOX_PATH=dev/outbox.json AO_QUEUE_PATH=dev/outbox-queue.ndjson lua scripts/verify/outbox_replay.lua

local storage = require("ao.shared.storage")
local cjson = require("cjson.safe")

local outbox_path = os.getenv("WRITE_OUTBOX_PATH")
local queue_path = os.getenv("AO_QUEUE_PATH") or "dev/outbox-queue.ndjson"

if not outbox_path or outbox_path == "" then
  io.stderr:write("WRITE_OUTBOX_PATH not set\n")
  os.exit(1)
end

local ok = storage.load(outbox_path)
if not ok then
  io.stderr:write("failed to load outbox from " .. outbox_path .. "\n")
  os.exit(1)
end

local outbox = storage.get("outbox_queue") or storage.get("outbox") or {}
local f = assert(io.open(queue_path, "w"))
local count = 0
for _, entry in ipairs(outbox) do
  local ev = entry.event or entry
  if ev then
    f:write(cjson.encode(ev))
    f:write("\n")
    count = count + 1
  end
end
f:close()
print(string.format("outbox_replay: wrote %d events to %s", count, queue_path))
