package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

local write = require "ao.write.process"
local sign = require "scripts.verify._test_sign"

local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

local function expect(condition, msg)
  if not condition then
    fail(msg)
  end
end

local function run(req_id)
  return write.route(sign.maybe_sign {
    Action = "GetOpsHealth",
    ["Request-Id"] = req_id,
    ["Actor-Role"] = "admin",
    actor = "persist-checker",
    tenant = "tenant-1",
    nonce = "persist-nonce-" .. req_id,
    ts = os.time(),
    payload = {},
  })
end

local mode = os.getenv "PERSIST_FAIL_MODE"
if mode ~= "wal" and mode ~= "idem" then
  fail "set PERSIST_FAIL_MODE=wal|idem"
end

if mode == "wal" then
  local ok_cjson = pcall(require, "cjson")
  if not ok_cjson then
    io.stderr:write "SKIP persistence_failure_modes(wal): cjson unavailable\n"
    os.exit(0)
  end
end

local req_a = "persist-fail-a"
local req_b = "persist-fail-b"
local first = run(req_a)
local second = run(req_b)

expect(type(first) == "table" and type(second) == "table", "missing responses")
expect(first.status == "ERROR", "first response should fail")
expect(second.status == "ERROR", "second response should fail")
expect(first.code == "SERVER_ERROR", "first code should be SERVER_ERROR")
expect(second.code == "SERVER_ERROR", "second code should be SERVER_ERROR")

if mode == "wal" then
  expect(first.message == "wal_write_failed", "expected wal_write_failed in first response")
  expect(second.message == "wal_write_failed", "expected wal_write_failed in second response")
else
  local function is_idem_persist_failure(msg)
    local value = tostring(msg or "")
    if value == "idempotency_persist_failed" or value == "cjson_missing" then
      return true
    end
    if value == "open_failed" or value == "write_failed" or value == "rename_failed" then
      return true
    end
    if value:lower():find("permission denied", 1, true) then
      return true
    end
    return false
  end
  expect(
    is_idem_persist_failure(first.message),
    "expected idempotency persistence failure marker in first response"
  )
  expect(
    is_idem_persist_failure(second.message),
    "expected idempotency persistence failure marker in second response"
  )
end

print("persistence_failure_modes: ok (" .. mode .. ")")
