#!/usr/bin/env lua
-- Run all fixture commands and optionally compare with expected outputs.

local function load_json_module()
  local ok, mod = pcall(require, "cjson")
  if ok then return mod end
  ok, mod = pcall(require, "dkjson")
  if ok then
    return {
      decode = function(str) return mod.decode(str) end,
      encode = function(tbl) return mod.encode(tbl) end,
    }
  end
  return nil
end

local cjson = load_json_module()
if not cjson then
  io.stderr:write("cjson or dkjson required for batch_run\n")
  os.exit(1)
end
local lfs_ok, lfs = pcall(require, "lfs")
if not lfs_ok then
  io.stderr:write("lua-filesystem (lfs) required for batch_run\n")
  os.exit(1)
end
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  -- compare keys/values disregarding table iteration order
  local seen = {}
  for k, v in pairs(a) do
    if not same(v, b[k]) then return false end
    seen[k] = true
  end
  for k in pairs(b) do
    if not seen[k] then return false end
  end
  return true
end

local function load_write()
  return require("ao.write.process")
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function run_fixture(path)
  local body = read_file(path)
  if not body then return false, "read_failed" end
  local cmd = cjson.decode(body)
  local write = load_write()
  cmd._env = nil

  local commands, expected_all = nil, nil
  if cmd.commands then
    commands = cmd.commands
    for _, c in ipairs(commands) do c._env = nil end
    local expected_path = path .. ".expected.json"
    local expected_str = read_file(expected_path)
    if expected_str then expected_all = cjson.decode(expected_str) end
  else
    commands = { cmd }
  end

  local results = {}
  for _, c in ipairs(commands) do
    table.insert(results, write.route(c))
  end

  local expected_path = path .. ".expected.json"
  local expected_str = read_file(expected_path)
  if expected_str or expected_all then
    local expected = expected_all or cjson.decode(expected_str)
    if #commands == 1 then expected = { expected } end
    if not same(results, expected) then return false, "mismatch" end
  end
  if #results == 1 then results = results[1] end
  if expected_str and not same(results, (expected_all or cjson.decode(expected_str))) then
    local expected = cjson.decode(expected_str)
    if not same(results, expected) then return false, "mismatch" end
  end
  return true
end

-- Child mode: if a fixture path is passed as argv[1], run only that file.
if arg and arg[1] then
  local ok, err = run_fixture(arg[1])
  if not ok then
    io.stderr:write(string.format("%s (%s)\n", arg[1], err or "error"))
    os.exit(1)
  end
  os.exit(0)
end

local fixtures_dir = "fixtures"
local passed, failed = 0, 0
for file in lfs.dir(fixtures_dir) do
  if file:match("%.json$") and not file:match("%.expected%.json$") then
    local path = fixtures_dir .. "/" .. file
    local body = read_file(path)
    local env_over = {}
    if body then
      local ok, decoded = pcall(cjson.decode, body)
      if ok and decoded and decoded._env then env_over = decoded._env end
    end
    local env_prefix = ""
    for k, v in pairs(env_over) do
      env_prefix = env_prefix .. string.format("%s=%q ", k, tostring(v))
    end
    -- pass through existing env; allows per-fixture overrides via _env.
    local script_path = arg[0] or debug.getinfo(1, "S").source:sub(2)
    local cmd = string.format("%sLUA_PATH=%q LUA_CPATH=%q lua5.4 %s %s", env_prefix, os.getenv("LUA_PATH") or "", os.getenv("LUA_CPATH") or "", script_path, path)
    local ok = os.execute(cmd)
    if ok == true or ok == 0 then
      passed = passed + 1; print("[ok] " .. file)
    else
      failed = failed + 1; print(string.format("[fail] %s", file))
    end
  end
end

print(string.format("batch run: passed=%d failed=%d", passed, failed))
os.exit(failed == 0 and 0 or 1)
