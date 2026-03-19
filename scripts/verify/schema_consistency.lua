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
if type(schema) ~= "table" or type(schema.definitions) ~= "table" then
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
for def_name, def in pairs(schema.definitions) do
  if type(def) == "table" and def.properties and def.properties.Action and def.properties.Action.const then
    schema_actions[def.properties.Action.const] = def_name
  end
end

for action in pairs(schema_actions) do
  if not handlers[action] then
    fail(string.format("schema action without handler: %s", action))
  end
end

for action in pairs(handlers) do
  if not schema_actions[action] then
    fail(string.format("handler missing schema definition: %s", action))
  end
end

print("schema_consistency: ok (" .. tostring(#(function(tbl) local n=0; for _ in pairs(tbl) do n=n+1 end; return {n} end)(schema_actions)[1]) .. " actions)")
