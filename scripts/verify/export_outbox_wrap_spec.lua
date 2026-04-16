package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

local ok_json, cjson = pcall(require, "cjson.safe")
if not ok_json or not cjson then
  print "export_outbox_wrap_spec: skipped (cjson.safe not available)"
  os.exit(0)
end

local storage = require "ao.shared.storage"

storage.put("outbox_queue", {
  {
    event = { type = "PublishPageVersion", siteId = "site-wrap", requestId = "req-wrap-1" },
    status = "pending",
    attempts = 1,
  },
  { type = "PublishPageVersion", siteId = "site-plain", requestId = "req-wrap-2" },
})

local out = string.format("/tmp/outbox-wrap-%d.ndjson", os.time())
os.remove(out)

local old_arg = _G.arg
_G.arg = { out }
local ok_run, run_err = pcall(dofile, "scripts/bridge/export_outbox.lua")
_G.arg = old_arg
if not ok_run then
  io.stderr:write("export_outbox_wrap_spec: export script failed: " .. tostring(run_err) .. "\n")
  os.exit(1)
end

local f = io.open(out, "r")
if not f then
  io.stderr:write "export_outbox_wrap_spec: output file not created\n"
  os.exit(1)
end

local lines = {}
for line in f:lines() do
  table.insert(lines, line)
end
f:close()
os.remove(out)

if #lines ~= 2 then
  io.stderr:write("export_outbox_wrap_spec: expected 2 lines, got " .. tostring(#lines) .. "\n")
  os.exit(1)
end

local first = cjson.decode(lines[1])
local second = cjson.decode(lines[2])
if type(first) ~= "table" or first.type ~= "PublishPageVersion" or first.siteId ~= "site-wrap" then
  io.stderr:write "export_outbox_wrap_spec: first record not unwrapped event\n"
  os.exit(1)
end
if first.event ~= nil or first.status ~= nil then
  io.stderr:write "export_outbox_wrap_spec: wrapper metadata leaked into export\n"
  os.exit(1)
end
if type(second) ~= "table" or second.siteId ~= "site-plain" then
  io.stderr:write "export_outbox_wrap_spec: second plain event malformed\n"
  os.exit(1)
end

print "export_outbox_wrap_spec: ok"
