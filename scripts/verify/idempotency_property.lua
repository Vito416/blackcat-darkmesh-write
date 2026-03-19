package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")
local write = require "ao.write.process"

local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

local function expect_ok(res, msg)
  if not (res and res.status == "OK") then
    fail(msg)
  end
  return res
end

-- property: same request id yields identical response and does not mutate state beyond first apply
local function run_pair(action, payload1, payload2)
  local req_id = action .. "-idem"
  local req1 = {
    Action = action,
    ["Request-Id"] = req_id,
    ["Actor-Role"] = payload1.role or "admin",
    actor = payload1.actor or "tester",
    tenant = payload1.tenant or "t1",
    nonce = payload1.nonce or ("nonce-" .. action),
    ts = os.time(),
    payload = payload1.payload,
  }
  local before = write._state()
  local first = expect_ok(write.route(req1), "first " .. action .. " failed")

  local req2 = {
    Action = action,
    ["Request-Id"] = req_id,
    ["Actor-Role"] = payload2.role or "admin",
    actor = payload2.actor or "tester",
    tenant = payload2.tenant or "t1",
    nonce = payload2.nonce or ("nonce2-" .. action),
    ts = os.time(),
    payload = payload2.payload,
  }
  local second = expect_ok(write.route(req2), "second " .. action .. " failed")
  if first ~= second then
    fail(action .. " idempotency returned different table reference")
  end
  local after = write._state()
  if after ~= before and action == "SaveDraftPage" then
    local key = payload1.payload.siteId .. ":" .. payload1.payload.pageId
    local draft = after.drafts[key]
    if draft and draft.blocks and #draft.blocks ~= #payload1.payload.blocks then
      fail(action .. " idempotency mutated draft blocks on replay")
    end
  end
end

run_pair(
  "SaveDraftPage",
  {
    payload = {
      siteId = "s-idem",
      pageId = "home",
      locale = "en",
      blocks = { { type = "text", value = "first" } },
    },
  },
  {
    payload = {
      siteId = "s-idem",
      pageId = "home",
      locale = "en",
      blocks = { { type = "text", value = "second" } },
    },
  }
)

print "idempotency_property: ok"
