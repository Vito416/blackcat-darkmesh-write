#!/usr/bin/env lua
-- Sanity check that core counters/gauges land in the Prom text file
-- (breaker_open, webhook_retry_queue, wal_apply_duration*, idempotency_collisions*).

local tmp_prom = os.tmpname() .. ".prom"
local tmp_log = os.tmpname() .. ".log"

local overrides = {
  METRICS_PROM_PATH = tmp_prom,
  METRICS_LOG = tmp_log,
  METRICS_ENABLED = "1",
  METRICS_FLUSH_EVERY = "0",
}

-- luacheck: push ignore os
local real_getenv = os.getenv
os.getenv = function(key)
  if overrides[key] ~= nil then
    return overrides[key]
  end
  return real_getenv(key)
end
-- luacheck: pop

local metrics = require "ao.shared.metrics"

metrics._reset()
metrics.gauge("outbox_queue_depth", 7)
metrics.gauge("wal_apply_duration_seconds", 1.23)
metrics.gauge("wal_apply_duration", 1.23)
metrics.gauge("webhook_retry_lag_seconds", 9)
metrics.gauge("webhook_retry_lag", 9)
metrics.gauge("write.webhook.retry_queue", 3)
metrics.gauge("webhook_retry_queue", 3)
metrics.gauge("write.webhook.replay_cache_size", 5)
metrics.gauge("webhook_replay_cache_size", 5)
metrics.gauge("breaker_open", 2)
metrics.counter("idempotency_collisions_total", 4)
metrics.counter("idempotency_collisions", 1)
metrics.counter("write.webhook.retry_overflow", 2)
metrics.counter("write.webhook.replay_gc_evicted", 1)
metrics.flush_prom()

local f = assert(io.open(tmp_prom, "r"))
local contents = f:read "*a"
f:close()

local function assert_contains(name)
  assert(contents:match(name), "missing metric: " .. name)
end

assert_contains "outbox_queue_depth"
assert_contains "wal_apply_duration_seconds"
assert_contains "wal_apply_duration"
assert_contains "webhook_retry_lag_seconds"
assert_contains "webhook_retry_lag"
assert_contains "write_webhook_retry_queue"
assert_contains "webhook_retry_queue"
assert_contains "write_webhook_replay_cache_size"
assert_contains "webhook_replay_cache_size"
assert_contains "breaker_open"
assert_contains "idempotency_collisions_total"
assert_contains "idempotency_collisions"
assert_contains "write_webhook_retry_overflow_total"
assert_contains "write_webhook_replay_gc_evicted_total"

os.remove(tmp_prom)
os.remove(tmp_log)

print "metrics_counters_spec: ok"
