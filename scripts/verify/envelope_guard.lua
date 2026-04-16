package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

local function require_env()
  if os.getenv "WRITE_REQUIRE_SIGNATURE" ~= "1" then
    io.stderr:write "SKIP envelope_guard: WRITE_REQUIRE_SIGNATURE must be 1\n"
    os.exit(0)
  end
  if not os.getenv "WRITE_SIG_PRIV_HEX" or not os.getenv "WRITE_SIG_PUBLIC" then
    io.stderr:write "SKIP envelope_guard: set WRITE_SIG_PRIV_HEX and WRITE_SIG_PUBLIC\n"
    os.exit(0)
  end
end

local function json_escape(str)
  return str:gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function json_encode(val)
  local t = type(val)
  if t == "nil" then
    return "null"
  elseif t == "boolean" or t == "number" then
    return tostring(val)
  elseif t == "string" then
    return '"' .. json_escape(val) .. '"'
  elseif t == "table" then
    local is_array = (#val > 0)
    if is_array then
      local parts = {}
      for i = 1, #val do
        parts[#parts + 1] = json_encode(val[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(val) do
        keys[#keys + 1] = k
      end
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json_encode(val[k])
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

local function sign_cmd(cmd)
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "w"))
  f:write(json_encode(cmd))
  f:close()
  local handle = io.popen(
    string.format(
      "WRITE_SIG_PRIV_HEX=%q node scripts/sign-write.js --file %q",
      os.getenv "WRITE_SIG_PRIV_HEX",
      tmp
    ),
    "r"
  )
  if not handle then
    os.remove(tmp)
    error "cannot run sign-write.js"
  end
  local out = handle:read "*a"
  handle:close()
  os.remove(tmp)
  local sig = (out or ""):match '"signature"%s*:%s*"([^"]+)"'
  local sig_ref = (out or ""):match '"signatureRef"%s*:%s*"([^"]+)"'
  assert(sig, "signature missing in sign-write output")
  cmd.signature = sig
  cmd["Signature-Ref"] = sig_ref or "write-ed25519-test"
  return cmd
end

require_env()

local write = require "ao.write.process"

local function assert_eq(a, b, msg)
  if a ~= b then
    io.stderr:write(
      (msg or "assert failed") .. string.format(" (%s ~= %s)\n", tostring(a), tostring(b))
    )
    os.exit(1)
  end
end

-- missing nonce/ts should be rejected
local bad = write.route {
  Action = "GetOpsHealth",
  ["Request-Id"] = "r1",
  ["Actor-Role"] = "admin",
  actor = "validator",
  tenant = "tenant-1",
  signature = "deadbeef",
  ["Signature-Ref"] = "test",
}
assert_eq(bad.status, "ERROR", "missing nonce should error")

-- valid envelope passes
local ts = os.time()
local ok = write.route(sign_cmd {
  Action = "GetOpsHealth",
  ["Request-Id"] = "r2",
  ["Actor-Role"] = "admin",
  actor = "validator",
  tenant = "tenant-1",
  nonce = "n123",
  ts = ts,
})
assert_eq(ok.status, "OK", "valid envelope should succeed")
print "envelope_guard: ok"
