#!/usr/bin/env lua
-- Replay persisted outbox events into a queue file with optional HMAC verification.

local storage = require "ao.shared.storage"
local cjson = require "cjson.safe"
local metrics_ok, metrics = pcall(require, "ao.shared.metrics")
local verifier_ok, verifier = pcall(require, "ao.shared.outbox_verifier")

local outbox_path = os.getenv "WRITE_OUTBOX_PATH"
local queue_path = os.getenv "AO_QUEUE_PATH" or "dev/outbox-queue.ndjson"
local strict_hmac = os.getenv "WRITE_STRICT_OUTBOX_HMAC" == "1"
local hmac_mode = os.getenv "WRITE_OUTBOX_HMAC_MODE"
local hmac_secret = os.getenv "OUTBOX_HMAC_SECRET"
local limit = tonumber(os.getenv "OUTBOX_REPLAY_LIMIT" or "0")
local dry_run = os.getenv "OUTBOX_REPLAY_DRY_RUN" == "1"

if not outbox_path or outbox_path == "" then
  io.stderr:write "WRITE_OUTBOX_PATH is required\n"
  os.exit(1)
end

if not cjson then
  io.stderr:write "cjson is required for outbox replay\n"
  os.exit(1)
end

local function ensure_dir(path)
  local dir = path:match "(.+)/[^/]+$"
  if dir then
    os.execute(string.format('mkdir -p "%s"', dir))
  end
end

local ok = storage.load(outbox_path)
if not ok then
  io.stderr:write("failed to load outbox from " .. outbox_path .. "\n")
  os.exit(1)
end

local verify_event
if verifier_ok and verifier.make_verifier then
  verify_event = verifier.make_verifier {
    secret = hmac_secret,
    mode = hmac_mode,
    strict = strict_hmac,
  }
end

local outbox = storage.get "outbox_queue" or storage.get "outbox" or {}

ensure_dir(queue_path)
local f = assert(io.open(queue_path, "w"))

local written, skipped = 0, 0
local failures = { hmac_missing = 0, hmac_mismatch = 0, other = 0 }
local suppress_hmac_warn = os.getenv "OUTBOX_SUPPRESS_HMAC_WARN" == "1"

for _, entry in ipairs(outbox) do
  if limit > 0 and written >= limit then
    break
  end
  local ev = entry.event or entry
  if ev then
    local ok_hmac, why = true, "ok"
    if verify_event then
      ok_hmac, why = verify_event(ev)
    end
    if not ok_hmac then
      failures[why or "other"] = (failures[why or "other"] or 0) + 1
      if metrics_ok and metrics.counter then
        if why == "hmac_missing" then
          metrics.counter("write_outbox_hmac_missing_total", 1)
        elseif why == "hmac_mismatch" then
          metrics.counter("write_outbox_hmac_mismatch_total", 1)
        end
      end
      skipped = skipped + 1
    else
      if not dry_run then
        f:write(cjson.encode(ev))
        f:write "\n"
      end
      written = written + 1
    end
  end
end

f:close()

if metrics_ok and metrics.gauge then
  metrics.gauge("write.outbox.queue_size", written)
  metrics.gauge("outbox_queue_depth", written)
end

local msg = string.format(
  "outbox_replay: wrote=%d skipped=%d source=%s dest=%s",
  written,
  skipped,
  outbox_path,
  queue_path
)
print(msg)
if skipped > 0 and not suppress_hmac_warn then
  io.stderr:write(
    string.format(
      "hmac failures: missing=%d mismatch=%d other=%d\n",
      failures.hmac_missing or 0,
      failures.hmac_mismatch or 0,
      failures.other or 0
    )
  )
end
