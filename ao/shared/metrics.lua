-- Minimal metrics helper for write AO: counters and gauges flushed to log/Prom-style file.

local Metrics = {}

local LOG_PATH = os.getenv "METRICS_LOG" or "metrics/metrics.log"
local ENABLED = os.getenv "METRICS_ENABLED" ~= "0"
local PROM_PATH = os.getenv "METRICS_PROM_PATH"
local FLUSH_EVERY = tonumber(os.getenv "METRICS_FLUSH_EVERY" or "0")
local FLUSH_INTERVAL = tonumber(os.getenv "METRICS_FLUSH_INTERVAL_SEC" or "0")

local counters, gauges = {}, {}
local since_flush, last_flush, started = 0, os.time(), false
local timer_ok, timer = pcall(require, "ao.shared.timer")

local function ensure_dir(path)
  local dir = path:match "(.+)/[^/]+$"
  if dir then os.execute(string.format('mkdir -p "%s"', dir)) end
end

local function log(event)
  if not ENABLED or not LOG_PATH then return end
  ensure_dir(LOG_PATH)
  local f = io.open(LOG_PATH, "a")
  if not f then return end
  f:write(string.format(
    '{"ts":"%s","event":"%s","value":%s}\n',
    os.date "!%Y-%m-%dT%H:%M:%SZ",
    event.name or "metric",
    event.value or 0
  ))
  f:close()
end

function Metrics.inc(name, value)
  if os.getenv("METRICS_DISABLED") == "1" then return end
  value = value or 1
  counters[name] = (counters[name] or 0) + value
  log { name = name, value = counters[name] }
  since_flush = since_flush + 1
  if FLUSH_EVERY > 0 and since_flush >= FLUSH_EVERY then
    Metrics.flush_prom()
    since_flush = 0
  elseif FLUSH_EVERY == 0 then
    Metrics.flush_prom()
  end
end

function Metrics.counter(name, value)
  Metrics.inc(name, value)
end

function Metrics.gauge(name, value)
  if os.getenv("METRICS_DISABLED") == "1" then return end
  gauges[name] = value
  log { name = name, value = value }
end

function Metrics.flush_prom()
  if not PROM_PATH then return end
  ensure_dir(PROM_PATH)
  local f = io.open(PROM_PATH, "w")
  if not f then return end
  for k, v in pairs(counters) do
    f:write(string.format("%s_total %d\n", k:gsub("[^%w_]", "_"), v))
  end
  for k, v in pairs(gauges) do
    f:write(string.format("%s %s\n", k:gsub("[^%w_]", "_"), tostring(v)))
  end
  f:close()
end

function Metrics.tick()
  if os.getenv("METRICS_DISABLED") == "1" then return end
  local now = os.time()
  if FLUSH_INTERVAL > 0 and (now - last_flush) >= FLUSH_INTERVAL then
    Metrics.flush_prom()
    last_flush = now
    since_flush = 0
  end
  if FLUSH_INTERVAL > 0 and timer_ok then
    timer.start(FLUSH_INTERVAL, Metrics.flush_prom)
  end
end

function Metrics.start_background()
  if started then return end
  started = true
  if FLUSH_INTERVAL > 0 and timer_ok then
    timer.start(FLUSH_INTERVAL, Metrics.flush_prom)
  end
end

function Metrics._reset()
  counters, gauges = {}, {}
end

Metrics.start_background()

return Metrics
