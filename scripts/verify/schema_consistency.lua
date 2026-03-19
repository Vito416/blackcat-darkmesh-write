package.path = table.concat({ '?.lua', '?/init.lua', 'ao/?.lua', 'ao/?/init.lua', package.path }, ';')

local ok_actions, actions_schema = pcall(require, "cjson.safe")
local ok_process, write = pcall(require, "ao.write.process")

local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

if not ok_actions then
  fail("cjson.safe not available")
end

local schema_path = "schemas/actions.schema.json"
local f = io.open(schema_path, "r")
if not f then
  fail("missing schema: " .. schema_path)
end
local raw = f:read("*a"); f:close()
local schema = actions_schema.decode(raw)
if type(schema) ~= "table" then
  fail("invalid actions schema structure")
end

if not ok_process or type(write.handlers) ~= "table" then
  fail("write.process.handlers not available")
end

local handlers = {}
for action, _ in pairs(write.handlers) do
  handlers[action] = true
end

local schema_actions = {}
local props = schema.properties or {}
for name, def in pairs(props) do
  if name ~= "Action" and type(def) == "table" then
    schema_actions[name] = true
  end
end

for action in pairs(schema_actions) do
  if not handlers[action] then
    fail(string.format("schema action without handler: %s", action))
  end
end

-- Note: handlers without a schema definition are tolerated; this allows internal
-- maintenance/admin actions that are not part of the public API surface.
for action in pairs(handlers) do
  if not schema_actions[action] then
    io.stderr:write(string.format("warning: handler missing schema definition (ignored): %s\n", action) .. "\\n")
  end
end

local function count(tbl)
  local n = 0
  for _ in pairs(tbl) do n = n + 1 end
  return n
end

print(string.format("schema_consistency: ok (%d actions)", count(schema_actions)))
