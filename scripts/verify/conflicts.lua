local write = require "ao.write.process"

-- Simple replay/idempotency checks for minimal action set

local function call(msg)
  return write.route(msg)
end

local req = {
  Action = "SaveDraftPage",
  ["Request-Id"] = "rid-1",
  ["Actor-Role"] = "editor",
  action = "SaveDraftPage",
  payload = { siteId = "s1", pageId = "home", blocks = {} },
}

local first = call(req)
assert(first.status == "OK")

local replay = call(req)
assert(replay.status == "OK") -- idem cache returns same response

local unknown = call { Action = "NotAllowed", ["Request-Id"] = "rid-2" }
assert(unknown.code == "UNKNOWN_ACTION")

print("conflicts: ok")
